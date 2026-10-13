import AppKit
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum PageBackgroundFit: String, Codable, CaseIterable {
    case fill, fit
}

struct PageBackgroundConfiguration: Codable, Equatable {
    var assetName: String
    var opacity: Double = 0.30
    /// Normalized brightness adjustment: zero is black, one is unchanged, and two is white.
    var brightness: Double = 1.0
    var fit: PageBackgroundFit = .fill
}

enum PageBackgroundRule: Codable, Equatable {
    case image(PageBackgroundConfiguration)
    /// A deliberate per-page opt-out, distinct from inheriting the global background.
    case none
}

enum PageBackgroundError: LocalizedError {
    case invalidImage, imageTooLarge, invalidConfiguration, unsafeLocation

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "请选择可以正常打开的 JPG 或 PNG 图片。"
        case .imageTooLarge: return "背景图片不能超过 80 MB 或 1 亿像素。"
        case .invalidConfiguration: return "背景配置无效，请重新选择图片。"
        case .unsafeLocation: return "背景文件位置不可用，请检查本机文件权限。"
        }
    }
}

/// Device-only appearance data. This store deliberately has no OOSStore, task document,
/// CloudSync, or account-workspace dependency, so its files cannot enter task synchronization.
@MainActor final class PageBackgroundStore: ObservableObject {
    @Published private(set) var global: PageBackgroundConfiguration?
    @Published private(set) var overrides: [String: PageBackgroundRule] = [:]

    private struct Document: Codable {
        var version = 1
        var global: PageBackgroundConfiguration?
        var overrides: [String: PageBackgroundRule]
    }

    private let directory: URL
    private let assets: URL
    private let configurationURL: URL
    private let cache = NSCache<NSString, NSImage>()
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    nonisolated static let maximumBytes = 80 * 1024 * 1024
    nonisolated static let maximumPixels = 100_000_000
    nonisolated static let previewSize = 4096

    /// `root` is the local base above the identity-hashed directory, not a cloud data root.
    init(identity: String, root: URL? = nil) {
        let base = (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hero OOS/Page Backgrounds", isDirectory: true))
            .standardizedFileURL.resolvingSymlinksInPath()
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = base.appendingPathComponent(digest, isDirectory: true)
        assets = directory.appendingPathComponent("assets", isDirectory: true)
        configurationURL = directory.appendingPathComponent("appearance.json")
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 12
        guard (try? Self.checkDirectory(directory, create: false)) != nil,
              (try? Self.checkFile(configurationURL)) != nil,
              let data = try? Data(contentsOf: configurationURL), data.count <= 1_048_576,
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else { return }
        global = document.global.flatMap { try? Self.validated($0) }
        overrides = document.overrides.reduce(into: [:]) { result, pair in
            guard Self.validPageKey(pair.key) else { return }
            switch pair.value {
            case .none: result[pair.key] = PageBackgroundRule.none
            case .image(let configuration):
                if let validated = try? Self.validated(configuration) { result[pair.key] = .image(validated) }
            }
        }
    }

    func effective(for pageKey: String) -> PageBackgroundConfiguration? {
        let candidate: PageBackgroundConfiguration?
        switch overrides[pageKey] {
        case nil: candidate = global
        case .some(.none): return nil
        case .some(.image(let configuration)): candidate = configuration
        }
        // A missing local file must not leave an opaque placeholder or accidentally read
        // a target outside this store. Existing settings are retained for recovery.
        guard let candidate, let _ = try? assetURL(for: candidate) else { return nil }
        return candidate
    }

    func setGlobal(_ configuration: PageBackgroundConfiguration?) throws {
        let next = try configuration.map(Self.validated)
        try persist(global: next, overrides: overrides)
        global = next
    }

    func setOverride(_ rule: PageBackgroundRule?, for pageKey: String) throws {
        guard Self.validPageKey(pageKey) else { throw PageBackgroundError.invalidConfiguration }
        let nextRule: PageBackgroundRule?
        switch rule {
        case .some(.image(let configuration)): nextRule = .image(try Self.validated(configuration))
        case .some(.none): nextRule = .none as PageBackgroundRule
        case nil: nextRule = nil
        }
        var next = overrides
        next[pageKey] = nextRule
        try persist(global: global, overrides: next)
        overrides = next
    }

    /// Replace all per-page choices in one atomic document write.
    func applyToAll(_ configuration: PageBackgroundConfiguration?) throws {
        let next = try configuration.map(Self.validated)
        try persist(global: next, overrides: [:])
        global = next
        overrides = [:]
    }

    func importImage(from url: URL) async throws -> PageBackgroundConfiguration {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let destination = assets
        let imported = try await Task.detached(priority: .userInitiated) {
            try Self.checkSourceFile(url)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= Self.maximumBytes else { throw PageBackgroundError.imageTooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let decoded = try Self.decode(data)
            try Self.checkDirectory(destination.deletingLastPathComponent(), create: true)
            try Self.checkDirectory(destination, create: true)
            let name = UUID().uuidString.lowercased() + "." + decoded.fileExtension
            let copiedURL = destination.appendingPathComponent(name)
            // Original bytes, including PNG alpha and metadata, are copied unchanged.
            // The downsampled image below is a memory-only display cache.
            guard !FileManager.default.fileExists(atPath: copiedURL.path), !Self.isSymbolicLink(copiedURL) else { throw PageBackgroundError.unsafeLocation }
            try data.write(to: copiedURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copiedURL.path)
            return (name, decoded.image)
        }.value
        let image = NSImage(cgImage: imported.1, size: .zero)
        cache.setObject(image, forKey: imported.0 as NSString, cost: imported.1.width * imported.1.height * 4)
        failed.remove(imported.0)
        return PageBackgroundConfiguration(assetName: imported.0)
    }

    /// Never decodes a large source image on the UI thread. Imported images are already
    /// cached; after relaunch a background decode publishes a redraw when ready.
    func image(for configuration: PageBackgroundConfiguration) -> NSImage? {
        guard let url = try? assetURL(for: configuration) else { return nil }
        let name = configuration.assetName
        if let image = cache.object(forKey: name as NSString) { return image }
        guard !loading.contains(name), !failed.contains(name) else { return nil }
        loading.insert(name)
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> CGImage? in
                guard (try? Self.checkSourceFile(url)) != nil,
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize, size <= Self.maximumBytes,
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return try? Self.decode(data).image
            }.value
            guard let self else { return }
            self.loading.remove(name)
            if let result {
                self.cache.setObject(NSImage(cgImage: result, size: .zero), forKey: name as NSString, cost: result.width * result.height * 4)
            } else { self.failed.insert(name) }
            self.objectWillChange.send()
        }
        return nil
    }

