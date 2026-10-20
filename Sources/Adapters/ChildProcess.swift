import AgentCore
import Foundation

/// Helpers shared by the adapters that ask another tool for information by running it.
enum ChildProcess {
    /// A Finder-launched app has a minimal PATH, so the usual install locations are tried before PATH.
    static func locate(name: String, candidates: [String], environmentPath: String) -> URL? {
        let onPath = environmentPath.split(separator: ":").map { "\($0)/\(name)" }
        return (candidates + onPath)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func homeRelative(_ paths: [String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return paths.map { "\(home)/\($0)" }
    }

    /// Asks the process to stop, and kills it if it has not exited after a second.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Runs a command to completion and returns its standard output. Standard input is closed and
    /// standard error discarded, so the command can never wait for a terminal. The process is
    /// terminated if it outlives `timeout`.
    static func run(
        executable: URL, arguments: [String], currentDirectory: URL, timeout: TimeInterval
    ) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        let collector = Collector()
        pipe.fileHandleForReading.readabilityHandler = { collector.append($0.availableData) }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw AgentSourceError.readFailed("could not start \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            terminate(process)
            throw AgentSourceError.readFailed("\(executable.lastPathComponent) did not answer in time")
        }
        // The pipe closes just after the process exits; give the reader a moment to drain it.
        collector.waitUntilClosed(timeout: 1)
        return (process.terminationStatus, collector.data)
    }
}

/// Accumulates what a child process writes, from the thread that reads its pipe.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let closed = DispatchSemaphore(value: 0)

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func append(_ chunk: Data) {
        if chunk.isEmpty {
            closed.signal()
            return
        }
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    func waitUntilClosed(timeout: TimeInterval) {
        _ = closed.wait(timeout: .now() + timeout)
    }
}
