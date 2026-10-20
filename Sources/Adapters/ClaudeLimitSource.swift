import AgentCore
import Foundation

/// Reads the Claude plan limits by running `claude -p "/usage"`: the slash command prints the
/// session (5-hour) and weekly percentages using Claude Code's own login. This code never reads a
/// token or a credentials file.
///
/// **This must never spend tokens.** `/usage` is a local command, and that is checked on every call
/// rather than assumed: the JSON result must report zero turns, zero cost and zero tokens. If it does
/// not, or if that cannot be verified, the call fails and the source disables itself for the rest of
/// the run, so a change in Claude Code can cost at most one request, never a stream of them.
public final class ClaudeLimitSource: LimitSource {
    public let provider = "Claude"

    /// The exact command line. `--safe-mode` skips hooks, MCP servers and plugins (faster, and no
    /// side effects of the user's own configuration); `--no-session-persistence` stops a transcript
    /// being saved for every call. The prompt is always the literal `/usage` slash command.
    static let arguments = ["-p", "/usage", "--output-format", "json", "--safe-mode", "--no-session-persistence"]

    private let explicitExecutable: URL?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var disabledReason: String?

    public init(executable: URL? = nil, timeout: TimeInterval = 30) {
        self.explicitExecutable = executable
        self.timeout = timeout
    }

    public func fetchLimits() throws -> [PlanLimit] {
        try fetchLimits(now: Date())
    }

    func fetchLimits(now: Date) throws -> [PlanLimit] {
        if let reason = currentDisabledReason() { throw AgentSourceError.readFailed(reason) }
        guard let executable = explicitExecutable ?? Self.locate() else {
            throw AgentSourceError.dataNotFound("claude")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AgentSourceError.dataNotFound(executable.path)
        }

        let run = try ChildProcess.run(
            executable: executable, arguments: Self.arguments,
            currentDirectory: FileManager.default.temporaryDirectory, timeout: timeout)
        guard run.status == 0 else {
            throw AgentSourceError.readFailed("claude exited with status \(run.status)")
        }

        let result = try Self.resultObject(from: run.output)
        if let violation = Self.spendViolation(in: result) {
            let reason = "disabled: claude /usage \(violation); it must never use tokens"
            disable(reason)
            throw AgentSourceError.readFailed(reason)
        }

        let text = (result["result"] as? String) ?? ""
        let windows = Self.parse(output: text, now: now)
        guard !windows.isEmpty else {
            throw AgentSourceError.readFailed("no usage limits in the output of claude /usage")
        }
        return [PlanLimit(provider: "Claude", name: "claude", plan: nil, windows: windows)]
    }

