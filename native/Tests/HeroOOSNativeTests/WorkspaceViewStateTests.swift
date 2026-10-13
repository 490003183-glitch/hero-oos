import XCTest
@testable import HeroOOSNative

final class WorkspaceViewStateTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "HeroOOS.workspace-view-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testRelaunchRestoresLastPageSelectionSearchModesAndSidebar() throws {
        try withDefaults { defaults in
            let saved = WorkspaceViewState(pageKey: "graph", selectedTaskID: "a",
                searches: ["graph": "录音", "tasks": "发票"], modes: ["work": 0, "personal": 1], sidebarHidden: true)
            saved.save(identity: "account-a", defaults: defaults)
            let reopened = WorkspaceViewState.load(identity: "account-a", defaults: defaults)
            XCTAssertEqual(reopened, saved)
            XCTAssertEqual(reopened.page, .graph)
            XCTAssertEqual(reopened.pageSearches[.progress], "发票")
            XCTAssertEqual(reopened.mode(for: .work, defaults: defaults), .list)
            XCTAssertEqual(reopened.mode(for: .personal, defaults: defaults), .board)
        }
    }
    func testAccountPreferencesAreIndependent() throws {
        try withDefaults { defaults in
            WorkspaceViewState(pageKey: "collage").save(identity: "one", defaults: defaults)
            WorkspaceViewState(pageKey: "personal").save(identity: "two", defaults: defaults)
            XCTAssertEqual(WorkspaceViewState.load(identity: "one", defaults: defaults).page, .collage)
            XCTAssertEqual(WorkspaceViewState.load(identity: "two", defaults: defaults).page, .personal)
            XCTAssertEqual(WorkspaceViewState.load(identity: "local", defaults: defaults).page, .progress)
        }
    }
    func testFirstUseUsesConfiguredDefaultButExistingLastModeTakesPrecedence() throws {
        try withDefaults { defaults in
            defaults.set(TaskViewMode.list.rawValue, forKey: TaskViewPreferences.workKey)
            XCTAssertEqual(WorkspaceViewState().mode(for: .work, defaults: defaults), .list)
            XCTAssertEqual(WorkspaceViewState(modes: ["work": 1]).mode(for: .work, defaults: defaults), .board)
            XCTAssertEqual(WorkspaceViewState(modes: ["work": 99]).mode(for: .work, defaults: defaults), .list)
        }
    }
    func testStablePageIdentifiersAndCustomPageSurviveRename() throws {
        let space = try XCTUnwrap(TaskSpace(rawValue: "page-13FC9187-4D3F-4B19-971B-720650FA3BE6"))
        for page in Page.allCases + [.taskPage(space)] {
            XCTAssertEqual(Page(persistenceKey: page.persistenceKey), page)
        }
        let saved = WorkspaceViewState(pageKey: Page.taskPage(space).persistenceKey)
        XCTAssertEqual(saved.validated(pageIDs: [space.rawValue], tasks: []).page, .taskPage(space))
        XCTAssertEqual(saved.validated(pageIDs: [], tasks: []).page, .progress)
        XCTAssertNil(Page(persistenceKey: "task-page:../../other"))
        XCTAssertEqual(Page(persistenceKey: "shared"), .progress)
    }
    func testMissingTaskAndWrongSpaceSelectionAreClearedWithoutChangingPage() {
        let task = Record(["id": "a", "title": "任务", "taskSpace": "work"])
        let saved = WorkspaceViewState(pageKey: "graph", selectedTaskID: "a")
        XCTAssertEqual(saved.validated(pageIDs: [], tasks: [task]).selectedTaskID, "a")
        XCTAssertNil(saved.validated(pageIDs: [], tasks: []).selectedTaskID)
        XCTAssertEqual(saved.validated(pageIDs: [], tasks: []).page, .graph)
        XCTAssertNil(WorkspaceViewState(pageKey: "personal", selectedTaskID: "a").validated(pageIDs: [], tasks: [task]).selectedTaskID)
    }
    func testCorruptPreferencesAndUnknownPageFallBackSafely() throws {
        try withDefaults { defaults in
            defaults.set(Data("bad json".utf8), forKey: WorkspaceViewState.key(for: "one"))
            XCTAssertEqual(WorkspaceViewState.load(identity: "one", defaults: defaults), WorkspaceViewState())
            XCTAssertEqual(WorkspaceViewState(pageKey: "future-page").page, .progress)
            XCTAssertEqual(WorkspaceViewState(searches: ["tasks": "one", "shared": "two", "future": "three"]).pageSearches.count, 1)
        }
    }
}
