import AgentCore
import Foundation

/// Reads Claude Code transcripts under `~/.claude/projects/<project>/`:
/// - main sessions: `<sessionId>.jsonl`
/// - subagents: `<sessionId>/subagents/agent-<id>.jsonl` plus `.meta.json`
///
/// Subagent completion: the parent transcript contains a `tool_result` for the meta's
/// `toolUseId`. Main session activity: the last assistant turn did not end with
/// `end_turn` (or the user wrote after it) and the transcript changed recently.
public final class ClaudeCodeSource: AgentSource {
    public let tool = AgentTool.claudeCode

    private let projectsRoot: URL
    private var transcriptCache: [String: Transcript] = [:]

    public init(projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects"))
    {
        self.projectsRoot = projectsRoot
    }

    public func fetchAgents(updatedSince: Date, now: Date) throws -> [Agent] {
        try requireProjectsRoot()
        let urls = transcriptURLs(modifiedSince: updatedSince)
        return urls.sessions.compactMap { mainSession(at: $0, now: now) }
            + urls.subagents.compactMap { subagent(at: $0, now: now) }
    }

    private func requireProjectsRoot() throws {
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else {
            throw AgentSourceError.dataNotFound(projectsRoot.path)
        }
    }

    private func transcriptURLs(modifiedSince: Date) -> (sessions: [URL], subagents: [URL]) {
        var sessions: [URL] = []
        var subagents: [URL] = []
        for project in subdirectories(of: projectsRoot) {
            sessions += jsonlFiles(in: project, modifiedSince: modifiedSince)
            for session in subdirectories(of: project) {
                subagents += jsonlFiles(
                    in: session.appendingPathComponent("subagents"), modifiedSince: modifiedSince)
            }
        }
        return (sessions, subagents)
    }

    // MARK: - Discovery

    private func subdirectories(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// Filters by mtime before parsing: transcripts can be large.
    private func jsonlFiles(in directory: URL, modifiedSince: Date) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { url in
            guard url.pathExtension == "jsonl" else { return false }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return modified >= modifiedSince
        }
    }

    // MARK: - Mapping

    private func mainSession(at url: URL, now: Date) -> Agent? {
        guard let transcript = cachedTranscript(at: url) else { return nil }
        let waitingForModel = transcript.lastStopReason != "end_turn" || transcript.userWroteAfterAssistant
        let status: AgentStatus =
            waitingForModel && ActivityPolicy.isRecent(transcript.updatedAt, now: now) ? .running : .idle

        return Agent(
            id: transcript.sessionID,
            tool: .claudeCode,
            parentSessionID: nil,
            name: "main",
            title: transcript.title,
            model: transcript.model.map(Self.modelRef),
            status: status,
            startedAt: transcript.startedAt,
            updatedAt: transcript.updatedAt,
            usage: transcript.usage.isEmpty ? nil : transcript.usage,
            directory: transcript.directory
        )
    }

    private func subagent(at url: URL, now: Date) -> Agent? {
        guard let transcript = cachedTranscript(at: url), let agentID = transcript.agentID else { return nil }
        let meta = readMeta(for: url)

        let status: AgentStatus
        if meta?.finished == true || parentHasResult(for: meta?.toolUseId, transcriptURL: url) {
            status = .succeeded
        } else {
            status = ActivityPolicy.statusWithoutTerminalSignal(updatedAt: transcript.updatedAt, now: now)
        }

        return Agent(
            id: agentID,
            tool: .claudeCode,
            parentSessionID: transcript.sessionID,
            name: meta?.agentType ?? "subagent",
            title: meta?.description,
            model: transcript.model.map(Self.modelRef),
            status: status,
            startedAt: transcript.startedAt,
            updatedAt: transcript.updatedAt,
            usage: transcript.usage.isEmpty ? nil : transcript.usage,
            directory: transcript.directory
        )
    }

    private static func modelRef(_ id: String) -> ModelRef {
        ModelRef(provider: "anthropic", id: id, variant: nil)
    }

    private struct Meta: Decodable {
        let agentType: String?
        let description: String?
        let toolUseId: String?
        let finished: Bool?
    }

    private func readMeta(for transcriptURL: URL) -> Meta? {
        let metaURL = transcriptURL.deletingPathExtension().appendingPathExtension("meta.json")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// `<project>/<sessionId>/subagents/x.jsonl` -> `<project>/<sessionId>.jsonl`
    private func parentHasResult(for toolUseID: String?, transcriptURL: URL) -> Bool {
        guard let toolUseID else { return false }
        let sessionDir = transcriptURL.deletingLastPathComponent().deletingLastPathComponent()
        let parentURL = sessionDir.deletingLastPathComponent()
            .appendingPathComponent(sessionDir.lastPathComponent + ".jsonl")
        guard let data = try? Data(contentsOf: parentURL, options: .mappedIfSafe) else { return false }
        return data.range(of: Data("\"tool_use_id\":\"\(toolUseID)\"".utf8)) != nil
    }

    // MARK: - Transcript parsing (cached by mtime + size)

    /// One model response: what the usage report is built from.
    private struct Message {
        let id: String
        let model: String?
        let date: Date
        let usage: TokenUsage
    }

    private struct Transcript {
        let modifiedAt: Date
        let size: Int
        let sessionID: String
        let agentID: String?
        let directory: String?
        let model: String?
        let title: String?
        let usage: TokenUsage
        let messages: [Message]
        let lastStopReason: String?
        let userWroteAfterAssistant: Bool
        let startedAt: Date
        let updatedAt: Date
    }

    private func cachedTranscript(at url: URL) -> Transcript? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? -1
        if let cached = transcriptCache[url.path], cached.modifiedAt == modifiedAt, cached.size == size {
            return cached
        }
        guard let parsed = parseTranscript(at: url, modifiedAt: modifiedAt, size: size) else { return nil }
        transcriptCache[url.path] = parsed
        return parsed
    }

    private func parseTranscript(at url: URL, modifiedAt: Date, size: Int) -> Transcript? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let isoDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        var sessionID: String?
        var agentID: String?
        var directory: String?
        var model: String?
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
        var lastStopReason: String?
        var userWroteAfterAssistant = false
        // A message is written once per content block with identical usage: keep one per id.
        var messagesByID: [String: Message] = [:]
        var rowDate: Date?
        var startedAt: Date?
        var updatedAt: Date?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            sessionID = sessionID ?? row["sessionId"] as? String
            agentID = agentID ?? row["agentId"] as? String
            // The latest cwd: a session can move to another project (e.g. after a directory change).
            directory = row["cwd"] as? String ?? directory
            rowDate = nil
            if let stamp = row["timestamp"] as? String, let date = try? isoDate.parse(stamp) {
                startedAt = startedAt ?? date
                updatedAt = date
                rowDate = date
            }
            switch row["type"] as? String {
            case "assistant":
                // Only assistant rows carry the agent's own model.
                if let message = row["message"] as? [String: Any] {
                    model = message["model"] as? String ?? model
                    lastStopReason = message["stop_reason"] as? String
                    if let id = message["id"] as? String, let raw = message["usage"] as? [String: Any],
                       let date = messagesByID[id]?.date ?? rowDate
                    {
                        messagesByID[id] = Message(
                            id: id, model: message["model"] as? String, date: date, usage: Self.tokenUsage(from: raw))
                    }
                }
                userWroteAfterAssistant = false
            case "user":
                userWroteAfterAssistant = true
            case "custom-title":
                customTitle = row["customTitle"] as? String ?? customTitle
            case "ai-title":
                aiTitle = row["aiTitle"] as? String ?? aiTitle
            case "last-prompt":
                lastPrompt = row["lastPrompt"] as? String ?? lastPrompt
            default:
                break
            }
        }

