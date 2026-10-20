import Adapters
import AgentCore
import Foundation

// Spike: print main sessions and their subagents as a tree, newest first.
// Usage: agentwatch-cli [--hours N]   (default: 24)

let usage = "usage: agentwatch-cli [--hours N]"
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
    default:
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(2)
    }
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

/// Drops the legacy " (@explore subagent)" suffix and keeps one line.
func cleanTitle(_ title: String?) -> String {
    guard var text = title?.split(separator: "\n").first.map(String.init) else { return "" }
    if let range = text.range(of: #" \(@[\w-]+ subagent\)$"#, options: .regularExpression) {
        text.removeSubrange(range)
    }
    return text.count > 70 ? String(text.prefix(69)) + "…" : text
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
        cleanTitle(agent.title)
    )
    for child in node.children {
        printNode(child, indent: indent + "   ")
    }
}

print(pad("TOOL", 12), pad("STATUS", 12), pad("AGENT", 26), pad("MODEL", 30), pad("STARTED", 14), "TITLE")
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
