import XCTest
import SwiftUI
import AppKit
@testable import HeroOOSNative

@MainActor final class LedgerSummaryPresentationTests: XCTestCase {
    private func task(_ id: String, amount: JSON = .null, fields: [String: JSON] = [:]) -> Record {
        Record(["id": .string(id), "title": .string(id), "taskSpace": "work", "status": "ready",
                "ledgerEnabled": true, "amountTaxInclusive": amount].merging(fields) { _, new in new })
    }

    private func temporaryStore() -> OOSStore {
        OOSStore(api: OOSAPI(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("HeroOOS.ledger-summary-test." + UUID().uuidString)), recoverDrafts: false)
    }

    func testFocusUsesCurrentSnapshotIncludingUnsavedAmountAndStatusChanges() throws {
        let store = temporaryStore()
        defer { store.stop() }
        store.state = ["tasks": .array([
            task("missing", fields: ["invoiceStatus": "未开票", "paymentStatus": "未收款", "client": "客户甲"]).json,
            task("closing", amount: 20).json,
            task("usd", amount: 5, fields: ["currency": "USD"]).json
        ])]
        let before = StudioLedgerSummary(tasks: store.tasks)
        XCTAssertEqual(LedgerSummaryFocus.missing.taskIDs(in: before), ["missing"])
        XCTAssertEqual(LedgerSummaryFocus.pending.taskIDs(in: before), ["missing", "closing", "usd"])

        // The UI derives its snapshot from resolvedTasks, not stale persisted records.
        store.pending = ["missing": ["amountTaxInclusive": 12.25, "invoiceStatus": "已开票",
                                     "paymentStatus": "已收款", "client": "客户乙"],
                         "closing": ["status": "completed"]]
        let after = StudioLedgerSummary(tasks: store.tasks)
        XCTAssertTrue(LedgerSummaryFocus.missing.taskIDs(in: after).isEmpty)
        XCTAssertEqual(LedgerSummaryFocus.pending.taskIDs(in: after), ["missing", "usd"])
        XCTAssertEqual(LedgerSummaryFocus.currency("CNY").taskIDs(in: after), ["missing"])
        XCTAssertEqual(LedgerSummaryFocus.invoice("CNY", "已开票").taskIDs(in: after), ["missing"])
        XCTAssertTrue(LedgerSummaryFocus.invoice("CNY", "未开票").taskIDs(in: after).isEmpty)
        XCTAssertEqual(LedgerSummaryFocus.payment("CNY", "已收款").taskIDs(in: after), ["missing"])
        XCTAssertEqual(LedgerSummaryFocus.client("CNY", "客户乙").taskIDs(in: after), ["missing"])
        XCTAssertTrue(LedgerSummaryFocus.client("CNY", "客户甲").taskIDs(in: after).isEmpty)
        XCTAssertEqual(after.currencies.first { $0.code == "CNY" }?.total, Decimal(string: "12.25"))
        XCTAssertEqual(store.state["tasks"].records.first?["amountTaxInclusive"], .null)
    }

    func testAllPendingAndCurrentFilterHaveIndependentFocusResults() {
        let records = [task("one", amount: 10), task("two", amount: 20), task("missing"),
                       task("closed", amount: 30, fields: ["status": "completed"]),
                       task("private", amount: 40, fields: ["taskSpace": "personal"])]
        let all = StudioLedgerSummary(tasks: records)
        let filtered = StudioLedgerSummary(tasks: records, scopeIDs: ["two", "missing", "closed", "private"])
        XCTAssertEqual(LedgerSummaryFocus.pending.taskIDs(in: all), ["one", "two", "missing"])
        XCTAssertEqual(LedgerSummaryFocus.pending.taskIDs(in: filtered), ["two", "missing"])
        XCTAssertEqual(LedgerSummaryFocus.currency("CNY").taskIDs(in: filtered), ["two", "missing"])
        XCTAssertEqual(LedgerSummaryFocus.missing.taskIDs(in: filtered), ["missing"])
        XCTAssertEqual(all.currencies.first?.total, 30)
        XCTAssertEqual(filtered.currencies.first?.total, 20)
        XCTAssertTrue(LedgerSummaryFocus.currency("EUR").taskIDs(in: filtered).isEmpty)
    }

    func testIssueFocusKeepsExcludedProjectsDiscoverable() {
        let summary = StudioLedgerSummary(tasks: [task("invalid", amount: "not a number"),
            task("parent", amount: 100), task("child", amount: 25, fields: ["parentId": "parent"]),
            task("duplicate", amount: 2), task("duplicate", amount: 3)])
        XCTAssertEqual(LedgerSummaryFocus.invalid.taskIDs(in: summary), ["invalid"])
        XCTAssertEqual(LedgerSummaryFocus.overlap.taskIDs(in: summary), ["parent", "child"])
        XCTAssertEqual(LedgerSummaryFocus.duplicates.taskIDs(in: summary), ["duplicate"])
        XCTAssertEqual(LedgerSummaryFocus.pending.taskIDs(in: summary), ["invalid", "parent", "child", "duplicate"])
        XCTAssertTrue(summary.countedIDs.isEmpty)
    }

    func testMoneyDisplayPreservesZeroDecimalsAndCurrencyIdentity() throws {
        XCTAssertEqual(LedgerMoneyFormat.text(0, currency: "CNY"), "¥0.00")
        XCTAssertEqual(LedgerMoneyFormat.text(try XCTUnwrap(Decimal(string: "1234.5")), currency: "CNY"), "¥1,234.50")
        XCTAssertEqual(LedgerMoneyFormat.text(try XCTUnwrap(Decimal(string: "0.3")), currency: "USD"), "USD 0.30")
        XCTAssertEqual(LedgerMoneyFormat.text(20, currency: "EUR"), "EUR 20.00")
    }

