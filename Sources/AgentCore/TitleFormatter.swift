import Foundation

public enum TitleFormatter {
    /// Keeps the first line, drops the legacy " (@explore subagent)" suffix and truncates.
    public static func clean(_ title: String?, maxLength: Int = 70) -> String {
        guard var text = title?.split(separator: "\n").first.map(String.init) else { return "" }
        if let range = text.range(of: #" \(@[\w-]+ subagent\)$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }
}