    private func assetURL(for configuration: PageBackgroundConfiguration) throws -> URL {
        _ = try Self.validated(configuration)
        try Self.checkDirectory(directory, create: false)
        try Self.checkDirectory(assets, create: false)
        let url = assets.appendingPathComponent(configuration.assetName)
        try Self.checkFile(url)
        return url
    }

    private func persist(global: PageBackgroundConfiguration?, overrides: [String: PageBackgroundRule]) throws {
        try Self.checkDirectory(directory, create: true)
        if FileManager.default.fileExists(atPath: configurationURL.path) || Self.isSymbolicLink(configurationURL) {
            try Self.checkFile(configurationURL)
        }
        let data = try JSONEncoder().encode(Document(global: global, overrides: overrides))
        try data.write(to: configurationURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }

    nonisolated private static func validPageKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 100 && !key.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    nonisolated private static func validated(_ configuration: PageBackgroundConfiguration) throws -> PageBackgroundConfiguration {
        let parts = configuration.assetName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              ["jpg", "jpeg", "png"].contains(String(parts[1])),
              configuration.opacity.isFinite, configuration.brightness.isFinite else { throw PageBackgroundError.invalidConfiguration }
        var result = configuration
        result.opacity = min(1, max(0, result.opacity))
        result.brightness = min(2, max(0, result.brightness))
        return result
    }

    nonisolated private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true ||
            (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    nonisolated private static func checkDirectory(_ url: URL, create: Bool) throws {
        // URL equality also compares the directory hint / trailing slash. Filesystem
        // confinement is about canonical paths, so compare paths rather than URL values.
        guard !isSymbolicLink(url), url.standardizedFileURL.path == url.standardizedFileURL.resolvingSymlinksInPath().path else { throw PageBackgroundError.unsafeLocation }
        if !FileManager.default.fileExists(atPath: url.path), create {
            // Check every existing ancestor first; never create descendants through a
            // malicious symbolic link inside an app-owned background directory.
            var parent = url.deletingLastPathComponent()
            while parent.path != "/" {
                guard !isSymbolicLink(parent) else { throw PageBackgroundError.unsafeLocation }
                if FileManager.default.fileExists(atPath: parent.path) { break }
                parent.deleteLastPathComponent()
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let properties = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw PageBackgroundError.unsafeLocation }
    }

    nonisolated private static func checkFile(_ url: URL) throws {
        guard !isSymbolicLink(url) else { throw PageBackgroundError.unsafeLocation }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PageBackgroundError.unsafeLocation }
    }

    nonisolated private static func checkSourceFile(_ url: URL) throws {
        guard url.isFileURL else { throw PageBackgroundError.unsafeLocation }
        try checkFile(url)
    }

    nonisolated private static func decode(_ data: Data) throws -> (image: CGImage, fileExtension: String) {
        guard data.count <= maximumBytes else { throw PageBackgroundError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              type == UTType.jpeg.identifier || type == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw PageBackgroundError.invalidImage }
        let w = width.int64Value, h = height.int64Value
        guard w > 0, h > 0 else { throw PageBackgroundError.invalidImage }
        guard w <= Int64(maximumPixels), h <= Int64(maximumPixels), w <= Int64(maximumPixels) / h else { throw PageBackgroundError.imageTooLarge }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: previewSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw PageBackgroundError.invalidImage }
        return (image, type == UTType.png.identifier ? "png" : "jpg")
    }
}
