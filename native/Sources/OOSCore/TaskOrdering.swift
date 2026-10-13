import Foundation

public enum TaskOrdering {
    public static func key(_ mode: String) -> String { mode == "board" ? "boardOrder" : "listOrder" }
    public static func sorted(_ fallback: [Record], mode: String) -> [Record] {
        let key = key(mode)
        return fallback.enumerated().sorted { a, b in
            let av = a.element[key], bv = b.element[key]
            if case .number(let x) = av, case .number(let y) = bv, x != y { return x < y }
            if av != .null && bv == .null { return true }
            if av == .null && bv != .null { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
