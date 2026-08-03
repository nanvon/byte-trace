import Darwin
import Foundation

public enum NettopConnectionCollectorEvent: Sendable {
    case started(pid: Int32)
    case parser(NettopConnectionParserEvent)
    case stderr(String)
    case exited(status: Int32)
}

/// Owns a connection-level nettop process without changing the formal
/// process-level collector used for application totals.
public final class NettopConnectionCollector: @unchecked Sendable {
    public static let executablePath = "/usr/bin/nettop"
    public static let arguments = ["-d", "-x", "-L", "0", "-s", "1"]

    public var onEvent: ((NettopConnectionCollectorEvent) -> Void)?

    private let stateLock = NSLock()
    private let parserQueue = DispatchQueue(
        label: "com.nanvon.ByteTrace.nettop-connection-parser"
    )
    private var currentState: NettopCollectorState = .stopped
    private var process: Process?
    private var processIdentifier: Int32?
    private var readGroup: DispatchGroup?
    private var stdinPipe: Pipe?
    private var parser = NettopConnectionCSVParser()
    private var didReportExit = false
    private var stderrData = Data()

    public init() {}

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
        parser = NettopConnectionCSVParser()
        stderrData.removeAll(keepingCapacity: false)
        didReportExit = false
        stateLock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = Self.arguments

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

    private func handleParserEvents(_ events: [NettopConnectionParserEvent]) {
        for event in events {
            switch event {
            case let .frameCompleted(_, _, _, isBaseline):
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

    private func emit(_ event: NettopConnectionCollectorEvent) {
        onEvent?(event)
    }

    private func emitParserEvent(_ event: NettopConnectionParserEvent) {
        guard let callback = onEvent else { return }
        if Thread.isMainThread {
            callback(.parser(event))
        } else {
            DispatchQueue.main.async {
                callback(.parser(event))
            }
        }
    }

    private static func readUntilEOF(_ handle: FileHandle, onData: @escaping (Data) -> Void) {
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    return
                }
                onData(chunk)
            } catch {
                return
            }
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
