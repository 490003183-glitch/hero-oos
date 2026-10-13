import Foundation

/// Monotonic, deterministic hover timing; leaving or interacting cancels the
/// candidate so a delayed callback cannot resurrect a preview for an old card.
struct TaskGraphHoverDwell {
    static let delay: TimeInterval = 0.5
    private(set) var candidate: String?
    private var enteredAt: TimeInterval?

    @discardableResult mutating func update(_ id: String?, at time: TimeInterval) -> Bool {
        guard candidate != id else { return false }
        candidate = id; enteredAt = id == nil ? nil : time
        return true
    }
    func ready(at time: TimeInterval) -> String? {
        guard let candidate, let enteredAt, time - enteredAt >= Self.delay else { return nil }
        return candidate
    }
    mutating func cancel() { candidate = nil; enteredAt = nil }
}
