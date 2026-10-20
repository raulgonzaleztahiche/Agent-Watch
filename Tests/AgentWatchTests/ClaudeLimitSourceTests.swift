@testable import Adapters
import AgentCore
import Foundation
import Testing

private let canary = TimeZone(identifier: "Atlantic/Canary")!
private var canaryCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = canary
    return calendar
}

private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026) -> Date {
    canaryCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Tue 2026-10-20 10:00 in the Canary Islands.
private let now = date(10, 20, 10)

private let usageText =
    #"You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 40% used · resets Oct 20 at 1:29pm (Atlantic/Canary)\nCurrent week (all models): 16% used · resets Oct 22 at 12:59pm (Atlantic/Canary)\n\nWhat's contributing to your limits usage?\nLast 24h · 376 requests · 4 sessions"#

/// The JSON `claude -p /usage --output-format json` prints: a local command, so everything is zero.
private func resultJSON(
    turns: Int = 0, cost: Double = 0, input: Int = 0, output: Int = 0, apiMs: Int = 0,
    modelUsage: String = "{}", usage: Bool = true, text: String = usageText
) -> String {
    let usageJSON = usage ? #""usage":{"input_tokens":\#(input),"output_tokens":\#(output)},"# : ""
    return #"{"type":"result","subtype":"success","is_error":false,"num_turns":\#(turns),"duration_api_ms":\#(apiMs),"total_cost_usd":\#(cost),\#(usageJSON)"modelUsage":\#(modelUsage),"local_command":true,"result":"\#(text)"}"#
}

private final class FakeClaude {
    let directory: URL
    var argsFile: String { directory.appendingPathComponent("args").path }
    var runsFile: String { directory.appendingPathComponent("runs").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentwatch-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func script(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("claude")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Records its arguments and how many times it ran, then prints `json` (read from a file, so
    /// quotes and apostrophes in the text cannot break the shell script).
    func printing(_ json: String, exitCode: Int = 0) throws -> URL {
        let output = directory.appendingPathComponent("output.json")
        try json.write(to: output, atomically: true, encoding: .utf8)
        return try script("""
        echo "$@" > '\(argsFile)'
        echo run >> '\(runsFile)'
        cat '\(output.path)'
        exit \(exitCode)
        """)
    }

    var runCount: Int {
        ((try? String(contentsOfFile: runsFile, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
}

private func isReadFailed(_ error: Error, containing text: String? = nil) -> Bool {
    guard case AgentSourceError.readFailed(let message) = error else { return false }
    return text.map(message.contains) ?? true
}

@Suite struct ClaudeLimitSourceProcessTests {
    @Test func readsTheSessionAndWeeklyWindows() throws {
        let fake = try FakeClaude()

        let limits = try ClaudeLimitSource(executable: try fake.printing(resultJSON()), timeout: 10).fetchLimits(now: now)

        #expect(limits.count == 1)
        #expect(limits[0].provider == "Claude" && limits[0].title == "Claude")
        #expect(limits[0].windows == [
            LimitWindow(minutes: 300, usedPercent: 40, resetsAt: date(10, 20, 13, 29), name: "Session"),
            LimitWindow(minutes: 10_080, usedPercent: 16, resetsAt: date(10, 22, 12, 59), name: "Weekly"),
        ])
    }

    @Test func theCommandLineIsExactlyTheLocalSlashCommandInSafeMode() throws {
        // The prompt must be the literal /usage slash command and nothing else: anything that is not a
        // local command could be sent to the model.
        let fake = try FakeClaude()
        _ = try ClaudeLimitSource(executable: try fake.printing(resultJSON()), timeout: 10).fetchLimits(now: now)

        let received = try String(contentsOfFile: fake.argsFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(received == "-p /usage --output-format json --safe-mode --no-session-persistence")
        #expect(ClaudeLimitSource.arguments[0...1] == ["-p", "/usage"])
        #expect(ClaudeLimitSource.arguments.contains("--no-session-persistence"))
        #expect(ClaudeLimitSource.arguments.contains("--safe-mode"))
    }

    @Test(arguments: [
        ("a model turn", resultJSON(turns: 1)),
        ("a cost", resultJSON(cost: 0.01)),
        ("input tokens", resultJSON(input: 5)),
        ("output tokens", resultJSON(output: 1)),
        ("time in the API", resultJSON(apiMs: 120)),
        ("model usage", resultJSON(modelUsage: #"{"claude-haiku-5-5":{"inputTokens":3}}"#)),
        ("missing figures", resultJSON(usage: false)),
    ])
    func anyHintOfSpendingFailsAndDisablesTheSourceForGood(label: String, json: String) throws {
        let fake = try FakeClaude()
        let source = ClaudeLimitSource(executable: try fake.printing(json), timeout: 10)

        #expect(throws: AgentSourceError.self, "\(label) must be rejected") { try source.fetchLimits(now: now) }
        #expect {
            try source.fetchLimits(now: now)
        } throws: { isReadFailed($0, containing: "must never use tokens") }

        #expect(fake.runCount == 1, "after a violation claude must not be run again (\(label))")
    }

    @Test func aPlainFailureIsNotAViolationSoItIsRetriedLater() throws {
        let fake = try FakeClaude()
        let source = ClaudeLimitSource(executable: try fake.printing("", exitCode: 1), timeout: 10)

        #expect { try source.fetchLimits(now: now) } throws: { isReadFailed($0, containing: "status 1") }
        #expect { try source.fetchLimits(now: now) } throws: { isReadFailed($0, containing: "status 1") }

        #expect(fake.runCount == 2)
    }

    @Test func outputWithoutLimitsIsAReadableFailureAndNotADisable() throws {
        let fake = try FakeClaude()
        let source = ClaudeLimitSource(
            executable: try fake.printing(resultJSON(text: "You are using API usage billing.")), timeout: 10)

        #expect { try source.fetchLimits(now: now) } throws: { isReadFailed($0, containing: "no usage limits") }
        #expect { try source.fetchLimits(now: now) } throws: { isReadFailed($0, containing: "no usage limits") }
        #expect(fake.runCount == 2)
    }

    @Test func acceptsTheResultInsideAnArrayToo() throws {
        let fake = try FakeClaude()
        let array = "[{\"type\":\"system\"}," + resultJSON() + "]"

        let limits = try ClaudeLimitSource(executable: try fake.printing(array), timeout: 10).fetchLimits(now: now)

        #expect(limits[0].windows.count == 2)
    }

    @Test func aSilentProcessTimesOutAndIsKilled() throws {
        let fake = try FakeClaude()
        let pidFile = fake.directory.appendingPathComponent("pid").path
        let source = ClaudeLimitSource(executable: try fake.script("echo $$ > '\(pidFile)'\nexec sleep 30"), timeout: 1)
        let started = Date()

        #expect { try source.fetchLimits(now: now) } throws: { isReadFailed($0, containing: "in time") }

        #expect(Date().timeIntervalSince(started) < 6)
        let pid = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<60 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { usleep(50_000) }
        }
        #expect(gone, "the spawned process must not outlive the call")
    }

    @Test func aMissingOrNonExecutableBinaryMeansClaudeIsNotInstalled() throws {
        let fake = try FakeClaude()
        let plain = fake.directory.appendingPathComponent("plain")
        try "x".write(to: plain, atomically: true, encoding: .utf8)

        for url in [URL(fileURLWithPath: "/nonexistent/claude"), plain] {
            #expect {
                try ClaudeLimitSource(executable: url).fetchLimits(now: now)
            } throws: { error in
                if case AgentSourceError.dataNotFound = error { true } else { false }
            }
        }
    }
}

@Suite struct ClaudeSpendGuardTests {
    private func violation(_ json: String) throws -> String? {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return ClaudeLimitSource.spendViolation(in: object)
    }

    @Test func aFreeLocalCommandPasses() throws {
        #expect(try violation(resultJSON()) == nil)
    }

    @Test func everyMissingFigureIsAViolationBecauseUnverifiableMeansNotAllowed() throws {
        for missing in ["num_turns", "total_cost_usd"] {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(resultJSON().utf8)) as? [String: Any])
            var trimmed = object
            trimmed.removeValue(forKey: missing)
            #expect(ClaudeLimitSource.spendViolation(in: trimmed) != nil, "\(missing)")
        }
        #expect(try violation(#"{"num_turns":0,"total_cost_usd":0,"usage":{"input_tokens":0}}"#) != nil)
        #expect(try violation("{}") != nil)
    }

    @Test func nonNumericFiguresAreNotTrusted() throws {
        #expect(try violation(#"{"num_turns":"0","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}"#) != nil)
    }
}

@Suite struct ClaudeUsageParsingTests {
    private func parse(_ text: String) -> [LimitWindow] {
        ClaudeLimitSource.parse(output: text, now: now, calendar: canaryCalendar)
    }

    @Test func parsesSessionAndWeekLinesIgnoringEverythingElse() {
        let windows = parse("""
        You are currently using your subscription
        Current session: 40% used · resets Oct 20 at 1:29pm (Atlantic/Canary)
        Current week (all models): 16% used · resets Oct 22 at 12:59pm (Atlantic/Canary)

        Last 24h · 376 requests · 4 sessions
          75% of your usage was at >150k context
        """)

        #expect(windows.map(\.label) == ["Session", "Weekly"])
        #expect(windows.map(\.usedPercent) == [40, 16])
        #expect(windows.map(\.minutes) == [300, 10_080])
        #expect(windows[0].resetsAt == date(10, 20, 13, 29))
        #expect(windows[1].resetsAt == date(10, 22, 12, 59))
    }

    @Test func aQualifiedWeekKeepsItsQualifier() {
        let windows = parse("""
        Current week (all models): 16% used
        Current week (Opus): 3% used · resets Oct 22 at 12:59pm (Atlantic/Canary)
        Current week (Sonnet only): 9% used
        """)

        #expect(windows.map(\.label) == ["Weekly", "Weekly · Opus", "Weekly · Sonnet only"])
    }

    @Test func aLineWithoutAResetTimeStillCounts() {
        let windows = parse("Current session: 5% used")

        #expect(windows.count == 1 && windows[0].resetsAt == nil && windows[0].usedPercent == 5)
    }

    @Test func roundsDecimalPercentagesAndIgnoresColourCodes() {
        let windows = parse("\u{1B}[1mCurrent session: 16.4% used · resets 1pm (Atlantic/Canary)\u{1B}[0m")

        #expect(windows.map(\.usedPercent) == [16])
    }

    @Test func anUnknownWindowKeepsTheNameItIsGiven() {
        let windows = parse("Current extra usage: 2% used")

        #expect(windows[0].label == "extra usage" && windows[0].minutes == nil)
    }

    @Test func unrelatedTextGivesNothing() {
        #expect(parse("Unknown command: /usage").isEmpty)
        #expect(parse("").isEmpty)
    }
}

@Suite struct ClaudeResetDateTests {
    private func reset(_ text: String, now: Date = now) -> Date? {
        ClaudeLimitSource.parseReset(text, now: now, calendar: canaryCalendar)
    }

    @Test func parsesADateAndATimeInTheGivenZone() {
        #expect(reset("Oct 22 at 12:59pm (Atlantic/Canary)") == date(10, 22, 12, 59))
        #expect(reset("Nov 3 at 9am (Atlantic/Canary)") == date(11, 3, 9))
    }

    @Test func theZoneInTheTextWinsOverTheCalendar() {
        let madrid = reset("Oct 20 at 1:29pm (Europe/Madrid)")

        #expect(madrid == Calendar(identifier: .gregorian).date(from: {
            var c = DateComponents(year: 2026, month: 10, day: 20, hour: 13, minute: 29)
            c.timeZone = TimeZone(identifier: "Europe/Madrid")
            return c
        }()))
    }

    @Test func aTimeWithoutADateIsTheNextTimeItComesRound() {
        #expect(reset("1:29pm") == date(10, 20, 13, 29))
        #expect(reset("9am") == date(10, 21, 9), "9am has already passed today, so it is tomorrow")
    }

    @Test func twelveAMAndTwelvePM() {
        #expect(reset("Oct 21 at 12am (Atlantic/Canary)") == date(10, 21, 0))
        #expect(reset("Oct 21 at 12pm (Atlantic/Canary)") == date(10, 21, 12))
    }

    @Test func aDateEarlyInTheNextYearRollsOver() {
        let lateDecember = date(12, 31, 20)

        #expect(reset("Jan 1 at 1:00am (Atlantic/Canary)", now: lateDecember) == date(1, 1, 1, year: 2027))
    }

    @Test func anUnknownZoneFallsBackToTheCalendarZoneInsteadOfFailing() {
        #expect(reset("Oct 22 at 12:59pm (Not/AZone)") == date(10, 22, 12, 59))
    }

    @Test func unreadableTextGivesNil() {
        #expect(reset("soon") == nil)
        #expect(reset("Foo 3 at 1pm") == nil)
        #expect(reset("") == nil)
    }
}
