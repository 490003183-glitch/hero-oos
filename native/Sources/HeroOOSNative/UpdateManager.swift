import AppKit
import Combine
import CryptoKit
import Foundation
import Sparkle
import SwiftUI

struct PublishedRelease: Codable, Identifiable, Equatable {
    var version: String
    var build: Int
    var architecture: String
    var minOS: String
    var schema: Int
    var url: URL
    var sha256: String
    var edSignature: String
    var byteLength: Int
    var publishedAt: String
    var id: Int { build }
}

struct ReleaseCatalog: Codable {
    var formatVersion: Int
    var versions: [PublishedRelease]
}

enum UpdateTrust {
    static var root: URL {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https" else {
            return URL(string: "https://cloud.example.invalid/updates/v3/")!
        }
        return url.deletingLastPathComponent().appendingPathComponent("")
    }
    static let maxArchiveBytes = 256 * 1_024 * 1_024
    static func permits(_ url: URL) -> Bool {
        // URL.path can drop the root URL's trailing slash. Keep the directory
        // boundary, so a sibling such as /updates/v30 cannot match /updates/v3.
        let pathPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.scheme == "https" && url.host == root.host && (url.port == nil || url.port == 443) &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
        url.path.hasPrefix(pathPrefix) && !url.pathComponents.contains("..")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "HeroOOS.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func verify(_ data: Data, signature: String, publicKey: String) throws {
        guard let rawKey = Data(base64Encoded: publicKey), rawKey.count == 32,
              let rawSignature = Data(base64Encoded: signature), rawSignature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              key.isValidSignature(rawSignature, for: data) else {
            throw failure("更新签名校验失败，未使用下载内容。")
        }
    }
    static func catalog(_ data: Data, signature: String, publicKey: String) throws -> [PublishedRelease] {
        guard data.count <= 256 * 1_024 else { throw failure("版本索引过大。") }
        try verify(data, signature: signature, publicKey: publicKey)
        let catalog = try JSONDecoder().decode(ReleaseCatalog.self, from: data)
        guard catalog.formatVersion == 1, catalog.versions.count <= 10,
              Set(catalog.versions.map(\.build)).count == catalog.versions.count else {
            throw failure("版本索引格式无效。")
        }
        for release in catalog.versions {
            guard release.build > 0, release.schema > 0, !release.version.isEmpty,
                  release.version.count <= 40, release.minOS.count <= 20,
                  ["arm64", "x86_64", "universal"].contains(release.architecture),
                  permits(release.url), release.url.pathExtension == "zip",
                  release.byteLength > 0, release.byteLength <= maxArchiveBytes,
                  release.sha256.count == 64, release.sha256.allSatisfy(\.isHexDigit),
                  Data(base64Encoded: release.edSignature)?.count == 64 else {
                throw failure("版本索引含不安全或不完整的条目。")
            }
        }
        return catalog.versions.sorted { $0.build > $1.build }
    }
    static func verifyArchive(_ data: Data, release: PublishedRelease, publicKey: String) throws {
        guard data.count == release.byteLength, data.count <= maxArchiveBytes else { throw failure("安装包大小不符。") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else { throw failure("安装包 SHA-256 校验失败。") }
        try verify(data, signature: release.edSignature, publicKey: publicKey)
    }
}

/// Restrict redirects as well as initial URLs; never silently switch to an arbitrary host.
private final class UpdateDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(UpdateTrust.permits) == true ? request : nil)
    }
}

/// The manager's tests use this same installation boundary without opening
/// Sparkle windows, accessing the Keychain, or replacing a real application.
@MainActor protocol UpdateInstallationController: AnyObject {
    var canCheck: Bool { get }
    var sessionInProgress: Bool { get }
    func start(availabilityChanged: @escaping (Bool) -> Void) throws
    func checkForUpdates(approvedBuild: Int?)
}

