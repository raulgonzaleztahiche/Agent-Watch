import AgentCore
import Foundation

/// Reads the ChatGPT/Codex plan limits by asking `codex app-server` (JSON-RPC, one JSON object per
/// line over stdio) for `account/rateLimits/read`.
///
/// Codex owns the login: this code never reads a token or a credentials file, it only receives the
/// percentages. The protocol is marked experimental by Codex and was checked against codex-cli 0.163.
/// A process is spawned per call and always terminated, so nothing stays running in the background.
public final class CodexLimitSource: LimitSource {
    public let provider = "Codex"

    private let explicitExecutable: URL?
    private let timeout: TimeInterval

    public init(executable: URL? = nil, timeout: TimeInterval = 15) {
        self.explicitExecutable = executable
        self.timeout = timeout
    }

    public func fetchLimits() throws -> [PlanLimit] {
        guard let executable = explicitExecutable ?? Self.locate() else {
            throw AgentSourceError.dataNotFound("codex")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AgentSourceError.dataNotFound(executable.path)
        }
        // Writing to a process that already exited would otherwise raise SIGPIPE and kill the app.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw AgentSourceError.readFailed("could not start codex: \(error.localizedDescription)")
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            ChildProcess.terminate(process)
        }

        let deadline = Date().addingTimeInterval(timeout)
        func send(_ object: [String: Any]) throws {
            // Without escaping slashes, so "account/rateLimits/read" goes out exactly as spelled.
            var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            data.append(UInt8(ascii: "\n"))
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                throw AgentSourceError.readFailed("codex closed the connection")
            }
        }

        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agentwatch", "version": "0.1.0"]]])
        guard buffer.waitForResponse(id: 1, until: deadline) != nil else {
            throw AgentSourceError.readFailed("codex did not answer the handshake")
        }
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read"])
        guard let response = buffer.waitForResponse(id: 2, until: deadline) else {
            throw AgentSourceError.readFailed("codex did not report limits in time")
        }
        if let error = response["error"] as? [String: Any] {
            throw AgentSourceError.readFailed(error["message"] as? String ?? "codex returned an error")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw AgentSourceError.readFailed("unexpected answer from codex")
        }
        return Self.parse(result: result)
    }

    // MARK: - Locating the binary

    static func locate(
        candidates: [String] = defaultCandidates(),
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> URL? {
        ChildProcess.locate(name: "codex", candidates: candidates, environmentPath: environmentPath)
    }

    static func defaultCandidates() -> [String] {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + ChildProcess.homeRelative([".local/bin/codex", ".bun/bin/codex", ".npm-global/bin/codex"])
    }

    // MARK: - Parsing

    /// Uses `rateLimitsByLimitId` when present (one entry per limit), otherwise the single `rateLimits`.
    static func parse(result: [String: Any]) -> [PlanLimit] {
        let snapshots: [[String: Any]]
        if let byID = result["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            snapshots = byID.keys.sorted().compactMap { byID[$0] as? [String: Any] }
        } else if let single = result["rateLimits"] as? [String: Any] {
            snapshots = [single]
        } else {
            snapshots = []
        }
        return snapshots.map { snapshot in
            PlanLimit(
                provider: "Codex",
                name: snapshot["limitName"] as? String ?? snapshot["limitId"] as? String ?? "codex",
                plan: snapshot["planType"] as? String,
                windows: ["primary", "secondary"].compactMap { window(from: snapshot[$0] as? [String: Any]) }
            )
        }
    }

    private static func window(from raw: [String: Any]?) -> LimitWindow? {
        guard let raw, let used = (raw["usedPercent"] as? NSNumber)?.intValue else { return nil }
        return LimitWindow(
            minutes: (raw["windowDurationMins"] as? NSNumber)?.intValue,
            usedPercent: used,
            resetsAt: (raw["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }
}

/// Collects the lines written by the child process on its own thread and lets the caller wait for a
/// JSON-RPC response by id.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var lines: [Data] = []
    private var closed = false
    private let signal = DispatchSemaphore(value: 0)

    func append(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            closed = true
        } else {
            pending.append(data)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Data(pending[pending.startIndex..<newline]))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        lock.unlock()
        signal.signal()
    }

    /// The first JSON object whose `id` is `id`, or `nil` at the deadline or when the process closes its output.
    func waitForResponse(id: Int, until deadline: Date) -> [String: Any]? {
        while true {
            lock.lock()
            var found: [String: Any]?
            while !lines.isEmpty {
                let line = lines.removeFirst()
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   (object["id"] as? NSNumber)?.intValue == id
                {
                    found = object
                    break
                }
            }
            let isClosed = closed
            lock.unlock()

            if let found { return found }
            if isClosed { return nil }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = signal.wait(timeout: .now() + remaining)
        }
    }
}