        guard let sessionID, let startedAt, let updatedAt else { return nil }
        return Transcript(
            modifiedAt: modifiedAt, size: size, sessionID: sessionID, agentID: agentID,
            directory: directory, model: model, title: customTitle ?? aiTitle ?? lastPrompt,
            usage: messagesByID.values.map(\.usage).reduce(TokenUsage(), +),
            messages: Array(messagesByID.values),
            lastStopReason: lastStopReason, userWroteAfterAssistant: userWroteAfterAssistant,
            startedAt: startedAt, updatedAt: updatedAt
        )
    }

    private static func tokenUsage(from raw: [String: Any]) -> TokenUsage {
        func count(_ key: String) -> Int { (raw[key] as? NSNumber)?.intValue ?? 0 }
        let thinking = ((raw["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? NSNumber)?.intValue ?? 0
        return TokenUsage(
            input: count("input_tokens"), output: count("output_tokens"), reasoning: thinking,
            cacheRead: count("cache_read_input_tokens"), cacheWrite: count("cache_creation_input_tokens")
        )
    }
}

extension ClaudeCodeSource: UsageSource {
    /// Every assistant message at or after `since`, from sessions and subagents.
    /// Message ids are unique across files, but they are deduplicated anyway.
    public func fetchUsage(since: Date) throws -> [UsageEntry] {
        try requireProjectsRoot()
        let urls = transcriptURLs(modifiedSince: since)
        var byID: [String: UsageEntry] = [:]
        for url in urls.sessions + urls.subagents {
            guard let transcript = cachedTranscript(at: url) else { continue }
            for message in transcript.messages where message.date >= since && !message.usage.isEmpty {
                byID[message.id] = UsageEntry(
                    tool: .claudeCode,
                    model: message.model.map { ModelRef(provider: "anthropic", id: $0, variant: nil) },
                    date: message.date, usage: message.usage)
            }
        }
        return Array(byID.values)
    }
}