@MainActor private final class ConsentedUpdateUserDriver: SPUStandardUserDriver {
    var approvedBuild: Int?
    private var approvedSession = false

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // The app's own dialog has just supplied consent. Avoid leaving the
        // standard checking window behind when showUpdateFound replies directly.
        if approvedBuild == nil { super.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if approvedBuild == Int(appcastItem.versionString), !appcastItem.isInformationOnlyUpdate {
            approvedBuild = nil; approvedSession = true
            reply(.install)
        } else {
            approvedBuild = nil; approvedSession = false
            super.showUpdateFound(with: appcastItem, state: state, reply: reply)
        }
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if approvedSession { reply(.install) }
        else { super.showReady(toInstallAndRelaunch: reply) }
    }

    override func dismissUpdateInstallation() {
        approvedBuild = nil; approvedSession = false
        super.dismissUpdateInstallation()
    }
}

@MainActor private final class SparkleInstallationController: UpdateInstallationController {
    private let driver: ConsentedUpdateUserDriver
    private let updater: SPUUpdater
    private var observation: NSKeyValueObservation?
    var canCheck: Bool { updater.canCheckForUpdates }
    var sessionInProgress: Bool { updater.sessionInProgress }

    init(bundle: Bundle, delegate: SPUUpdaterDelegate) {
        driver = ConsentedUpdateUserDriver(hostBundle: bundle, delegate: nil)
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
    }

    func start(availabilityChanged: @escaping (Bool) -> Void) throws {
        // App-owned, signed-catalog reminders are the only automatic scheduler.
        // Leaving Sparkle's independent scheduler running could install on quit
        // even after the user chose to wait until tomorrow.
        updater.automaticallyDownloadsUpdates = false
        updater.automaticallyChecksForUpdates = false
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { value, _ in
            Task { @MainActor in availabilityChanged(value.canCheckForUpdates) }
        }
        try updater.start()
    }

    func checkForUpdates(approvedBuild: Int?) {
        driver.approvedBuild = approvedBuild
        updater.checkForUpdates()
    }
}

