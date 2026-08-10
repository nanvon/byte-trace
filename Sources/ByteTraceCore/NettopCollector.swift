import Darwin
import Foundation

public enum NettopCollectorState: Equatable, Sendable {
    case stopped
    case starting
    case baseline
    case collecting
    case incompatible
    case failed(String)
}

public enum NettopCollectorEvent: Sendable {
    case started(pid: Int32)
    case parser(NettopParserEvent)
    case stderr(String)
    case exited(status: Int32)
}

public enum NettopCollectorError: LocalizedError {
    case alreadyRunning
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "nettop collector is already running"
        case let .launchFailed(message):
            return "unable to launch nettop: \(message)"
        }
    }
}

public enum NettopCollectorScope: Equatable, Sendable {
    case externalProcessSummary
    case supplementalConnections

    public var arguments: [String] {
        let common = ["-n", "-d", "-x", "-L", "0"]
        let columns = ["-J", "time,interface,state,bytes_in,bytes_out"]
        switch self {
        case .externalProcessSummary:
            return ["-n", "-P", "-d", "-x", "-L", "0", "-s", "5", "-t", "external"] + columns
        case .supplementalConnections:
            return common + ["-s", "1", "-t", "loopback", "-t", "undefined"] + columns
        }
    }

    var parserMode: NettopCSVParserMode {
        switch self {
        case .externalProcessSummary: return .processSummary
        case .supplementalConnections: return .connections
        }
    }
}

public final class NettopCollector: @unchecked Sendable {
    public static let executablePath = "/usr/bin/nettop"
    public static let arguments = NettopCollectorScope.externalProcessSummary.arguments

    public let scope: NettopCollectorScope

    public var onEvent: ((NettopCollectorEvent) -> Void)?

    private let stateLock = NSLock()
    private let parserQueue = DispatchQueue(label: "com.nanvon.ByteTrace.nettop-parser")
    private var currentState: NettopCollectorState = .stopped
    private var process: Process?
    private var processIdentifier: Int32?
    private var readGroup: DispatchGroup?
    private var stdinPipe: Pipe?
    private var parser: NettopCSVParser
    private var didReportExit = false
    private var stderrData = Data()

    public init(scope: NettopCollectorScope = .externalProcessSummary) {
        self.scope = scope
        self.parser = NettopCSVParser(mode: scope.parserMode)
    }

    public var state: NettopCollectorState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentState
    }

    public var runningProcessIdentifier: Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return processIdentifier
    }

    public func start() throws {
        stateLock.lock()
        guard process == nil, currentState != .starting else {
            stateLock.unlock()
            throw NettopCollectorError.alreadyRunning
        }
        currentState = .starting
        parser = NettopCSVParser(mode: scope.parserMode)
        stderrData.removeAll(keepingCapacity: false)
        didReportExit = false
        stateLock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = scope.arguments
        // `-L 0` 是无限 CSV 日志模式。输出到普通 Pipe 时 nettop 会做整块缓冲；
        // 精简 `-J` 列后，低流量场景可能数分钟都凑不满缓冲区，应用便收不到帧。
        // Apple 的 NSUnbufferedIO 只关闭子进程 stdio 缓冲，不改变 CSV 格式或采样频率。
        var environment = ProcessInfo.processInfo.environment
        environment["NSUnbufferedIO"] = "YES"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // stdin 必须是一个父进程持续持有、且永不写入的空 Pipe：
        // nettop 是 curses 交互程序，会 poll stdin 等待按键；若 stdin 立即可读
        // （如 /dev/null 的 EOF），poll 永不休眠，子进程会空转占满一个多核心。
        // 空 pipe 的写端由我们持有且不关闭，stdin 永远不就绪。
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        process.terminationHandler = { [weak self] process in
            self?.reportTermination(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            updateState(.failed(error.localizedDescription))
            throw NettopCollectorError.launchFailed(error.localizedDescription)
        }

        let readGroup = DispatchGroup()
        stateLock.lock()
        self.process = process
        self.stdinPipe = stdinPipe
        processIdentifier = process.processIdentifier
        self.readGroup = readGroup
        stateLock.unlock()

        emit(.started(pid: process.processIdentifier))

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Self.readUntilEOF(stdoutHandle) { [weak self] data in
                self?.consumeStdout(data)
            }
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            Self.readUntilEOF(stderrHandle) { [weak self] data in
                self?.consumeStderr(data)
            }
            readGroup.leave()
        }
    }

    public func stop() {
        stateLock.lock()
        let process = self.process
        let readGroup = self.readGroup
        stateLock.unlock()

        if let process {
            Self.terminate(process)
        }
        readGroup?.wait()

        let finalEvents = parserQueue.sync {
            parser.finish()
        }
        handleParserEvents(finalEvents)

        stateLock.lock()
        let stderr = String(decoding: stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.process = nil
        self.stdinPipe = nil
        processIdentifier = nil
        self.readGroup = nil
        currentState = .stopped
        stateLock.unlock()

        if !stderr.isEmpty {
            emit(.stderr(stderr))
        }
    }

    private func consumeStdout(_ data: Data) {
        let events = parserQueue.sync {
            parser.consume(data)
        }
        handleParserEvents(events)
    }

    private func consumeStderr(_ data: Data) {
        stateLock.lock()
        stderrData.append(data)
        stateLock.unlock()
    }

    private func handleParserEvents(_ events: [NettopParserEvent]) {
        for event in events {
            switch event {
            case let .frameCompleted(_, _, isBaseline):
                updateState(isBaseline ? .baseline : .collecting)
            case .incompatibleSchema:
                updateState(.incompatible)
            case .malformedRow, .schemaChanged:
                break
            }
            emitParserEvent(event)
        }
    }

    private func reportTermination(status: Int32) {
        stateLock.lock()
        guard !didReportExit else {
            stateLock.unlock()
            return
        }
        didReportExit = true
        stateLock.unlock()
        emit(.exited(status: status))
    }

    private func updateState(_ newState: NettopCollectorState) {
        stateLock.lock()
        currentState = newState
        stateLock.unlock()
    }

    private func emit(_ event: NettopCollectorEvent) {
        onEvent?(event)
    }

    private func emitParserEvent(_ event: NettopParserEvent) {
        guard let callback = onEvent else { return }
        DispatchQueue.main.async {
            callback(.parser(event))
        }
    }

    private static func readUntilEOF(_ handle: FileHandle, onData: @escaping (Data) -> Void) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if byteCount > 0 {
                onData(Data(buffer.prefix(byteCount)))
                continue
            }
            if byteCount < 0, errno == EINTR { continue }
            return
        }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
