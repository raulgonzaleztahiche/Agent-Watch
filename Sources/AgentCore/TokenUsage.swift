import Foundation

/// Cumulative token counters for one session or subagent.
/// `reasoning` is informational: tools disagree on whether it is already part of `output`,
/// so it is never added to another counter.
public struct TokenUsage: Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var reasoning: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var isEmpty: Bool { self == TokenUsage() }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }

    /// e.g. "697k in · 27k out"
    public var summary: String {
        "\(Self.compact(input)) in · \(Self.compact(output)) out"
    }

    /// Full breakdown for a tooltip.
    public var detail: String {
        """
        input: \(input)
        output: \(output)
        reasoning: \(reasoning)
        cache read: \(cacheRead)
        cache write: \(cacheWrite)
        """
    }

    /// 950 -> "950", 1234 -> "1.2k", 10_280_704 -> "10.3M"
    public static func compact(_ count: Int) -> String {
        func scaled(_ value: Double, _ suffix: String) -> String {
            let rounded = (value * 10).rounded() / 10
            return (rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)) + suffix
        }
        let value = Double(count)
        switch count {
        case ..<1_000: return "\(count)"
        case ..<999_950: return scaled(value / 1_000, "k")
        case ..<999_950_000: return scaled(value / 1_000_000, "M")
        default: return scaled(value / 1_000_000_000, "B")
        }
    }
}