@MainActor final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var automatic = false
    @Published private(set) var ready = false
    @Published private(set) var canCheck = false
    @Published private(set) var busy = false
    @Published private(set) var versions: [PublishedRelease] = []
    @Published private(set) var message = ""
    @Published private(set) var preparedArchive: URL?
    private var controller: UpdateInstallationController?
    private let bundle: Bundle
    private let defaults: UserDefaults
    private let publicKey: String
    private let now: () -> Date
    private let calendar: Calendar
    private let catalogLoader: (() async throws -> [PublishedRelease])?
    private let reminderPresenter: (PublishedRelease) async -> UpdateReminderChoice
    private let controllerFactory: (Bundle, SPUUpdaterDelegate) -> UpdateInstallationController
    private let releaseStreamFactory: () -> UpdateReleaseStreaming
    private let reminderScheduling: Bool
    private let canPresentReminder: () -> Bool
    private var reminderTask: Task<Void, Never>?
    private var releaseRetryTask: Task<Void, Never>?
    private var releaseStream: UpdateReleaseStreaming?
    private var pendingAnnouncedBuild = 0
    private var handledAnnouncementBuild = 0
    private var releaseRetryAttempt = 0
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private let downloadDelegate = UpdateDownloadDelegate()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: downloadDelegate, delegateQueue: nil)
    static let pauseKey = "HeroOOS.updates.pausedForManualRollback"
    static let automaticKey = "HeroOOS.updates.proactive.enabled"
    private lazy var reminder = ProactiveUpdateReminder(
        defaults: defaults,
        currentBuild: Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0,
        architecture: Self.architecture, systemVersion: Self.systemVersion,
        now: now, calendar: calendar,
        fetch: { [weak self] in
            guard let self else { return [] }
            if let catalogLoader = self.catalogLoader { return try await catalogLoader() }
            return try await self.fetchVerifiedVersions()
        },
        prompt: reminderPresenter,
        install: { [weak self] release in
            self?.message = "正在下载并验证 \(release.version)，完成保存后安装并重新打开。"
            self?.controller?.checkForUpdates(approvedBuild: release.build)
        })

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         catalogLoader: (() async throws -> [PublishedRelease])? = nil,
         reminderPresenter: ((PublishedRelease) async -> UpdateReminderChoice)? = nil,
         controllerFactory: ((Bundle, SPUUpdaterDelegate) -> UpdateInstallationController)? = nil,
         releaseStreamFactory: (() -> UpdateReleaseStreaming)? = nil,
         reminderScheduling: Bool = true, canPresentReminder: (() -> Bool)? = nil) {
        self.bundle = bundle; self.defaults = defaults
        self.now = now; self.calendar = calendar; self.catalogLoader = catalogLoader
        self.reminderPresenter = reminderPresenter ?? Self.presentReminder
        self.controllerFactory = controllerFactory ?? { SparkleInstallationController(bundle: $0, delegate: $1) }
        self.releaseStreamFactory = releaseStreamFactory ?? { UpdateReleaseStream() }
        self.reminderScheduling = reminderScheduling
        self.canPresentReminder = canPresentReminder ?? {
            NSApp.modalWindow == nil && !NSApp.windows.contains { $0.attachedSheet != nil }
        }
        publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        super.init()
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ??
            defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? false
        if defaults.bool(forKey: Self.pauseKey) { automatic = false }
    }

    deinit {
        reminderTask?.cancel()
        releaseRetryTask?.cancel()
        for (center, token) in notificationTokens { center.removeObserver(token) }
    }

    /// Call once after stores and the app delegate's termination/save barrier are attached.
    func start() {
        guard controller == nil else { return }
        guard Data(base64Encoded: publicKey)?.count == 32,
              bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String == UpdateTrust.root.appendingPathComponent("appcast.xml").absoluteString else {
            message = "可信更新尚未配置：需要发布公钥与 HTTPS 更新源。"; return
        }
        // Save the existing choice before disabling Sparkle's separate scheduler.
        defaults.set(automatic, forKey: Self.automaticKey)
        let updater = controllerFactory(bundle, self)
        if defaults.bool(forKey: Self.pauseKey) {
            message = "手动版本回退准备中：自动升级已暂停，可在这里重新开启。"
        }
        do {
            try updater.start { [weak self] value in
                self?.canCheck = value
                if value { self?.resumePendingReleaseCheck() }
            }
            controller = updater; ready = true; canCheck = updater.canCheck
            if reminderScheduling { startReminderScheduling() }
        } catch { message = "更新服务未能启动：\(error.localizedDescription)" }
    }

    func setAutomatic(_ enabled: Bool) {
        guard ready else { return }
        automatic = enabled
        defaults.set(enabled, forKey: Self.automaticKey)
        if enabled { defaults.removeObject(forKey: Self.pauseKey) }
        if reminderScheduling {
            configureReleaseStream()
            scheduleDeferredReminder()
            if enabled { Task { await checkAutomatically(force: true) } }
        }
    }

    func check() {
        guard ready && canCheck && !reminder.checking else { return }
        controller?.checkForUpdates(approvedBuild: nil)
    }

    func checkAutomatically(force: Bool = false) async {
        guard ready, automatic, !defaults.bool(forKey: Self.pauseKey) else { return }
        let announcementAtStart = pendingAnnouncedBuild
        let verifiedBuild = await reminder.check(
            enabled: { self.automatic && !self.defaults.bool(forKey: Self.pauseKey) },
            available: { !self.busy && self.controller?.canCheck == true &&
                self.controller?.sessionInProgress == false && self.canPresentReminder() }, force: force)
        if let verifiedBuild {
            handledAnnouncementBuild = max(handledAnnouncementBuild, verifiedBuild)
            releaseRetryAttempt = 0
            releaseRetryTask?.cancel(); releaseRetryTask = nil
        }
        guard automatic, !defaults.bool(forKey: Self.pauseKey) else { return }
        if let until = reminder.deferredUntil, reminder.isDeferred {
            message = "已选择明天提醒（\(until.formatted(date: .abbreviated, time: .omitted))）。"
        } else if let error = reminder.lastError {
            message = "自动更新暂时无法连接，将自动重试：\(error)"
        }
        scheduleDeferredReminder()
        if pendingAnnouncedBuild > handledAnnouncementBuild && reminder.lastError != nil {
            schedulePendingReleaseRetry()
        } else if pendingAnnouncedBuild > announcementAtStart {
            // A newer release notification arrived while the old catalog or
            // dialog was in flight. Do one fresh verification for that event.
            resumePendingReleaseCheck()
        }
    }

    private func startReminderScheduling() {
        configureReleaseStream()
        scheduleDeferredReminder()
        Task { [weak self] in await self?.checkAutomatically() }
        for (center, name) in [(NotificationCenter.default, NSApplication.didBecomeActiveNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.checkAutomatically() }
            }
            notificationTokens.append((center, token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumePendingReleaseCheck() }
        }
        notificationTokens.append((center, token))
    }

    private var currentBuild: Int { Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    /// The stream hint never authorizes an installation or bypasses signature
    /// validation. Reconnects may repeat the same build without another dialog.
    func receiveReleaseNotification(build: Int) async {
        guard build > currentBuild else { return }
        pendingAnnouncedBuild = max(pendingAnnouncedBuild, build)
        guard build > handledAnnouncementBuild else { return }
        await checkAutomatically(force: true)
    }

    private func configureReleaseStream() {
        guard automatic && !defaults.bool(forKey: Self.pauseKey) else {
            releaseStream?.stop()
            reminderTask?.cancel(); reminderTask = nil
            releaseRetryTask?.cancel(); releaseRetryTask = nil
            return
        }
        if releaseStream == nil { releaseStream = releaseStreamFactory() }
        releaseStream?.start { [weak self] build in
            Task { @MainActor in await self?.receiveReleaseNotification(build: build) }
        }
    }

    private func resumePendingReleaseCheck() {
        guard reminderScheduling, ready, automatic, pendingAnnouncedBuild > max(currentBuild, handledAnnouncementBuild),
              !reminder.checking, !reminder.isDeferred else { return }
        Task { [weak self] in await self?.checkAutomatically(force: true) }
    }

    private func scheduleDeferredReminder() {
        guard reminderScheduling else { return }
        reminderTask?.cancel(); reminderTask = nil
        guard automatic, let until = reminder.deferredUntil, reminder.isDeferred else { return }
        let delay = max(0.01, until.timeIntervalSince(now()))
        reminderTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(delay, 172_800) * 1_000_000_000)) }
            catch { return }
            await self?.remindAfterDeferral()
        }
    }

    /// A single local deadline, so tomorrow's reminder does not depend on a new
    /// server release event being published at midnight.
    func remindAfterDeferral() async {
        if reminder.isDeferred { scheduleDeferredReminder(); return }
        await checkAutomatically(force: true)
    }

    private func schedulePendingReleaseRetry() {
        guard reminderScheduling, releaseRetryTask == nil, !reminder.isDeferred, automatic,
              pendingAnnouncedBuild > max(currentBuild, handledAnnouncementBuild) else { return }
        let delay = UpdateReleaseStream.reconnectDelay(failures: releaseRetryAttempt)
        releaseRetryAttempt = min(releaseRetryAttempt + 1, 6)
        releaseRetryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            self?.releaseRetryTask = nil
            await self?.checkAutomatically(force: true)
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    private static var systemVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
    static let reminderButtonTitles = ["立即更新", "明天提醒"]
    private static func presentReminder(_ release: PublishedRelease) async -> UpdateReminderChoice {
        let alert = NSAlert()
        alert.messageText = "Hero OOS \(release.version) 已发布"
        alert.informativeText = "新版已通过发布签名校验。立即更新会下载并验证安装包，完成当前内容的保存后重新打开 App。"
        for title in reminderButtonTitles { alert.addButton(withTitle: title) }
        NSApp.requestUserAttention(.informationalRequest)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { result in
                    continuation.resume(returning: result == .alertFirstButtonReturn ? .installNow : .tomorrow)
                }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn ? .installNow : .tomorrow
    }

    func loadVersions() async {
        guard ready && !busy else { return }
        busy = true; defer { busy = false; resumePendingReleaseCheck() }
        do {
            versions = try await fetchVerifiedVersions()
            message = versions.isEmpty ? "还没有公开发布的版本。" : "已验证最近 \(versions.count) 个版本。"
        } catch { message = "获取版本失败：\(error.localizedDescription)" }
    }

    private func fetchVerifiedVersions() async throws -> [PublishedRelease] {
        let data = try await download(UpdateTrust.root.appendingPathComponent("versions.json"), maximum: 256 * 1_024)
        let signatureData = try await download(UpdateTrust.root.appendingPathComponent("versions.json.sig"), maximum: 1_024)
        let signature = String(data: signatureData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try UpdateTrust.catalog(data, signature: signature, publicKey: publicKey)
    }

    func confirmPrepare(_ release: PublishedRelease) {
        guard !busy, versions.contains(release) else { return }
        let alert = NSAlert()
        alert.messageText = "准备 \(release.version) 安装包？"
        alert.informativeText = "这不是自动降级：将验证发布签名和文件哈希，再保存安装包供你手动安装。旧版可能不兼容新版数据（此版本数据格式 \(release.schema)）；请先备份。下载验证成功后会暂停自动更新，避免刚回退又升级。不会替换或删除当前 App 与数据。"
        alert.addButton(withTitle: "验证并下载"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await prepareArchive(release) }
    }

    private func prepareArchive(_ release: PublishedRelease) async {
        guard !busy else { return }
        busy = true; defer { busy = false; resumePendingReleaseCheck() }
        do {
            let data = try await download(release.url, maximum: release.byteLength)
            try UpdateTrust.verifyArchive(data, release: release, publicKey: publicKey)
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = downloads.appendingPathComponent("Hero OOS Releases", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent("Hero-OOS-build-\(release.build)-\(UUID().uuidString.prefix(8)).zip")
            try data.write(to: target, options: .withoutOverwriting)
            defaults.set(true, forKey: Self.pauseKey); setAutomatic(false)
            preparedArchive = target
            message = "安装包签名与哈希已验证；自动更新已暂停。请备份数据，退出 App 后手动安装。"
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch { message = "未准备安装包：\(error.localizedDescription)" }
    }

    private func download(_ url: URL, maximum: Int) async throws -> Data {
        guard UpdateTrust.permits(url), maximum > 0, maximum <= UpdateTrust.maxArchiveBytes else { throw UpdateTrust.failure("拒绝不可信下载地址。") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let session = session
        return try await Task.detached(priority: .utility) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url.map(UpdateTrust.permits) == true,
              response.expectedContentLength <= Int64(maximum) else { throw UpdateTrust.failure("更新服务器响应无效。") }
        var data = Data(); data.reserveCapacity(min(maximum, 1_024 * 1_024))
        for try await byte in bytes {
            if data.count >= maximum { throw UpdateTrust.failure("下载超过允许的大小。") }
            data.append(byte)
        }
        return data
        }.value
    }

    // Sparkle uses NSApplication termination. The existing AppDelegate can cancel or
    // defer it until task/canvas persistence succeeds; never call exit/kill here.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        message = "更新已准备好；将在正常退出并完成保存后安装。"
        return false
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { message = error.localizedDescription }
}

struct SoftwareUpdateSettingsView: View {
    @ObservedObject var updates: UpdateManager
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("软件更新").font(.headline)
            Toggle("自动发现新版并提醒", isOn: Binding(get: { updates.automatic }, set: updates.setAutomatic))
                .disabled(!updates.ready)
            Text("新版发布后由服务器主动通知，可选择立即更新或明天提醒；启动和恢复使用时也会核对一次。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("检查更新") { updates.check() }.disabled(!updates.canCheck)
                Button("最近 10 个版本") { Task { await updates.loadVersions() } }.disabled(!updates.ready || updates.busy)
                if updates.busy { ProgressView().controlSize(.small) }
            }
            if !updates.message.isEmpty { Text(updates.message).font(.caption).foregroundStyle(.secondary) }
            ForEach(updates.versions) { release in
                HStack {
                    Text("\(release.version)（\(release.build)） · \(release.architecture) · macOS \(release.minOS)+").font(.caption)
                    Spacer()
                    Button("准备手动安装包") { updates.confirmPrepare(release) }.disabled(updates.busy)
                }
            }
            Text("回退需手动确认并先备份；旧版可能无法读取新版数据。不会自动降级。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
