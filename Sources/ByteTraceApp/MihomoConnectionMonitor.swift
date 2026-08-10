import ByteTraceCore
import Foundation

enum MihomoControllerConfigurationError: LocalizedError {
    case invalidURL
    case unsupportedScheme
    case nonLoopbackHost
    case unsupportedURLComponents

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "控制器地址无效"
        case .unsupportedScheme:
            return "控制器地址只支持 http 或 https"
        case .nonLoopbackHost:
            return "当前版本只允许连接本机回环地址"
        case .unsupportedURLComponents:
            return "控制器地址不能包含账号、路径、查询参数或片段"
        }
    }
}

struct MihomoControllerConfiguration: Equatable, Sendable {
    let baseURL: URL
    let secret: String

    init(controllerURL: String, secret: String) throws {
        let trimmed = controllerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw MihomoControllerConfigurationError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw MihomoControllerConfigurationError.unsupportedScheme
        }
        guard Self.isLoopbackHost(host) else {
            throw MihomoControllerConfigurationError.nonLoopbackHost
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw MihomoControllerConfigurationError.unsupportedURLComponents
        }

        var normalized = components
        normalized.scheme = scheme
        normalized.path = ""
        guard let baseURL = normalized.url else {
            throw MihomoControllerConfigurationError.invalidURL
        }
        self.baseURL = baseURL
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayURL: String {
        baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func connectionsRequest() throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MihomoControllerConfigurationError.invalidURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/connections"
        components.queryItems = [URLQueryItem(name: "interval", value: "1000")]
        guard let url = components.url else {
            throw MihomoControllerConfigurationError.invalidURL
        }
        return authorizedRequest(url: url)
    }

    func versionRequest() throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MihomoControllerConfigurationError.invalidURL
        }
        components.path = "/version"
        guard let url = components.url else {
            throw MihomoControllerConfigurationError.invalidURL
        }
        var request = authorizedRequest(url: url)
        request.timeoutInterval = 3
        return request
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.first == "127",
              parts.allSatisfy({ UInt8($0) != nil }) else {
            return false
        }
        return true
    }
}

enum MihomoConnectionMonitorEvent: Sendable {
    case connecting
    case connected
    case deltas([MihomoConnectionDelta])
    case failed(String)
}

final class MihomoConnectionMonitor: @unchecked Sendable {
    var onEvent: (@Sendable (MihomoConnectionMonitorEvent) -> Void)?

    private let queue = DispatchQueue(label: "com.nanvon.ByteTrace.mihomo-connections")
    private let accumulator = MihomoConnectionAccumulator()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var isRunning = false
    private var didReceiveSnapshot = false

    func start(configuration: MihomoControllerConfiguration) {
        queue.async { [weak self] in
            self?.startOnQueue(configuration: configuration)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    static func test(configuration: MihomoControllerConfiguration) async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: configuration.versionRequest())
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(
                domain: "ByteTrace.Mihomo",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: status == 401 ? "密钥不正确" : "控制器返回状态码 \(status)"]
            )
        }
    }

    private func startOnQueue(configuration: MihomoControllerConfiguration) {
        stopOnQueue()
        generation += 1
        let currentGeneration = generation
        isRunning = true
        didReceiveSnapshot = false
        accumulator.reset()

        do {
            let request = try configuration.connectionsRequest()
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: sessionConfiguration)
            let task = session.webSocketTask(with: request)
            self.session = session
            self.task = task
            onEvent?(.connecting)
            task.resume()
            receiveNext(task: task, generation: currentGeneration)
        } catch {
            isRunning = false
            onEvent?(.failed(error.localizedDescription))
        }
    }

    private func stopOnQueue() {
        isRunning = false
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        didReceiveSnapshot = false
        accumulator.reset()
    }

    private func receiveNext(task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.isRunning,
                      self.generation == generation,
                      self.task === task else {
                    return
                }
                switch result {
                case let .success(message):
                    self.handle(message)
                    self.receiveNext(task: task, generation: generation)
                case let .failure(error):
                    self.isRunning = false
                    self.task = nil
                    self.session?.invalidateAndCancel()
                    self.session = nil
                    self.onEvent?(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case let .data(value):
            data = value
        case let .string(value):
            data = Data(value.utf8)
        @unknown default:
            return
        }

        do {
            let snapshot = try JSONDecoder().decode(MihomoConnectionSnapshot.self, from: data)
            let deltas = accumulator.consume(snapshot)
            if !didReceiveSnapshot {
                didReceiveSnapshot = true
                onEvent?(.connected)
            }
            if !deltas.isEmpty {
                onEvent?(.deltas(deltas))
            }
        } catch {
            // 单帧损坏不重置已有基线；继续等待下一份完整快照。
        }
    }
}
