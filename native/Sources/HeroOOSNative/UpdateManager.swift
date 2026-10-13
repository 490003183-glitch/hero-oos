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
            return URL(string: "https://cloud.example.invalid/updates/")!
        }
        return url.deletingLastPathComponent().appendingPathComponent("")
    }
    static let maxArchiveBytes = 256 * 1_024 * 1_024
    static func permits(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == root.host && (url.port == nil || url.port == 443) &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
        url.path.hasPrefix(root.path) && !url.pathComponents.contains("..")
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

@MainActor final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var automatic = false
    @Published private(set) var ready = false
    @Published private(set) var canCheck = false
    @Published private(set) var busy = false
    @Published private(set) var versions: [PublishedRelease] = []
    @Published private(set) var message = ""
    @Published private(set) var preparedArchive: URL?
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private let bundle: Bundle
    private let defaults: UserDefaults
    private let publicKey: String
    private let downloadDelegate = UpdateDownloadDelegate()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: downloadDelegate, delegateQueue: nil)
    static let pauseKey = "HeroOOS.updates.pausedForManualRollback"

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.bundle = bundle; self.defaults = defaults
        publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        super.init()
        automatic = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? false
    }

    /// Call once after stores and the app delegate's termination/save barrier are attached.
    func start() {
        guard controller == nil else { return }
        guard Data(base64Encoded: publicKey)?.count == 32,
              bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String == UpdateTrust.root.appendingPathComponent("appcast.xml").absoluteString else {
            message = "可信更新尚未配置：需要发布公钥与 HTTPS 更新源。"; return
        }
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller = updater
        observations = [
            updater.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] value, _ in
                Task { @MainActor in self?.canCheck = value.canCheckForUpdates }
            },
            updater.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] value, _ in
                Task { @MainActor in self?.automatic = value.automaticallyChecksForUpdates && value.automaticallyDownloadsUpdates }
            },
            updater.updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] value, _ in
                Task { @MainActor in self?.automatic = value.automaticallyChecksForUpdates && value.automaticallyDownloadsUpdates }
            }
        ]
        if defaults.bool(forKey: Self.pauseKey) {
            updater.updater.automaticallyDownloadsUpdates = false
            updater.updater.automaticallyChecksForUpdates = false
            message = "手动版本回退准备中：自动升级已暂停，可在这里重新开启。"
        }
        ready = true
        updater.startUpdater()
    }

    func setAutomatic(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        // Persist only in response to user choice; do not overwrite preferences every launch.
        updater.automaticallyDownloadsUpdates = enabled
        updater.automaticallyChecksForUpdates = enabled
        automatic = enabled
        if enabled { defaults.removeObject(forKey: Self.pauseKey) }
    }

    func check() { guard ready && canCheck else { return }; controller?.checkForUpdates(nil) }

    func loadVersions() async {
        guard ready && !busy else { return }
        busy = true; defer { busy = false }
        do {
            let data = try await download(UpdateTrust.root.appendingPathComponent("versions.json"), maximum: 256 * 1_024)
            let signatureData = try await download(UpdateTrust.root.appendingPathComponent("versions.json.sig"), maximum: 1_024)
            let signature = String(data: signatureData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            versions = try UpdateTrust.catalog(data, signature: signature, publicKey: publicKey)
            message = versions.isEmpty ? "还没有公开发布的版本。" : "已验证最近 \(versions.count) 个版本。"
        } catch { message = "获取版本失败：\(error.localizedDescription)" }
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
        busy = true; defer { busy = false }
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
            Toggle("自动检查、下载并在安全退出后安装更新", isOn: Binding(get: { updates.automatic }, set: updates.setAutomatic))
                .disabled(!updates.ready)
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
