import XCTest
@testable import HeroOOSNative

final class ViewPreferencesTests: XCTestCase {
    func testBothSpacesDefaultToBoardEvenWithOldLastMode() throws {
        let name = "hero-oos-view-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(0, forKey: "HeroOOS.tasks.work.mode")
        defaults.set(0, forKey: "HeroOOS.tasks.personal.mode")
        XCTAssertEqual(TaskViewPreferences.mode(for: .work, defaults: defaults), .board)
        XCTAssertEqual(TaskViewPreferences.mode(for: .personal, defaults: defaults), .board)
    }
    func testIndependentDefaultsPersistAndInvalidValueFallsBack() throws {
        let name = "hero-oos-view-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(TaskViewMode.list.rawValue, forKey: TaskViewPreferences.workKey)
        XCTAssertEqual(TaskViewPreferences.mode(for: .work, defaults: defaults), .list)
        XCTAssertEqual(TaskViewPreferences.mode(for: .personal, defaults: defaults), .board)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertEqual(TaskViewPreferences.mode(for: .work, defaults: reopened), .list)
        defaults.set(99, forKey: TaskViewPreferences.personalKey)
        XCTAssertEqual(TaskViewPreferences.mode(for: .personal, defaults: defaults), .board)
    }
}
