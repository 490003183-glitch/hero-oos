import Foundation

enum UpdateReminderChoice { case installNow, tomorrow }

/// The deferral applies to all releases, including one published later that day.
/// It is a local calendar day boundary, not a fixed 24-hour interval (DST-safe).
@MainActor final class ProactiveUpdateReminder {
    static let deferredUntilKey = "HeroOOS.updates.remindAfter"
    private let defaults: UserDefaults
    private let currentBuild: Int
    private let architecture: String
    private let systemVersion: String
    private let now: () -> Date
    private let calendar: Calendar
    private let fetch: () async throws -> [PublishedRelease]
    private let prompt: (PublishedRelease) async -> UpdateReminderChoice
    private let install: (PublishedRelease) -> Void
    private let minimumInterval: TimeInterval
    private var lastAttempt: Date?
    private(set) var checking = false
    private(set) var lastError: String?
    private(set) var lastVerifiedBuild: Int?

    init(defaults: UserDefaults, currentBuild: Int, architecture: String, systemVersion: String,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         minimumInterval: TimeInterval = 60,
         fetch: @escaping () async throws -> [PublishedRelease],
         prompt: @escaping (PublishedRelease) async -> UpdateReminderChoice,
         install: @escaping (PublishedRelease) -> Void) {
        self.defaults = defaults; self.currentBuild = currentBuild
        self.architecture = architecture; self.systemVersion = systemVersion
        self.now = now; self.calendar = calendar; self.minimumInterval = minimumInterval
        self.fetch = fetch; self.prompt = prompt; self.install = install
    }

    var deferredUntil: Date? { defaults.object(forKey: Self.deferredUntilKey) as? Date }
    var isDeferred: Bool { deferredUntil.map { now() < $0 } ?? false }

    @discardableResult
    func check(enabled: () -> Bool, available: () -> Bool, force: Bool = false) async -> Int? {
        guard !checking, enabled(), available(), !isDeferred else { return nil }
        let date = now()
        if !force, let lastAttempt, date.timeIntervalSince(lastAttempt) >= 0,
           date.timeIntervalSince(lastAttempt) < minimumInterval { return nil }
        checking = true; lastAttempt = date
        defer { checking = false }
        do {
            let releases = try await fetch()
            lastError = nil
            let newestBuild = releases.map(\.build).max() ?? currentBuild
            lastVerifiedBuild = newestBuild
            // The user may turn updates off, open a modal or start a manual
            // installation while the network request is still in flight.
            guard enabled(), available(), !isDeferred else { return nil }
            guard let release = releases.filter(isCompatible).max(by: { $0.build < $1.build }) else { return newestBuild }
            switch await prompt(release) {
            case .tomorrow:
                let start = calendar.startOfDay(for: now())
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) {
                    defaults.set(tomorrow, forKey: Self.deferredUntilKey)
                }
            case .installNow:
                guard enabled(), available() else { return newestBuild }
                defaults.removeObject(forKey: Self.deferredUntilKey)
                install(release)
            }
            return newestBuild
        } catch {
            // A failed/offline check only updates status. A reconnect, pending
            // release retry or activation can retry without a failure dialog.
            lastError = error.localizedDescription
            return nil
        }
    }

    private func isCompatible(_ release: PublishedRelease) -> Bool {
        guard currentBuild > 0, release.build > currentBuild,
              release.architecture == architecture || release.architecture == "universal",
              Self.validVersion(release.minOS), Self.validVersion(systemVersion) else { return false }
        return systemVersion.compare(release.minOS, options: .numeric) != .orderedAscending
    }

    private static func validVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
}
