import Foundation

struct ADBProcessResult: Sendable {
    let status: Int32
    let stderr: String
    let stdout: Data

    var succeeded: Bool { status == 0 }
}

/// A running adb child process with raw binary stdout, writable stdin, and
/// cancellation. `ADB.run` captures everything to a temp file and is fine for
/// short commands; transfers need the bytes as they arrive.
final class ADBStream: @unchecked Sendable {
    let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()

    private var stdoutContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private let stdoutStream: AsyncThrowingStream<Data, Error>
    private var stderrData = Data()
    private var stdoutData = Data()
    /// Listing commands need their output on exit; transfers consume it as it arrives.
    private let capturesOutput: Bool
    private var status: Int32?
    private var waiters: [CheckedContinuation<ADBProcessResult, Never>] = []
    private var started = false

    init(adbURL: URL, environment: [String: String], arguments: [String], capturesOutput: Bool = false) {
        self.capturesOutput = capturesOutput
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        stdoutStream = AsyncThrowingStream { continuation = $0 }
        stdoutContinuation = continuation

        process.executableURL = adbURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    func start() throws {
        guard !started else { return }
        started = true

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.finishStdout()
            } else {
                if self.capturesOutput {
                    self.stdoutData.append(data)
                }
                self.stdoutContinuation?.yield(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self.lock.lock()
                if self.stderrData.count < 131_072 {
                    self.stderrData.append(data)
                }
                self.lock.unlock()
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            // Let the pipe handlers drain before reporting completion.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                self.finish(status: process.terminationStatus)
            }
        }

        try process.run()
    }

    func write(_ data: Data) throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func closeInput() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// The process's stdout as it arrives. The stream finishes at EOF.
    func output() -> AsyncThrowingStream<Data, Error> {
        stdoutStream
    }

    /// Waits for exit and returns the combined stderr plus the status.
    func wait() async -> ADBProcessResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                let stderr = String(decoding: stderrData, as: UTF8.self)
                let captured = stdoutData
                lock.unlock()
                continuation.resume(returning: ADBProcessResult(status: status, stderr: stderr, stdout: captured))
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func terminate() {
        closeInput()
        if process.isRunning {
            process.terminate()
        } else {
            finish(status: status ?? -1)
        }
    }

    // MARK: - Completion

    private func finishStdout() {
        lock.lock()
        let continuation = stdoutContinuation
        stdoutContinuation = nil
        lock.unlock()
        continuation?.finish()
    }

    private func finish(status: Int32) {
        lock.lock()
        if self.status != nil {
            lock.unlock()
            return
        }
        self.status = status
        let continuation = stdoutContinuation
        stdoutContinuation = nil
        let stderr = String(decoding: stderrData, as: UTF8.self)
        let captured = stdoutData
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()

        continuation?.finish()
        let result = ADBProcessResult(status: status, stderr: stderr, stdout: captured)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}
