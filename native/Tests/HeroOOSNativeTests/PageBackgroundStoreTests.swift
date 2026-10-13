import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HeroOOSNative

@MainActor final class PageBackgroundStoreTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hero-oos-background-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ownedDirectory(_ root: URL, identity: String = "test-user") -> URL {
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.resolvingSymlinksInPath().appendingPathComponent(hash)
    }

    private func source(_ root: URL, type: UTType = .png, width: Int = 8, height: Int = 6, orientation: Int = 1, name: String = "original") throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        // Intentionally unrelated suffix: validation is based on the actual image type.
        let url = root.appendingPathComponent(name + ".source")
        try (data as Data).write(to: url)
        return url
    }

    func testGlobalAndPerPagePersistenceWithExplicitNoneAndReset() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PageBackgroundStore(identity: "test-user", root: root)
        var first = try await store.importImage(from: source(root))
        first.opacity = 0.48; first.brightness = 0.72; first.fit = .fit
        let second = try await store.importImage(from: source(root, name: "second"))
        try store.setGlobal(first)
        try store.setOverride(.image(second), for: "today")
        try store.setOverride(PageBackgroundRule.none, for: "plan")
        XCTAssertEqual(store.effective(for: "private"), first)
        XCTAssertEqual(store.effective(for: "today"), second)
        XCTAssertNil(store.effective(for: "plan"))
        let reloaded = PageBackgroundStore(identity: "test-user", root: root)
        XCTAssertEqual(reloaded.global, first)
        XCTAssertEqual(reloaded.overrides["plan"], PageBackgroundRule.none)
        XCTAssertNil(reloaded.effective(for: "plan"), "A persisted disabled page must not inherit the global image.")
        try reloaded.setOverride(nil, for: "today")
        XCTAssertEqual(reloaded.effective(for: "today"), first)
        try reloaded.setGlobal(nil)
        XCTAssertNil(reloaded.effective(for: "today"))
        XCTAssertEqual(reloaded.overrides["plan"], PageBackgroundRule.none)
    }

    func testApplyToAllClearsOverridesAtomicallyAndCanResetEverything() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PageBackgroundStore(identity: "test-user", root: root)
        let image = try await store.importImage(from: source(root))
        try store.setOverride(PageBackgroundRule.none, for: "today")
        try store.setOverride(.image(image), for: "private")
        try store.applyToAll(image)
        XCTAssertTrue(store.overrides.isEmpty)
        XCTAssertEqual(store.effective(for: "today"), image)
        XCTAssertTrue(PageBackgroundStore(identity: "test-user", root: root).overrides.isEmpty)
        try store.applyToAll(nil)
        XCTAssertNil(store.global)
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testLocalIdentityIsolationAndAppearanceDocumentHasNoTaskFields() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let first = PageBackgroundStore(identity: "test-user", root: root)
        let image = try await first.importImage(from: source(root))
        try first.applyToAll(image)
        let other = PageBackgroundStore(identity: "another-user", root: root)
        XCTAssertNil(other.global)
        XCTAssertNil(other.effective(for: "today"))
        XCTAssertNil(other.image(for: image))
        let data = try Data(contentsOf: ownedDirectory(root).appendingPathComponent("appearance.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(document.keys), Set(["version", "global", "overrides"]))
        let serialized = String(decoding: data, as: UTF8.self)
        for secret in ["test-user", "tasks", "cloud", "password", "token", "original.source"] { XCTAssertFalse(serialized.contains(secret)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/state.json").path))
    }

    func testPNGOriginalBytesAndTransparencyArePreservedAndCopyIsIndependent() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try source(root), bytes = try Data(contentsOf: original)
        let store = PageBackgroundStore(identity: "test-user", root: root)
        let configuration = try await store.importImage(from: original)
        XCTAssertTrue(configuration.assetName.hasSuffix(".png"))
        let copied = ownedDirectory(root).appendingPathComponent("assets/" + configuration.assetName)
        XCTAssertEqual(try Data(contentsOf: copied), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let image = try XCTUnwrap(store.image(for: configuration)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue([CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo))
        try store.setGlobal(configuration)
        try FileManager.default.removeItem(at: original)
        XCTAssertNotNil(store.effective(for: "today"), "Deleting or moving the user's original must not break the managed copy.")
    }

    func testJPEGOrientationAndLargePreviewDownsampling() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PageBackgroundStore(identity: "test-user", root: root)
        let jpeg = try await store.importImage(from: source(root, type: .jpeg, width: 8, height: 6, orientation: 6))
        XCTAssertTrue(jpeg.assetName.hasSuffix(".jpg"))
        let rotated = try XCTUnwrap(store.image(for: jpeg)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(rotated.width, 6)
        XCTAssertEqual(rotated.height, 8)
        let large = try await store.importImage(from: source(root, width: 5000, height: 2, name: "large"))
        let preview = try XCTUnwrap(store.image(for: large)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(preview.width, 4096)
        let copied = ownedDirectory(root).appendingPathComponent("assets/" + large.assetName)
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithURL(copied as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 5000)
    }

    func testRejectsNonImageEvenWithJPGExtensionAndValidOtherImageType() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PageBackgroundStore(identity: "test-user", root: root)
        let fake = root.appendingPathComponent("fake.jpg")
        try Data("not an image".utf8).write(to: fake)
        do { _ = try await store.importImage(from: fake); XCTFail("Must reject a fake JPEG") }
        catch { XCTAssertTrue(error is PageBackgroundError) }
        let tiff = try source(root, type: .tiff, name: "unsupported")
        do { _ = try await store.importImage(from: tiff); XCTFail("Only PNG and JPEG are allowed") }
        catch { XCTAssertTrue(error is PageBackgroundError) }
        XCTAssertNil(store.global)
        XCTAssertTrue(store.overrides.isEmpty)
    }

    func testRejectsByteLimitBeforeReadingHugeSource() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(PageBackgroundStore.maximumBytes + 1))
        try handle.close()
        let store = PageBackgroundStore(identity: "test-user", root: root)
        do { _ = try await store.importImage(from: file); XCTFail("Must reject oversized source") }
        catch { if case PageBackgroundError.imageTooLarge = error {} else { XCTFail("Unexpected error: \(error)") } }
    }

    func testFiniteRangesAreClampedAndInvalidPathsOrNumbersDoNotChangeState() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PageBackgroundStore(identity: "test-user", root: root)
        var configuration = try await store.importImage(from: source(root))
        configuration.opacity = -4; configuration.brightness = 9
        try store.setGlobal(configuration)
        XCTAssertEqual(store.global?.opacity, 0)
        XCTAssertEqual(store.global?.brightness, 2)
        let saved = store.global
        for badName in ["../secret.png", "/tmp/secret.jpg", "photo.png", "..", ""] {
            configuration.assetName = badName
            XCTAssertThrowsError(try store.setGlobal(configuration))
            XCTAssertEqual(store.global, saved)
        }
        configuration = try XCTUnwrap(saved)
        configuration.opacity = .nan
        XCTAssertThrowsError(try store.setGlobal(configuration))
        configuration.opacity = 0.3; configuration.brightness = .infinity
        XCTAssertThrowsError(try store.applyToAll(configuration))
        XCTAssertThrowsError(try store.setOverride(PageBackgroundRule.none, for: ""))
        XCTAssertEqual(store.global, saved)
        XCTAssertEqual(PageBackgroundStore(identity: "test-user", root: root).global, saved)
    }

    func testFailedAtomicSaveLeavesPublishedAndPersistedChoicesUnchanged() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PageBackgroundStore(identity: "test-user", root: root)
        let configuration = try await store.importImage(from: source(root))
        try store.setGlobal(configuration)
        try store.setOverride(PageBackgroundRule.none, for: "today")
        let settings = ownedDirectory(root).appendingPathComponent("appearance.json")
        let saved = try Data(contentsOf: settings), backup = ownedDirectory(root).appendingPathComponent("previous.json")
        try FileManager.default.moveItem(at: settings, to: backup)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.applyToAll(nil))
        XCTAssertEqual(store.global, configuration)
        XCTAssertEqual(store.overrides["today"], PageBackgroundRule.none)
        XCTAssertEqual(try Data(contentsOf: backup), saved)
    }

    func testCorruptConfigurationMissingAssetAndSymlinkAssetsFailClosed() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PageBackgroundStore(identity: "test-user", root: root)
        let original = try source(root)
        let configuration = try await store.importImage(from: original)
        try store.setGlobal(configuration)
        let owned = ownedDirectory(root), file = owned.appendingPathComponent("assets/" + configuration.assetName)
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(store.effective(for: "today"))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        XCTAssertNil(store.effective(for: "today"))
        XCTAssertNil(store.image(for: configuration))
        try Data("broken json".utf8).write(to: owned.appendingPathComponent("appearance.json"))
        let reloaded = PageBackgroundStore(identity: "test-user", root: root)
        XCTAssertNil(reloaded.global)
        XCTAssertTrue(reloaded.overrides.isEmpty)
        let linkedSource = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: original)
        do { _ = try await reloaded.importImage(from: linkedSource); XCTFail("Symbolic-link sources must be rejected") }
        catch { XCTAssertTrue(error is PageBackgroundError) }
    }

    func testSymbolicLinkConfigurationCannotOverwriteOutsideFile() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PageBackgroundStore(identity: "test-user", root: root)
        try store.setOverride(PageBackgroundRule.none, for: "today")
        let settings = ownedDirectory(root).appendingPathComponent("appearance.json"), outside = root.appendingPathComponent("untouched.txt")
        let original = Data("user data".utf8)
        try original.write(to: outside)
        try FileManager.default.removeItem(at: settings)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: outside)
        XCTAssertThrowsError(try store.applyToAll(nil))
        XCTAssertEqual(try Data(contentsOf: outside), original)
        XCTAssertEqual(store.overrides["today"], PageBackgroundRule.none)
    }

    func testReadingOutOfRangeStoredSettingsSanitizesWithoutChangingFile() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PageBackgroundStore(identity: "test-user", root: root)
        let configuration = try await store.importImage(from: source(root))
        let settings = ownedDirectory(root).appendingPathComponent("appearance.json")
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "global": ["assetName": configuration.assetName,
            "opacity": 20, "brightness": -4, "fit": "fit"], "overrides": [:]])
        try bytes.write(to: settings)
        let reloaded = PageBackgroundStore(identity: "test-user", root: root)
        XCTAssertEqual(reloaded.global?.opacity, 1)
        XCTAssertEqual(reloaded.global?.brightness, 0)
        XCTAssertEqual(reloaded.global?.fit, .fit)
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
    }
}
