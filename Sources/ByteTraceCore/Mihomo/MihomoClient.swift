import Darwin
import Foundation

public enum MihomoClientError: LocalizedError, Equatable {
    case unauthorized
    case httpStatus(Int)
    case connectionFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "mihomo 控制器拒绝访问（secret 不匹配）"
        case let .httpStatus(code): return "mihomo 控制器返回 HTTP \(code)"
        case let .connectionFailed(message): return "无法连接 mihomo 控制器：\(message)"
        case .invalidResponse: return "mihomo 控制器响应无法解析"
        }
    }
}

/// 只读访问 mihomo 控制器。TCP 走 URLSession；Unix 套接字（Clash Verge 默认）
/// 用 POSIX 套接字发 HTTP/1.0 请求，服务端读完即关闭连接，不需要处理分块编码。
public final class MihomoClient: @unchecked Sendable {
    private let session: URLSession
    private let queue = DispatchQueue(label: "com.nanvon.ByteTrace.mihomo-client", qos: .utility)
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 2) {
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // 控制器在本机回环上，必须绕过系统代理，否则请求会被代理自己转发。
        configuration.connectionProxyDictionary = [:]
        configuration.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: configuration)
    }

    public func get(_ path: String, from controller: MihomoController) async throws -> Data {
        switch controller.transport {
        case let .tcp(host, port):
            let hostPart = host.contains(":") ? "[\(host)]" : host
            guard let url = URL(string: "http://\(hostPart):\(port)\(path)") else {
                throw MihomoClientError.invalidResponse
            }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            if let secret = controller.secret {
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw MihomoClientError.connectionFailed(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw MihomoClientError.invalidResponse }
            try Self.check(status: http.statusCode)
            return data

        case let .unix(socketPath):
            let timeout = timeout
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let data = try Self.unixGet(
                            path,
                            socketPath: socketPath,
                            secret: controller.secret,
                            timeout: timeout
                        )
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func check(status: Int) throws {
        if status == 401 || status == 403 { throw MihomoClientError.unauthorized }
        guard (200..<300).contains(status) else { throw MihomoClientError.httpStatus(status) }
    }

    private static func unixGet(
        _ path: String,
        socketPath: String,
        secret: String?,
        timeout: TimeInterval
    ) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MihomoClientError.connectionFailed(String(cString: strerror(errno))) }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw MihomoClientError.connectionFailed("套接字路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw MihomoClientError.connectionFailed(String(cString: strerror(errno))) }

        var request = "GET \(path) HTTP/1.0\r\nHost: localhost\r\n"
        if let secret { request += "Authorization: Bearer \(secret)\r\n" }
        request += "\r\n"
        let requestBytes = Array(request.utf8)
        var sent = 0
        while sent < requestBytes.count {
            let result = requestBytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard result > 0 else { throw MihomoClientError.connectionFailed(String(cString: strerror(errno))) }
            sent += result
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0 else { throw MihomoClientError.connectionFailed(String(cString: strerror(errno))) }
            response.append(contentsOf: buffer[0..<count])
            if response.count > 32 * 1024 * 1024 { throw MihomoClientError.invalidResponse }
        }
        return try body(ofHTTPResponse: response)
    }

    static func body(ofHTTPResponse response: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator),
              let head = String(data: response[..<range.lowerBound], encoding: .utf8) else {
            throw MihomoClientError.invalidResponse
        }
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw MihomoClientError.invalidResponse
        }
        try check(status: status)
        let body = response[range.upperBound...]
        let chunked = lines.dropFirst().contains {
            $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked")
        }
        return chunked ? try decodeChunked(Data(body)) : Data(body)
    }

    static func decodeChunked(_ data: Data) throws -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex),
                  let sizeLine = String(data: data[index..<lineEnd.lowerBound], encoding: .utf8),
                  let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16) else {
                throw MihomoClientError.invalidResponse
            }
            if size == 0 { break }
            let chunkStart = lineEnd.upperBound
            let chunkEnd = chunkStart + size
            guard chunkEnd <= data.endIndex else { throw MihomoClientError.invalidResponse }
            output.append(data[chunkStart..<chunkEnd])
            index = min(data.endIndex, chunkEnd + 2)
        }
        return output
    }
}
