import Adapters
import AgentCore
import Foundation

// Spike: print main sessions and their subagents as a tree, newest first.
// Usage: agentwatch-cli [--hours N] [--usage]   (default: 24 h, agent tree)
//   --usage   prints token usage per model for today and the last 7 days instead
//   --limits  prints the plan limits reported by Codex and Claude instead

let usage = "usage: agentwatch-cli [--hours N] [--usage] [--limits]"
var showUsage = false
var showLimits = false
var hours: Double = 24
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--hours":
        guard let value = arguments.popFirst().flatMap(Double.init), value > 0 else {
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            exit(2)
        }
        hours = value
    case "--usage":
        showUsage = true
    case "--limits":
        showLimits = true
    default:
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
}

if showUsage {
    printUsageReport()
    exit(0)
}
if showLimits {
    printLimits()
    exit(0)
}

let now = Date()
let since = now.addingTimeInterval(-hours * 3600)
let sources: [any AgentSource] = [ClaudeCodeSource(), OpenCodeSource()]

var agents: [Agent] = []
for source in sources {
    do {
        agents += try source.fetchAgents(updatedSince: since, now: now)
    } catch {
        FileHandle.standardError.write(Data("[\(source.tool.rawValue)] \(error)\n".utf8))
    }
}

let started = Date.FormatStyle().month(.twoDigits).day(.twoDigits).hour().minute()

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? String(text.prefix(width - 1)) + "…" : text + String(repeating: " ", count: width - text.count)
}

func printNode(_ node: AgentNode, indent: String) {
    let agent = node.agent
    let label = indent + (agent.isMainSession ? "● " : "└─ ") + agent.name
    print(
        pad(agent.tool.rawValue, 12),
        pad(agent.status.rawValue, 12),
        pad(label, 26),
        pad(agent.model?.displayName ?? "-", 30),
        pad(agent.startedAt.formatted(started), 14),
        pad(agent.usage?.summary ?? "-", 24),
        TitleFormatter.clean(agent.title)
    )
    for child in node.children {
        printNode(child, indent: indent + "   ")
    }
}

print(pad("TOOL", 12), pad("STATUS", 12), pad("AGENT", 26), pad("MODEL", 30), pad("STARTED", 14), pad("TOKENS", 24), "TITLE")
for node in AgentTree.build(agents) {
    printNode(node, indent: "")
}

print()
print("last \(hours.formatted()) h")
for tool in AgentTool.allCases {
    let own = agents.filter { $0.tool == tool }
    let sessions = own.filter(\.isMainSession)
    let subagents = own.filter { !$0.isMainSession }
    let running = own.filter { $0.status == .running }.count
    print("\(tool.rawValue): \(sessions.count) sessions, \(subagents.count) subagents, \(running) running")
}

func printUsageReport() {
    let now = Date()
    let start = UsageReport.windowStart(now: now)
    var entries: [UsageEntry] = []
    for source in [ClaudeCodeSource(), OpenCodeSource()] as [any UsageSource] {
        do {
            entries += try source.fetchUsage(since: start)
        } catch {
            FileHandle.standardError.write(Data("[\(source.tool.rawValue)] \(error)\n".utf8))
        }
    }
    let report = UsageReport.make(entries: entries, now: now)
    for (title, period) in [("TODAY", report.today), ("LAST 7 DAYS", report.week)] {
        print("== \(title)")
        print(pad("MODEL", 40), pad("TOOL", 12), pad("IN", 9), pad("OUT", 9), pad("CACHE READ", 11), pad("MSGS", 6), "COST")
        for model in period.models {
            print(
                pad(model.model, 40), pad(model.tool.rawValue, 12), pad(TokenUsage.compact(model.usage.input), 9),
                pad(TokenUsage.compact(model.usage.output), 9), pad(TokenUsage.compact(model.usage.cacheRead), 11),
                pad("\(model.messages)", 6), model.cost.map { String(format: "$%.2f", $0) } ?? "-")
        }
        print(
            pad("TOTAL", 40), pad("", 12), pad(TokenUsage.compact(period.total.input), 9),
            pad(TokenUsage.compact(period.total.output), 9), pad(TokenUsage.compact(period.total.cacheRead), 11),
            pad("\(period.messages)", 6), period.cost.map { String(format: "$%.2f", $0) } ?? "-")
        print()
    }
}

func printLimits() {
    let now = Date()
    for source in [CodexLimitSource(), ClaudeLimitSource()] as [any LimitSource] {
        do {
            let limits = try source.fetchLimits()
            if limits.isEmpty { print("\(source.provider): no limits reported") }
            for limit in limits {
                print("\(limit.title)\(limit.plan.map { " (\($0))" } ?? "")")
                for window in limit.windows {
                    print("  \(pad(window.label, 22)) \(window.usedPercent)% used, resets in \(window.resetsIn(now: now) ?? "?")")
                }
            }
        } catch AgentSourceError.dataNotFound {
            print("\(source.provider): not installed")
        } catch {
            print("\(source.provider): \(error)")
        }
    }
}
