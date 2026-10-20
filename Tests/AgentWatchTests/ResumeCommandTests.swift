import AgentCore
import Foundation
import Testing

private func agent(
    id: String = "ses_abc", tool: AgentTool, parent: String? = nil, directory: String? = "/Users/me/code/demo"
) -> Agent {
    Agent(
        id: id, tool: tool, parentSessionID: parent, name: "x", title: nil, model: nil, status: .idle,
        startedAt: .now, updatedAt: .now, directory: directory)
}

@Suite struct ResumeCommandTests {
    @Test func claudeCodeResumesBySessionIDInItsFolder() {
        let session = agent(id: "ed7e066b-1737-4938-9337-3be010403890", tool: .claudeCode)

        #expect(ResumeCommand.make(for: session)
            == "cd /Users/me/code/demo && claude --resume ed7e066b-1737-4938-9337-3be010403890")
    }

    @Test func openCodeResumesWithTheSessionFlag() {
        #expect(ResumeCommand.make(for: agent(tool: .openCode)) == "cd /Users/me/code/demo && opencode --session ses_abc")
    }

    @Test func withoutAFolderItIsJustTheCommand() {
        #expect(ResumeCommand.make(for: agent(tool: .openCode, directory: nil)) == "opencode --session ses_abc")
        #expect(ResumeCommand.make(for: agent(tool: .openCode, directory: "")) == "opencode --session ses_abc")
    }

    @Test func subagentsCannotBeResumed() {
        #expect(ResumeCommand.make(for: agent(tool: .claudeCode, parent: "main")) == nil)
    }

    @Test func quotesFoldersWithSpacesAndApostrophes() {
        #expect(ResumeCommand.shellQuoted("/Users/me/My Projects/demo") == "'/Users/me/My Projects/demo'")
        #expect(ResumeCommand.shellQuoted("/Users/me/it's here") == #"'/Users/me/it'\''s here'"#)
        #expect(ResumeCommand.shellQuoted("a;rm -rf ~") == "'a;rm -rf ~'")
        #expect(ResumeCommand.shellQuoted("$(whoami)") == "'$(whoami)'")
        #expect(ResumeCommand.shellQuoted("") == "''")
    }

    @Test func leavesPlainPathsUnquoted() {
        #expect(ResumeCommand.shellQuoted("/Users/me/code/demo-2.0") == "/Users/me/code/demo-2.0")
    }
}
