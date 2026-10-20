import AgentCore
import Foundation
import Testing

private func agent(_ id: String, parent: String? = nil, startedAt minutes: Double) -> Agent {
    let date = Date(timeIntervalSince1970: minutes * 60)
    return Agent(
        id: id, tool: .openCode, parentSessionID: parent, name: "x", title: nil,
        model: nil, status: .idle, startedAt: date, updatedAt: date
    )
}

@Suite struct AgentTreeTests {
    @Test func nestsSubagentsUnderTheirSession() {
        let tree = AgentTree.build([
            agent("sub", parent: "main", startedAt: 2),
            agent("main", startedAt: 1),
        ])

        #expect(tree.map(\.agent.id) == ["main"])
        #expect(tree[0].children.map(\.agent.id) == ["sub"])
    }

    @Test func nestsSubagentsOfSubagents() {
        let tree = AgentTree.build([
            agent("main", startedAt: 1),
            agent("child", parent: "main", startedAt: 2),
            agent("grandchild", parent: "child", startedAt: 3),
        ])

        #expect(tree[0].children[0].children.map(\.agent.id) == ["grandchild"])
    }

    @Test func keepsSubagentWithMissingParentAtTopLevel() {
        let tree = AgentTree.build([agent("orphan", parent: "outside-window", startedAt: 1)])

        #expect(tree.map(\.agent.id) == ["orphan"])
        #expect(tree[0].children.isEmpty)
    }

    @Test func ordersSiblingsNewestFirst() {
        let tree = AgentTree.build([
            agent("old", startedAt: 1),
            agent("new", startedAt: 5),
            agent("mid", startedAt: 3),
        ])

        #expect(tree.map(\.agent.id) == ["new", "mid", "old"])
    }
}

@Suite struct ModelRefTests {
    @Test func showsProviderAndVariant() {
        #expect(ModelRef(provider: "openai", id: "gpt-6-luna", variant: "high").displayName
            == "openai/gpt-6-luna (high)")
    }

    @Test func hidesDefaultVariantAndMissingProvider() {
        #expect(ModelRef(provider: nil, id: "m", variant: "default").displayName == "m")
    }
}