    func testSidebarBecomesDrawerWithoutSqueezingNarrowWindows() {
        XCTAssertFalse(LedgerSummaryLayout.isInline(width: 720))
        XCTAssertFalse(LedgerSummaryLayout.isInline(width: 1139))
        XCTAssertTrue(LedgerSummaryLayout.isInline(width: 1140))
        XCTAssertTrue(LedgerSummaryLayout.isInline(width: 1600))
        XCTAssertEqual(LedgerSummaryLayout.sidebarWidth, 326)
    }

    func testExpandedAndScopePreferencesAreIsolatedByWorkspace() throws {
        let name = "HeroOOS.ledger-summary-preferences." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let expandedA = WorkspaceViewState.preferenceKey("ledger.summaryExpanded", identity: "account-a")
        let expandedB = WorkspaceViewState.preferenceKey("ledger.summaryExpanded", identity: "account-b")
        let scopeA = WorkspaceViewState.preferenceKey("ledger.summaryScope", identity: "account-a")
        let scopeB = WorkspaceViewState.preferenceKey("ledger.summaryScope", identity: "account-b")
        XCTAssertEqual(Set([expandedA, expandedB, scopeA, scopeB]).count, 4)
        defaults.set(false, forKey: expandedA); defaults.set("filtered", forKey: scopeA)
        defaults.set(true, forKey: expandedB); defaults.set("all", forKey: scopeB)
        XCTAssertFalse(defaults.bool(forKey: expandedA))
        XCTAssertEqual(defaults.string(forKey: scopeA), "filtered")
        XCTAssertTrue(defaults.bool(forKey: expandedB))
        XCTAssertEqual(defaults.string(forKey: scopeB), "all")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testHostedLedgerControlsAndSidebarAreNotBlankDismissalTargets() throws {
        _ = NSApplication.shared
        for (width, expanded) in [(CGFloat(1500), true), (CGFloat(900), true), (CGFloat(900), false)] {
            let identity = "HeroOOS.ledger-host-test." + UUID().uuidString
            let preferenceNames = ["ledger.kind", "ledger.category", "ledger.delivery", "ledger.invoice",
                                   "ledger.summaryExpanded", "ledger.summaryScope"]
            let store = temporaryStore()
            store.state = ["tasks": .array([task("fixture", amount: 100, fields: ["client": "客户甲"]).json])]
            let original = store.state
            UserDefaults.standard.set(expanded, forKey: WorkspaceViewState.preferenceKey("ledger.summaryExpanded", identity: identity))
            let host = NSHostingView(rootView: LedgerView(selected: .constant("fixture"), search: "", workspaceIdentity: identity)
                .environmentObject(store).frame(width: width, height: 700))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
            host.layoutSubtreeIfNeeded()
            defer {
                window.contentView = nil; store.stop()
                for name in preferenceNames {
                    UserDefaults.standard.removeObject(forKey: WorkspaceViewState.preferenceKey(name, identity: identity))
                }
            }

            let controls = descendants(host).filter {
                $0 is NSPopUpButton || String(describing: type(of: $0)).contains("SwiftUIPopupButton")
            }
            if controls.count < 4 {
                // Newer SwiftUI may draw filter popups without individual AppKit control views.
                let marker = try XCTUnwrap(descendants(host).compactMap { $0 as? DetailProtectedView }
                    .first { $0.bounds.width > 500 && $0.bounds.height < 200 })
                let visible = marker.bounds.intersection(marker.visibleRect)
                XCTAssertGreaterThan(visible.width, 40)
                for fraction in [0.15, 0.35, 0.55, 0.75] {
                    let point = host.convert(NSPoint(x: visible.minX + visible.width * fraction, y: visible.midY), from: marker)
                    XCTAssertFalse(DetailClickPolicy.isBlank(at: point, in: host, hit: host.hitTest(point)))
                    XCTAssertFalse(host.hitTest(point) is DetailProtectedView)
                }
            }
            for control in controls {
                for x in [control.bounds.minX + 4, control.bounds.midX, control.bounds.maxX - 4] {
                    let point = host.convert(NSPoint(x: x, y: control.bounds.midY), from: control)
                    let hit = host.hitTest(point)
                    XCTAssertFalse(DetailClickPolicy.isBlank(at: point, in: host, hit: hit), "Ledger filters must not dismiss task details")
                    XCTAssertFalse(hit is DetailProtectedView, "Protection must not consume control clicks")
                }
            }

            let panels = descendants(host).compactMap { $0 as? DetailProtectedView }.filter { $0.bounds.height > 300 }
            XCTAssertEqual(panels.count, expanded ? 1 : 0, "Only expanded summary must protect its full panel")
            if let panel = panels.first {
                XCTAssertEqual(panel.bounds.width, LedgerSummaryLayout.sidebarWidth, accuracy: 1)
                let point = host.convert(NSPoint(x: panel.bounds.midX, y: panel.bounds.midY), from: panel)
                XCTAssertFalse(DetailClickPolicy.isBlank(at: point, in: host, hit: host.hitTest(point)))
                XCTAssertFalse(host.hitTest(point) is DetailProtectedView)
            }
            XCTAssertEqual(store.state, original)
            XCTAssertTrue(store.pending.isEmpty)
        }
    }
}
