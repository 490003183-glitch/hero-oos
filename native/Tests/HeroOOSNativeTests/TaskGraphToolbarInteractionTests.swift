import XCTest
import SwiftUI
import AppKit
@testable import HeroOOSNative

@MainActor final class TaskGraphToolbarInteractionTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testGraphToolbarControlsAreNotBlankDetailDismissalTargets() throws {
        _ = NSApplication.shared
        let identity = "HeroOOS.graph-toolbar-test." + UUID().uuidString
        let api = OOSAPI(base: FileManager.default.temporaryDirectory.appendingPathComponent(identity))
        let store = OOSStore(api: api, recoverDrafts: false)
        let key = "HeroOOS.taskGraph.v1." + api.draftIdentity
        defer {
            store.stop()
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key + ".view")
        }
        let host = NSHostingView(rootView: TaskGraphWorkspace(selected: .constant(nil), search: "")
            .environmentObject(store).frame(width: 1800, height: 650))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1800, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 1800, height: 650)
        host.layoutSubtreeIfNeeded()
        // SwiftUI uses a non-NSControl popup host on newer macOS releases;
        // checking NSControl alone is exactly why blank-area dismissal failed.
        let controls = descendants(host).filter {
            $0 is NSPopUpButton || String(describing: type(of: $0)).contains("SwiftUIPopupButton")
        }
        XCTAssertGreaterThanOrEqual(controls.count, 4)
        for control in controls {
            for x in [control.bounds.minX + 4, control.bounds.midX, control.bounds.maxX - 4] {
                let point = host.convert(NSPoint(x: x, y: control.bounds.midY), from: control)
                let hit = host.hitTest(point)
                XCTAssertFalse(DetailClickPolicy.isBlank(at: point, in: host, hit: hit), "Filter controls must not close details: \(control.accessibilityLabel() ?? "")")
                XCTAssertFalse(hit is TaskGraphSurface)
                XCTAssertFalse(hit is DetailProtectedView) // Protection must not swallow the original click.
            }
        }
        // The marker is scoped to the toolbar, not the entire workspace.
        let blankFooter = NSPoint(x: 100, y: 645)
        XCTAssertTrue(DetailClickPolicy.isBlank(at: blankFooter, in: host, hit: host.hitTest(blankFooter)))
    }
}
