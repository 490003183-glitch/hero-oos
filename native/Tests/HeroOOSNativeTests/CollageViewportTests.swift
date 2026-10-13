import XCTest
import AppKit
@testable import HeroOOSNative

@MainActor final class CollageViewportTests: XCTestCase {
    private func document(active: String = "one") -> JSON {
        ["activeCanvasId": .string(active), "canvases": .array(["one", "two"].map { id in
            ["id": .string(id), "name": .string(id), "background": "#000000", "items": [
                ["id": .string(id + "-image"), "kind": "image", "x": 900, "y": 700, "width": 1600, "height": 1200, "z": 0]
            ]]
        })]
    }
    private func fixture(defaults: UserDefaults, identity: String = "account-a", active: String = "one") -> (CollageStore, CollageSurface) {
        var remote = document(active: active)
        let api = OOSAPI(base: URL(fileURLWithPath: "/test-only/" + identity), transport: { _, method, body, _ in
            if method == "PUT", let body { remote = body["collages"] }
            return ["collages": remote]
        })
        let store = CollageStore(api: api, recoverDrafts: false)
        store.document = remote
        let surface = CollageSurface(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), viewportDefaults: defaults)
        surface.model = store; store.surface = surface
        return (store, surface)
    }
    private func preferences() throws -> (String, UserDefaults) {
        let name = "hero-collage-viewport-test-\(UUID().uuidString)"
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    func testReopenRestoresZoomOffsetAndExistingSelectionWithoutFittingAgain() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let (store, surface) = fixture(defaults: defaults)
        surface.zoomTo(0.28); surface.offset = CGPoint(x: -812, y: 145)
        store.selection = ["one-image", "deleted-item"]
        surface.persistViewport()
        let (reopened, restored) = fixture(defaults: defaults)
        XCTAssertEqual(restored.displayScale, 0.28)
        XCTAssertEqual(restored.offset, CGPoint(x: -812, y: 145))
        XCTAssertEqual(reopened.selection, ["one-image"])
        XCTAssertFalse(restored.needsFit)
        restored.layout()
        XCTAssertEqual(restored.offset, CGPoint(x: -812, y: 145))
    }

    func testCanvasSwitchKeepsSeparateViewsAndSelections() async throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let (store, surface) = fixture(defaults: defaults)
        surface.zoomTo(0.4); surface.offset = CGPoint(x: 123, y: -456); store.selection = ["one-image"]
        store.switchCanvas("two")
        XCTAssertNotEqual(surface.offset, CGPoint(x: 123, y: -456))
        XCTAssertTrue(store.selection.isEmpty)
        surface.zoomTo(1.25); surface.offset = CGPoint(x: -900, y: -330); store.selection = ["two-image"]
        store.switchCanvas("one")
        XCTAssertEqual(surface.displayScale, 0.4); XCTAssertEqual(surface.offset, CGPoint(x: 123, y: -456))
        XCTAssertEqual(store.selection, ["one-image"])
        store.switchCanvas("two")
        XCTAssertEqual(surface.displayScale, 1.25); XCTAssertEqual(surface.offset, CGPoint(x: -900, y: -330))
        XCTAssertEqual(store.selection, ["two-image"])
        _ = await store.save()
    }

    func testRefreshDoesNotResetExistingCamera() async throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let (store, surface) = fixture(defaults: defaults)
        surface.zoomTo(2.2); surface.offset = CGPoint(x: -5000, y: 112)
        store.selection = ["one-image"]
        await store.load()
        XCTAssertEqual(surface.displayScale, 2.2); XCTAssertEqual(surface.offset, CGPoint(x: -5000, y: 112))
        XCTAssertEqual(store.selection, ["one-image"])
    }

    func testSameCanvasIDNeverLeaksViewportAcrossAccounts() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let (store, surface) = fixture(defaults: defaults, identity: "account-one")
        surface.zoomTo(7); surface.offset = CGPoint(x: 112233, y: -445566); surface.persistViewport()
        let (other, otherSurface) = fixture(defaults: defaults, identity: "account-two")
        XCTAssertNotEqual(otherSurface.displayScale, 7); XCTAssertNotEqual(otherSurface.offset, surface.offset)
        XCTAssertNotEqual(CollageViewportState.key(identity: store.api.draftIdentity, canvasID: "one"),
                          CollageViewportState.key(identity: other.api.draftIdentity, canvasID: "one"))
        XCTAssertNotEqual(CollageViewportState.key(identity: "a|b", canvasID: "c"), CollageViewportState.key(identity: "a", canvasID: "b|c"))
    }

    func testMalformedOrOutOfRangePreferencesFallBackToContentFit() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let identity = OOSAPI(base: URL(fileURLWithPath: "/test-only/account-a")).draftIdentity
        let key = CollageViewportState.key(identity: identity, canvasID: "one")
        let bad = CollageViewportState(scale: 0, offsetX: 1_000_000_001, offsetY: 0, selectedIDs: [])
        XCTAssertFalse(bad.isValid)
        defaults.set(try JSONEncoder().encode(bad), forKey: key)
        XCTAssertNil(CollageViewportState.load(identity: identity, canvasID: "one", defaults: defaults))
        let (store, surface) = fixture(defaults: defaults)
        XCTAssertFalse(surface.needsFit); XCTAssertGreaterThan(surface.displayScale, 0)
        XCTAssertLessThanOrEqual(surface.displayScale, 1)
        XCTAssertEqual(surface.visibleCenter.x, 1700, accuracy: 0.001)
        XCTAssertEqual(surface.visibleCenter.y, 1300, accuracy: 0.001)
        XCTAssertTrue(store.selection.isEmpty)
        defaults.set(Data("not json".utf8), forKey: key)
        XCTAssertNil(CollageViewportState.load(identity: identity, canvasID: "one", defaults: defaults))
        XCTAssertFalse(CollageViewportState(scale: .nan, offsetX: 0, offsetY: 0, selectedIDs: []).isValid)
        XCTAssertFalse(CollageViewportState(scale: 1, offsetX: .infinity, offsetY: 0, selectedIDs: []).isValid)
    }

    func testViewportWritesAreDebouncedAndExitNotificationFlushesImmediately() async throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let (store, surface) = fixture(defaults: defaults)
        let key = CollageViewportState.key(identity: store.api.draftIdentity, canvasID: "one")
        for i in 0..<50 { surface.offset = CGPoint(x: -i, y: i) }
        XCTAssertNil(defaults.data(forKey: key), "Wheel events must not write preferences synchronously")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(CollageViewportState.load(identity: store.api.draftIdentity, canvasID: "one", defaults: defaults)?.offsetX, -49)
        surface.zoomTo(0.7); surface.offset = CGPoint(x: -188, y: 144)
        NotificationCenter.default.post(name: .commitInlineTaskTitle, object: nil)
        let saved = try XCTUnwrap(CollageViewportState.load(identity: store.api.draftIdentity, canvasID: "one", defaults: defaults))
        XCTAssertEqual(saved.scale, 0.7); XCTAssertEqual(saved.offsetX, -188); XCTAssertEqual(saved.offsetY, 144)
    }

    func testRemovingSurfaceFlushesViewportEvenWithoutDocumentEdits() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let (store, surface) = fixture(defaults: defaults)
        let host = NSView(frame: surface.frame); host.addSubview(surface)
        surface.zoomTo(0.19); surface.offset = CGPoint(x: 808, y: -909)
        surface.removeFromSuperview()
        let saved = try XCTUnwrap(CollageViewportState.load(identity: store.api.draftIdentity, canvasID: "one", defaults: defaults))
        XCTAssertEqual(saved.scale, 0.19); XCTAssertEqual(saved.offsetX, 808); XCTAssertEqual(saved.offsetY, -909)
        XCTAssertFalse(store.dirty, "View persistence must not mutate collage documents")
    }
}
