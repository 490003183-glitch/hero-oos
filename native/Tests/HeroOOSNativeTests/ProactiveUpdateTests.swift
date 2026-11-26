import CryptoKit
import Foundation
import XCTest
@testable import HeroOOSNative

@MainActor final class ProactiveUpdateTests: XCTestCase {
    private final class Installation: UpdateInstallationController {
        var canCheck = true
        var sessionInProgress = false
        var starts = 0
        var approved: [Int?] = []
        func start(availabilityChanged: @escaping (Bool) -> Void) throws {
            starts += 1; availabilityChanged(canCheck)
        }
        func checkForUpdates(approvedBuild: Int?) { approved.append(approvedBuild) }
    }
    private final class ReleaseStream: UpdateReleaseStreaming {
        var starts = 0, stops = 0
        var onBuild: ((Int) -> Void)?
        func start(onBuild: @escaping (Int) -> Void) { starts += 1; self.onBuild = onBuild }
        func stop() { stops += 1 }
    }
    private var folders: [URL] = []
    private var suites: [String] = []
    private let signingKey = Curve25519.Signing.PrivateKey()
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func date(_ raw: String) -> Date { ISO8601DateFormatter().date(from: raw)! }
    private func defaults() -> UserDefaults {
        let name = "HeroOOS.ProactiveUpdateTests.\(UUID().uuidString)"
        suites.append(name)
        let preferences = UserDefaults(suiteName: name)!
        // This suite exercises the explicitly enabled reminder workflow.
        preferences.set(true, forKey: "SUEnableAutomaticChecks")
        return preferences
    }
    private func bundle(build: Int = 35) throws -> Bundle {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hero-oos-update-tests-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let info: [String: Any] = ["CFBundleIdentifier": "com.hero-oos.update-tests.\(UUID().uuidString)",
                                   "CFBundleVersion": String(build),
                                   "SUPublicEDKey": signingKey.publicKey.rawRepresentation.base64EncodedString(),
                                   "SUFeedURL": UpdateTrust.root.appendingPathComponent("appcast.xml").absoluteString]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: folder.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: folder))
    }
    private func release(build: Int = 36, architecture: String = "universal", minOS: String = "15.0") throws -> PublishedRelease {
        let archive = Data("update-test-fixture".utf8)
        return PublishedRelease(version: "1.7.13", build: build, architecture: architecture, minOS: minOS, schema: 1,
                                url: UpdateTrust.root.appendingPathComponent("Hero-OOS-build-\(build)-\(architecture).zip"),
                                sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
                                edSignature: try signingKey.signature(for: archive).base64EncodedString(), byteLength: archive.count,
                                publishedAt: "2026-11-05T00:00:00Z")
    }
    private func verified(_ releases: [PublishedRelease]) throws -> [PublishedRelease] {
        let bytes = try JSONEncoder().encode(ReleaseCatalog(formatVersion: 1, versions: releases))
        return try UpdateTrust.catalog(bytes, signature: signingKey.signature(for: bytes).base64EncodedString(),
                                       publicKey: signingKey.publicKey.rawRepresentation.base64EncodedString())
    }
    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        folders = []; suites = []
        super.tearDown()
    }

    func testManagerSignedReleasePromptDefersAcrossRestartAndNewReleaseThenInstallsTomorrow() async throws {
        let preferences = defaults(), app = try bundle()
        var now = date("2026-11-05T12:00:00+08:00")
        var catalog = try verified([release()])
        var fetches = 0, prompts: [Int] = []
        var choice = UpdateReminderChoice.tomorrow
        let first = Installation(), restarted = Installation()
        func manager(_ installation: Installation) -> UpdateManager {
            UpdateManager(bundle: app, defaults: preferences, now: { now }, calendar: calendar,
                          catalogLoader: { fetches += 1; return catalog },
                          reminderPresenter: { prompts.append($0.build); return choice },
                          controllerFactory: { _, _ in installation }, reminderScheduling: false, canPresentReminder: { true })
        }
        let original = manager(first)
        original.start()
        XCTAssertTrue(original.ready); XCTAssertTrue(original.automatic)
        XCTAssertEqual(UpdateManager.reminderButtonTitles, ["立即更新", "明天提醒"])
        await original.checkAutomatically()
        XCTAssertEqual(prompts, [36]); XCTAssertTrue(first.approved.isEmpty)
        XCTAssertEqual(preferences.object(forKey: ProactiveUpdateReminder.deferredUntilKey) as? Date,
                       date("2026-11-06T00:00:00+08:00"))

        now = date("2026-11-05T21:00:00+08:00")
        catalog = try verified([release(build: 37), release()])
        let reopened = manager(restarted); reopened.start()
        await reopened.checkAutomatically()
        XCTAssertEqual(fetches, 1); XCTAssertEqual(prompts, [36]); XCTAssertTrue(restarted.approved.isEmpty)

        now = date("2026-11-06T00:01:00+08:00"); choice = .installNow
        await reopened.checkAutomatically()
        XCTAssertEqual(fetches, 2); XCTAssertEqual(prompts, [36, 37])
        XCTAssertEqual(restarted.approved.count, 1); XCTAssertEqual(restarted.approved[0], 37)
        XCTAssertNil(preferences.object(forKey: ProactiveUpdateReminder.deferredUntilKey))
        XCTAssertTrue(reopened.message.contains("下载并验证"))
    }

    func testExistingOptOutAndRollbackPauseSuppressPromptsButManualCheckStillWorks() async throws {
        let app = try bundle(), release = try release()
        for paused in [false, true] {
            let preferences = defaults(), installation = Installation()
            preferences.set(paused, forKey: UpdateManager.pauseKey)
            preferences.set(paused, forKey: "SUEnableAutomaticChecks")
            var fetches = 0, prompts = 0
            let manager = UpdateManager(bundle: app, defaults: preferences,
                                        catalogLoader: { fetches += 1; return [release] },
                                        reminderPresenter: { _ in prompts += 1; return .installNow },
                                        controllerFactory: { _, _ in installation }, reminderScheduling: false, canPresentReminder: { true })
            manager.start(); await manager.checkAutomatically()
            XCTAssertFalse(manager.automatic); XCTAssertEqual(fetches, 0); XCTAssertEqual(prompts, 0)
            manager.check()
            XCTAssertEqual(installation.approved.count, 1); XCTAssertNil(installation.approved[0])
            manager.setAutomatic(true)
            await manager.checkAutomatically()
            XCTAssertTrue(manager.automatic); XCTAssertFalse(preferences.bool(forKey: UpdateManager.pauseKey))
            XCTAssertEqual(fetches, 1); XCTAssertEqual(prompts, 1)
        }
    }

    func testNewPreferenceSurvivesSparkleSchedulerBeingDisabledAndUserTurningOff() throws {
        let preferences = defaults(), app = try bundle()
        preferences.set(true, forKey: UpdateManager.automaticKey)
        preferences.set(false, forKey: "SUEnableAutomaticChecks")
        let installation = Installation()
        let manager = UpdateManager(bundle: app, defaults: preferences, controllerFactory: { _, _ in installation }, reminderScheduling: false)
        manager.start(); XCTAssertTrue(manager.automatic)
        manager.setAutomatic(false)
        let reopened = UpdateManager(bundle: app, defaults: preferences)
        XCTAssertFalse(reopened.automatic)
    }

    func testOfflineFailureStaysSilentThenRetriesWithoutManualCheck() async throws {
        let preferences = defaults(), installation = Installation(), app = try bundle(), item = try release()
        var now = date("2026-11-05T12:00:00+08:00"), online = false
        var fetches = 0, prompts = 0
        let manager = UpdateManager(bundle: app, defaults: preferences, now: { now },
                                    catalogLoader: { fetches += 1; if !online { throw URLError(.notConnectedToInternet) }; return [item] },
                                    reminderPresenter: { _ in prompts += 1; return .installNow },
                                    controllerFactory: { _, _ in installation }, reminderScheduling: false, canPresentReminder: { true })
        manager.start(); await manager.checkAutomatically()
        XCTAssertEqual(prompts, 0); XCTAssertTrue(installation.approved.isEmpty)
        XCTAssertTrue(manager.message.contains("将自动重试"))
        online = true; now.addTimeInterval(61)
        await manager.checkAutomatically()
        XCTAssertEqual(fetches, 2); XCTAssertEqual(prompts, 1); XCTAssertEqual(installation.approved.first!, 36)
    }

    func testCurrentOlderUnsupportedAndIncompatibleReleasesDoNotPrompt() async throws {
        let items = try [release(build: 35), release(build: 34), release(build: 37, architecture: "x86_64"),
                         release(build: 38, minOS: "99.0"), release(build: 39, minOS: "invalid")]
        var prompts = 0
        let reminder = ProactiveUpdateReminder(defaults: defaults(), currentBuild: 35, architecture: "arm64", systemVersion: "15.0.0",
                                               fetch: { items }, prompt: { _ in prompts += 1; return .installNow }, install: { _ in XCTFail("No supported update") })
        await reminder.check(enabled: { true }, available: { true })
        XCTAssertEqual(prompts, 0)
    }

    func testDisablingWhileCatalogLoadsOrActiveInstallerPreventsPrompt() async throws {
        let installation = Installation(), item = try release()
        var manager: UpdateManager!
        var prompts = 0, fetches = 0
        manager = UpdateManager(bundle: try bundle(), defaults: defaults(),
                                catalogLoader: { fetches += 1; manager.setAutomatic(false); return [item] },
                                reminderPresenter: { _ in prompts += 1; return .installNow },
                                controllerFactory: { _, _ in installation }, reminderScheduling: false, canPresentReminder: { true })
        manager.start(); installation.sessionInProgress = true
        await manager.checkAutomatically(); XCTAssertEqual(fetches, 0)
        installation.sessionInProgress = false
        await manager.checkAutomatically()
        XCTAssertEqual(fetches, 1); XCTAssertEqual(prompts, 0); XCTAssertTrue(installation.approved.isEmpty)
    }

    func testTomorrowUsesCalendarBoundaryAcrossDaylightSavingChange() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date("2026-11-01T00:30:00-07:00")
        let preferences = defaults()
        let reminder = ProactiveUpdateReminder(defaults: preferences, currentBuild: 35, architecture: "arm64", systemVersion: "15.0.0",
                                               now: { now }, calendar: calendar,
                                               fetch: { [try self.release()] }, prompt: { _ in .tomorrow }, install: { _ in XCTFail() })
        await reminder.check(enabled: { true }, available: { true })
        XCTAssertEqual(reminder.deferredUntil, date("2026-11-02T00:00:00-08:00"))
    }

    func testReleaseNotificationBypassesRecentLaunchCheckAndDuplicatesDoNotFetchOrPrompt() async throws {
        let installation = Installation(), item = try release()
        var catalog: [PublishedRelease] = []
        var fetches = 0, prompts = 0
        let manager = UpdateManager(bundle: try bundle(), defaults: defaults(),
                                    catalogLoader: { fetches += 1; return catalog },
                                    reminderPresenter: { _ in prompts += 1; return .installNow },
                                    controllerFactory: { _, _ in installation }, reminderScheduling: false, canPresentReminder: { true })
        manager.start(); await manager.checkAutomatically()
        XCTAssertEqual(fetches, 1)
        await manager.receiveReleaseNotification(build: 35)
        XCTAssertEqual(fetches, 1)
        catalog = try verified([item])
        // The build was published immediately after the launch check, well
        // within its normal 60-second activation debounce.
        await manager.receiveReleaseNotification(build: 36)
        XCTAssertEqual(fetches, 2); XCTAssertEqual(prompts, 1)
        XCTAssertEqual(installation.approved.count, 1)
        await manager.receiveReleaseNotification(build: 36)
        await manager.receiveReleaseNotification(build: 36)
        XCTAssertEqual(fetches, 2); XCTAssertEqual(prompts, 1)
    }

    func testReleaseNotificationDuringDeferralWaitsAndDeadlineRemindsWithoutAnotherServerEvent() async throws {
        let installation = Installation(), preferences = defaults()
        var now = date("2026-11-05T12:00:00+08:00")
        var catalog = try verified([release()])
        var fetches = 0, prompts: [Int] = []
        var choice = UpdateReminderChoice.tomorrow
        let manager = UpdateManager(bundle: try bundle(), defaults: preferences, now: { now }, calendar: calendar,
                                    catalogLoader: { fetches += 1; return catalog },
                                    reminderPresenter: { prompts.append($0.build); return choice },
                                    controllerFactory: { _, _ in installation }, reminderScheduling: false, canPresentReminder: { true })
        manager.start(); await manager.receiveReleaseNotification(build: 36)
        catalog = try verified([release(build: 37), release()])
        await manager.receiveReleaseNotification(build: 37)
        await manager.receiveReleaseNotification(build: 37)
        XCTAssertEqual(fetches, 1); XCTAssertEqual(prompts, [36])
        await manager.remindAfterDeferral()
        XCTAssertEqual(fetches, 1)
        now = date("2026-11-06T00:00:01+08:00"); choice = .installNow
        await manager.remindAfterDeferral()
        XCTAssertEqual(fetches, 2); XCTAssertEqual(prompts, [36, 37])
        XCTAssertEqual(installation.approved.first!, 37)
    }

    func testFailedReleaseVerificationIsNotMarkedHandledAndReconnectRetriesSameBuild() async throws {
        let installation = Installation(), item = try release()
        var online = false, fetches = 0, prompts = 0
        let manager = UpdateManager(bundle: try bundle(), defaults: defaults(),
                                    catalogLoader: {
                                        fetches += 1
                                        if !online { throw URLError(.notConnectedToInternet) }
                                        return try self.verified([item])
                                    },
                                    reminderPresenter: { _ in prompts += 1; return .installNow },
                                    controllerFactory: { _, _ in installation }, reminderScheduling: false, canPresentReminder: { true })
        manager.start(); await manager.receiveReleaseNotification(build: 36)
        XCTAssertEqual(fetches, 1); XCTAssertEqual(prompts, 0)
        online = true
        await manager.receiveReleaseNotification(build: 36)
        XCTAssertEqual(fetches, 2); XCTAssertEqual(prompts, 1)
        await manager.receiveReleaseNotification(build: 36)
        XCTAssertEqual(fetches, 2)
    }

    func testModalOpenedDuringCatalogFetchDoesNotConsumeReleaseNotification() async throws {
        let installation = Installation(), item = try release()
        var available = true, fetches = 0, prompts = 0
        let manager = UpdateManager(bundle: try bundle(), defaults: defaults(),
                                    catalogLoader: { fetches += 1; if fetches == 1 { available = false }; return [item] },
                                    reminderPresenter: { _ in prompts += 1; return .installNow },
                                    controllerFactory: { _, _ in installation }, reminderScheduling: false, canPresentReminder: { available })
        manager.start(); await manager.receiveReleaseNotification(build: 36)
        XCTAssertEqual(prompts, 0)
        available = true
        await manager.receiveReleaseNotification(build: 36)
        XCTAssertEqual(fetches, 2); XCTAssertEqual(prompts, 1)
    }

    func testPublicReleaseEndpointIsSeparateFromArchiveTrustAndHintsAreBounded() {
        XCTAssertTrue(UpdateReleaseStream.permits(UpdateReleaseStream.endpoint))
        XCTAssertFalse(UpdateTrust.permits(UpdateReleaseStream.endpoint))
        let request = UpdateReleaseStream.request()
        XCTAssertEqual(request.url, UpdateReleaseStream.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)
        for raw in ["http://cloud.example.invalid/v1/update-events", "https://example.com/v1/update-events",
                    "https://cloud.example.invalid:8443/v1/update-events", "https://root@cloud.example.invalid/v1/update-events",
                    "https://cloud.example.invalid/v1/update-events?token=secret", "https://cloud.example.invalid/v1/events",
                    "https://cloud.example.invalid/v1/%75pdate-events", "https://cloud.example.invalid/v1/update-events#ignored"] {
            XCTAssertFalse(UpdateReleaseStream.permits(URL(string: raw)!), raw)
        }
        XCTAssertEqual(UpdateReleaseStream.releaseBuild(from: ServerSentEvent(event: "release", data: "{\"releaseBuild\":36}")), 36)
        for event in [ServerSentEvent(event: "state", data: "{\"releaseBuild\":36}"),
                      ServerSentEvent(event: "release", data: "{\"releaseBuild\":-1}"),
                      ServerSentEvent(event: "release", data: "{\"releaseBuild\":true}"),
                      ServerSentEvent(event: "release", data: String(repeating: "x", count: 1_025))] {
            XCTAssertNil(UpdateReleaseStream.releaseBuild(from: event))
        }
        XCTAssertEqual((0...6).map { UpdateReleaseStream.reconnectDelay(failures: $0) }, [1, 2, 4, 8, 16, 32, 60])
    }

    func testManagerWiresReleaseStreamAndStopsItWhenAutomaticRemindersAreDisabled() async throws {
        let installation = Installation(), stream = ReleaseStream()
        var catalog: [PublishedRelease] = [], fetches = 0, prompts = 0
        let manager = UpdateManager(bundle: try bundle(), defaults: defaults(),
                                    catalogLoader: { fetches += 1; return catalog },
                                    reminderPresenter: { _ in prompts += 1; return .installNow },
                                    controllerFactory: { _, _ in installation }, releaseStreamFactory: { stream },
                                    reminderScheduling: true, canPresentReminder: { true })
        manager.start()
        XCTAssertEqual(stream.starts, 1)
        for _ in 0..<50 { if fetches > 0 { break }; await Task.yield() }
        XCTAssertEqual(fetches, 1)
        catalog = try verified([release()])
        stream.onBuild?(36)
        for _ in 0..<50 { if prompts > 0 { break }; await Task.yield() }
        XCTAssertEqual(fetches, 2); XCTAssertEqual(prompts, 1)
        manager.setAutomatic(false)
        XCTAssertEqual(stream.stops, 1)
        // A stale in-flight stream callback cannot restart checking after opt-out.
        stream.onBuild?(37)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fetches, 2)
    }
}