    private func currentDisabledReason() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return disabledReason
    }

    private func disable(_ reason: String) {
        lock.lock()
        disabledReason = reason
        lock.unlock()
    }

    // MARK: - The "no tokens" guard

    /// Why this call cannot be proven free, or `nil` when it demonstrably was: no turns, no API time,
    /// no cost and no tokens. A missing field is a violation too: unverifiable means not allowed.
    static func spendViolation(in result: [String: Any]) -> String? {
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        let usage = result["usage"] as? [String: Any]

        guard let turns = number(result["num_turns"]),
              let cost = number(result["total_cost_usd"]),
              let input = number(usage?["input_tokens"]),
              let output = number(usage?["output_tokens"])
        else { return "reported no usage figures, so it cannot be verified as free" }

        if turns != 0 { return "ran \(Int(turns)) model turn(s)" }
        if cost != 0 { return "reported a cost" }
        if input != 0 || output != 0 { return "reported token usage" }
        if let apiTime = number(result["duration_api_ms"]), apiTime != 0 { return "spent time in the API" }
        if let models = result["modelUsage"] as? [String: Any], !models.isEmpty { return "reported model usage" }
        return nil
    }

    /// The `result` object of `--output-format json` (a single object, or an array that contains it).
    static func resultObject(from data: Data) throws -> [String: Any] {
        let json = try? JSONSerialization.jsonObject(with: data)
        if let object = json as? [String: Any] { return object }
        if let array = json as? [[String: Any]], let result = array.last(where: { $0["type"] as? String == "result" }) {
            return result
        }
        throw AgentSourceError.readFailed("unexpected output from claude")
    }

    // MARK: - Locating the binary

    static func locate(
        candidates: [String] = defaultCandidates(),
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> URL? {
        ChildProcess.locate(name: "claude", candidates: candidates, environmentPath: environmentPath)
    }

    static func defaultCandidates() -> [String] {
        ChildProcess.homeRelative([".local/bin/claude", ".claude/local/claude", ".bun/bin/claude", ".npm-global/bin/claude"])
            + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    // MARK: - Parsing

    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^Current\s+(?<what>.+?):\s*(?<pct>\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\s+(?<reset>.+?))?\s*$"#)
    private static let resetRegex = try! NSRegularExpression(
        pattern: #"^(?:(?<mon>[A-Za-z]{3})[a-z]*\s+(?<day>\d{1,2})\s+at\s+)?(?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ap>[ap]m)(?:\s*\((?<tz>[^)]+)\))?$"#,
        options: [.caseInsensitive])
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")

    /// Reads lines such as `Current session: 40% used · resets Oct 20 at 1:29pm (Atlantic/Canary)`.
    static func parse(output: String, now: Date, calendar: Calendar = .current) -> [LimitWindow] {
        let plain = ansi.stringByReplacingMatches(
            in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "")
        return plain.split(whereSeparator: \.isNewline).compactMap { line -> LimitWindow? in
            let text = String(line).trimmingCharacters(in: .whitespaces)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = lineRegex.firstMatch(in: text, range: range),
                  let what = capture("what", in: match, of: text),
                  let percent = capture("pct", in: match, of: text).flatMap(Double.init)
            else { return nil }
            let identity = windowIdentity(for: what)
            return LimitWindow(
                minutes: identity.minutes, usedPercent: Int(percent.rounded()),
                resetsAt: capture("reset", in: match, of: text).flatMap { parseReset($0, now: now, calendar: calendar) },
                name: identity.name)
        }
    }

    /// "session" is the 5-hour window; "week (all models)" is the weekly one; anything else keeps its own name.
    static func windowIdentity(for what: String) -> (minutes: Int?, name: String) {
        let lower = what.lowercased()
        if lower.contains("session") { return (300, "Session") }
        if lower.hasPrefix("week") {
            let qualifier = what.firstMatch(of: /\(([^)]+)\)/)?.output.1.trimmingCharacters(in: .whitespaces)
            if let qualifier, qualifier.lowercased() != "all models" { return (10_080, "Weekly · \(qualifier)") }
            return (10_080, "Weekly")
        }
        return (nil, what)
    }

    /// "Oct 20 at 1:29pm (Atlantic/Canary)", "1:29pm" or "9am". With no date it is the next time
    /// that hour comes round; with a date, the next year if this year's would already be long past.
    static func parseReset(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = resetRegex.firstMatch(in: text, range: range),
              let hour12 = capture("h", in: match, of: text).flatMap(Int.init),
              let meridiem = capture("ap", in: match, of: text)?.lowercased()
        else { return nil }

        var calendar = calendar
        if let name = capture("tz", in: match, of: text), let zone = TimeZone(identifier: name) {
            calendar.timeZone = zone
        }
        let hour = hour12 % 12 + (meridiem == "pm" ? 12 : 0)
        let minute = capture("m", in: match, of: text).flatMap(Int.init) ?? 0

        guard let monthName = capture("mon", in: match, of: text), let day = capture("day", in: match, of: text).flatMap(Int.init) else {
            guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let month = months.firstIndex(of: monthName.lowercased()).map({ $0 + 1 }) else { return nil }
        let year = calendar.component(.year, from: now)
        func date(in year: Int) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
        }
        guard let thisYear = date(in: year) else { return nil }
        return thisYear < now.addingTimeInterval(-12 * 3_600) ? date(in: year + 1) : thisYear
    }

    private static func capture(_ name: String, in match: NSTextCheckingResult, of text: String) -> String? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
