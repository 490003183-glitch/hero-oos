import Foundation

public enum TaskBackground {
    public static let limit = 2000
    // Match the server's Unicode code-point count, not UTF-8 bytes or UTF-16 units.
    public static func count(_ text: String) -> Int { text.unicodeScalars.count }
    public static func clipped(_ text: String, limit: Int = TaskBackground.limit) -> String {
        guard count(text) > limit else { return text }
        var remaining = max(0, limit)
        return String(text.prefix { character in
            let size = String(character).unicodeScalars.count
            guard size <= remaining else { return false }
            remaining -= size
            return true
        })
    }
    public static func validate(_ value: JSON) throws {
        if value == .null { return }
        guard case .string(let text) = value, count(text) <= limit else {
            throw RuntimeError("invalid_task_background", "任务基础背景最多 2000 字，请缩短后再保存。")
        }
    }
}
