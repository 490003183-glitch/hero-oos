import XCTest
@testable import HeroOOSNative

@MainActor final class TaskClickTests: XCTestCase {
    func testSingleClickSelectsSynchronouslyWithoutWaitingForDoubleClick() {
        let view = TaskDragView()
        var selected = 0, renamed = 0
        view.selectTask = { selected += 1 }
        view.renameTask = { renamed += 1 }
        view.handleClick(count: 1)
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(renamed, 0)
        view.handleClick(count: 2)
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(renamed, 1)
    }
    func testDoubleClickContinuationRejectsSeparateClicksAndDistantTargets() {
        XCTAssertTrue(TaskDoubleClickContinuation.matches(count: 2, elapsed: 0.1, distance: 2, interval: 0.5))
        XCTAssertFalse(TaskDoubleClickContinuation.matches(count: 1, elapsed: 0.1, distance: 2, interval: 0.5))
        XCTAssertFalse(TaskDoubleClickContinuation.matches(count: 2, elapsed: 0.6, distance: 2, interval: 0.5))
        XCTAssertFalse(TaskDoubleClickContinuation.matches(count: 2, elapsed: 0.1, distance: 50, interval: 0.5))
    }
}
