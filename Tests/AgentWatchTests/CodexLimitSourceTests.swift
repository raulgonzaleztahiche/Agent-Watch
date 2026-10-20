@testable import Adapters
import AgentCore
import Foundation
import Testing

/// A throwaway directory holding fake `codex` executables (shell scripts speaking the same protocol).
private final class FakeCodex {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentwatch-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func script(_ body: String, name: String = "codex") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Answers like Codex, but only accepts the limits request after the `initialized` notification.
    func server(result: String, log: String? = nil) throws -> URL {
        try script("""
        echo '{"method":"server/ready"}'
        initialized=0
        while IFS= read -r line; do
          \(log.map { "echo \"$line\" >> '\($0)'" } ?? ":")
          case "$line" in
            *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
            *'"method":"initialized"'*) initialized=1 ;;
            *'"method":"account/rateLimits/read"'*)
              if [ "$initialized" = 1 ]; then echo '{"id":2,"result":\(result)}'
              else echo '{"id":2,"error":{"message":"not initialized"}}'; fi ;;
          esac
        done
        """)
    }
}

private let weeklyResult = """
{"rateLimits":{"limitId":"codex","limitName":null,"planType":"team","primary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1793086140},"secondary":null}}
"""

@Suite struct CodexLimitSourceProcessTests {
    @Test func readsLimitsAfterTheHandshakeIgnoringUnrelatedLines() throws {
        let fake = try FakeCodex()

        let limits = try CodexLimitSource(executable: try fake.server(result: weeklyResult), timeout: 10).fetchLimits()

        #expect(limits == [
            PlanLimit(
                provider: "Codex", name: "codex", plan: "team",
                windows: [LimitWindow(minutes: 10_080, usedPercent: 2, resetsAt: Date(timeIntervalSince1970: 1_793_086_140))]),
        ])
    }

    @Test func onlyTheThreeReadOnlyMessagesAreEverSent() throws {
        // Starting a thread or a turn would run the model. Only the handshake and the limits read may go out.
        let fake = try FakeCodex()
        let log = fake.directory.appendingPathComponent("received").path

        _ = try CodexLimitSource(executable: try fake.server(result: weeklyResult, log: log), timeout: 10).fetchLimits()

        let methods = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["method"] as? String
        }
        #expect(methods == ["initialize", "initialized", "account/rateLimits/read"])
    }

    @Test func anErrorResponseBecomesAReadableFailure() throws {
        let fake = try FakeCodex()
        let script = try fake.script("""
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
            *'"method":"account/rateLimits/read"'*) echo '{"id":2,"error":{"code":-32000,"message":"not signed in"}}' ;;
          esac
        done
        """)

        #expect {
            try CodexLimitSource(executable: script, timeout: 10).fetchLimits()
        } throws: { error in
            if case AgentSourceError.readFailed(let message) = error { message == "not signed in" } else { false }
        }
    }

    @Test func aSilentServerTimesOutInsteadOfHangingAndIsKilled() throws {
        let fake = try FakeCodex()
        let pidFile = fake.directory.appendingPathComponent("pid").path
        let script = try fake.script("echo $$ > '\(pidFile)'\nexec cat > /dev/null")
        let started = Date()

        #expect {
            try CodexLimitSource(executable: script, timeout: 1).fetchLimits()
        } throws: { error in
            if case AgentSourceError.readFailed = error { true } else { false }
        }

        #expect(Date().timeIntervalSince(started) < 5)
        let pid = try #require(Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { usleep(50_000) }
        }
        #expect(gone, "the spawned process must not outlive the call")
    }

    @Test func aProcessThatExitsAtOnceFailsWithoutCrashing() throws {
        // Writing to a dead pipe raises SIGPIPE; the adapter must turn that into an error.
        let fake = try FakeCodex()
        let script = try fake.script("exit 0")

        #expect {
            try CodexLimitSource(executable: script, timeout: 5).fetchLimits()
        } throws: { error in
            if case AgentSourceError.readFailed = error { true } else { false }
        }
    }

    @Test func aMissingOrNonExecutableBinaryMeansCodexIsNotInstalled() throws {
        let fake = try FakeCodex()
        let plain = fake.directory.appendingPathComponent("plain")
        try "x".write(to: plain, atomically: true, encoding: .utf8)

        for url in [URL(fileURLWithPath: "/nonexistent/codex"), plain] {
            #expect {
                try CodexLimitSource(executable: url).fetchLimits()
            } throws: { error in
                if case AgentSourceError.dataNotFound = error { true } else { false }
            }
        }
    }
}

@Suite struct CodexLimitParsingTests {
    private func parse(_ json: String) throws -> [PlanLimit] {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return CodexLimitSource.parse(result: object)
    }

    @Test func parsesASingleWeeklyWindow() throws {
        let limit = try #require(try parse(weeklyResult).first)

        #expect(limit.name == "codex" && limit.plan == "team")
        #expect(limit.windows.count == 1)
        #expect(limit.windows[0].usedPercent == 2 && limit.windows[0].minutes == 10_080)
        #expect(limit.windows[0].label == "Weekly")
    }

    @Test func parsesPrimaryAndSecondaryInThatOrder() throws {
        let limits = try parse("""
        {"rateLimits":{"limitId":"codex","planType":"plus",
         "primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1000},
         "secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":2000}}}
        """)

        #expect(limits[0].windows.map(\.label) == ["5 hours", "Weekly"])
        #expect(limits[0].windows.map(\.usedPercent) == [40, 7])
    }

    @Test func prefersTheLimitsByIDAndSortsThemByID() throws {
        let limits = try parse("""
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":1}},
         "rateLimitsByLimitId":{
           "spark":{"limitId":"spark","limitName":"Spark","primary":{"usedPercent":9,"windowDurationMins":300}},
           "codex":{"limitId":"codex","primary":{"usedPercent":3,"windowDurationMins":10080}}}}
        """)

        #expect(limits.map(\.name) == ["codex", "Spark"])
        #expect(limits.map { $0.windows[0].usedPercent } == [3, 9])
    }

    @Test func skipsWindowsThatAreNullOrHaveNoPercentage() throws {
        let limits = try parse("""
        {"rateLimits":{"limitId":"codex","primary":{"windowDurationMins":300},"secondary":null}}
        """)

        #expect(limits[0].windows.isEmpty)
    }

    @Test func aMissingResetTimeIsNilAndAnUnexpectedShapeGivesNothing() throws {
        let limit = try #require(try parse(#"{"rateLimits":{"primary":{"usedPercent":5}}}"#).first)

        #expect(limit.windows[0].resetsAt == nil && limit.windows[0].minutes == nil)
        #expect(limit.name == "codex")
        #expect(try parse(#"{"something":"else"}"#).isEmpty)
    }
}

@Suite struct CodexLocateTests {
    @Test func findsTheFirstExecutableCandidateBeforeLookingAtPATH() throws {
        let fake = try FakeCodex()
        let first = try fake.script("exit 0", name: "first")
        let second = try fake.script("exit 0", name: "second")

        let found = CodexLimitSource.locate(
            candidates: ["/nonexistent/codex", first.path, second.path], environmentPath: "")

        #expect(found == first)
    }

    @Test func fallsBackToPATHAndGivesNilWhenNothingMatches() throws {
        let fake = try FakeCodex()
        _ = try fake.script("exit 0", name: "codex")

        #expect(CodexLimitSource.locate(candidates: [], environmentPath: "/nonexistent:\(fake.directory.path)")
            == fake.directory.appendingPathComponent("codex"))
        #expect(CodexLimitSource.locate(candidates: [], environmentPath: "/nonexistent") == nil)
    }
}
