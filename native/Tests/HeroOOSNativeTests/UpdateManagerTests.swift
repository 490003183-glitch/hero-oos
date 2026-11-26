import CryptoKit
import Foundation
import XCTest
@testable import HeroOOSNative

final class UpdateManagerTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    private let archive = Data("test archive fixture".utf8)
    private func release(build: Int = 22) throws -> PublishedRelease {
        PublishedRelease(version: "1.7.0", build: build, architecture: "arm64", minOS: "15.0", schema: 1,
                         url: UpdateTrust.root.appendingPathComponent("Hero-OOS-build-\(build)-arm64.zip"),
                         sha256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(),
                         edSignature: try key.signature(for: archive).base64EncodedString(),
                         byteLength: archive.count, publishedAt: "2026-10-13T00:00:00Z")
    }
    private func verifiedCatalog(_ releases: [PublishedRelease], format: Int = 1) throws -> [PublishedRelease] {
        let data = try JSONEncoder().encode(ReleaseCatalog(formatVersion: format, versions: releases))
        return try UpdateTrust.catalog(data, signature: key.signature(for: data).base64EncodedString(), publicKey: publicKey)
    }
    func testOnlyOwnHTTPSUpdateDirectoryIsAllowed() {
        XCTAssertTrue(UpdateTrust.permits(URL(string: "https://cloud.example.invalid/updates/v3/versions.json")!))
        for raw in ["http://cloud.example.invalid/updates/a.zip", "https://example.com/updates/a.zip", "https://cloud.example.invalid/else/a.zip",
                    "https://cloud.example.invalid:8443/updates/a.zip", "https://root@cloud.example.invalid/updates/a.zip",
                    "https://cloud.example.invalid/updates/../private", "https://cloud.example.invalid/updates/a.zip?token=x",
                    "https://cloud.example.invalid/updates/versions.json", "https://cloud.example.invalid/updates/v30/a.zip",
                    "https://cloud.example.invalid/updates/v3/../a.zip", "https://cloud.example.invalid/updates/v3/a.zip?token=x"] {
            XCTAssertFalse(UpdateTrust.permits(URL(string: raw)!), raw)
        }
    }
    func testSignedCatalogSortedNewestFirst() throws {
        XCTAssertEqual(try verifiedCatalog([release(build: 22), release(build: 23)]).map(\.build), [23, 22])
    }
    func testForgedCatalogAndWrongKeyRejected() throws {
        let data = try JSONEncoder().encode(ReleaseCatalog(formatVersion: 1, versions: [release()]))
        let signature = try key.signature(for: data).base64EncodedString()
        XCTAssertThrowsError(try UpdateTrust.catalog(data + Data(" ".utf8), signature: signature, publicKey: publicKey))
        XCTAssertThrowsError(try UpdateTrust.catalog(data, signature: signature, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()))
    }
    func testCatalogBoundsAndDuplicatesRejected() throws {
        XCTAssertThrowsError(try verifiedCatalog((1...11).map { try release(build: $0) }))
        XCTAssertThrowsError(try verifiedCatalog([release(), release()]))
        XCTAssertThrowsError(try verifiedCatalog([], format: 2))
    }
    func testUnsafeMetadataRejectedEvenIfSigned() throws {
        var item = try release(); item.url = URL(string: "https://example.com/malware.zip")!
        XCTAssertThrowsError(try verifiedCatalog([item]))
        item = try release(); item.byteLength = UpdateTrust.maxArchiveBytes + 1
        XCTAssertThrowsError(try verifiedCatalog([item]))
        item = try release(); item.sha256 = "bad"
        XCTAssertThrowsError(try verifiedCatalog([item]))
        item = try release(); item.edSignature = "not a signature"
        XCTAssertThrowsError(try verifiedCatalog([item]))
    }
    func testArchiveRequiresMatchingSizeHashAndSignature() throws {
        let valid = try release()
        XCTAssertNoThrow(try UpdateTrust.verifyArchive(archive, release: valid, publicKey: publicKey))
        XCTAssertThrowsError(try UpdateTrust.verifyArchive(archive + Data([0]), release: valid, publicKey: publicKey))
        var wrongHash = valid; wrongHash.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try UpdateTrust.verifyArchive(archive, release: wrongHash, publicKey: publicKey))
        var wrongSignature = valid; wrongSignature.edSignature = try key.signature(for: Data("other".utf8)).base64EncodedString()
        XCTAssertThrowsError(try UpdateTrust.verifyArchive(archive, release: wrongSignature, publicKey: publicKey))
    }
    @MainActor func testMissingKeyFailsClosedWithoutStartingUpdater() {
        let defaults = UserDefaults(suiteName: "HeroOOS.UpdateTests.\(UUID().uuidString)")!
        let manager = UpdateManager(bundle: Bundle(for: Self.self), defaults: defaults)
        manager.start()
        XCTAssertFalse(manager.ready); XCTAssertFalse(manager.canCheck)
        XCTAssertTrue(manager.message.contains("尚未配置"))
        manager.check(); manager.setAutomatic(false)
        XCTAssertNil(defaults.object(forKey: "SUEnableAutomaticChecks"))
    }
}
