import XCTest
@testable import HeroOOSNative

final class SyncPresentationTests: XCTestCase {
    func testOneConfirmedScopeCannotHideOtherScopeOfflineOrConflict() {
        XCTAssertEqual(CloudSyncSummary(phases: [.upToDate, .offline], pending: 2, localUnsaved: false).text, "离线 · 待同步 2 项")
        XCTAssertEqual(CloudSyncSummary(phases: [.conflict, .syncing], pending: 1, localUnsaved: false).phase, .conflict)
        XCTAssertEqual(CloudSyncSummary(phases: [.upToDate, .notChecked], pending: 0, localUnsaved: false).phase, .notChecked)
        XCTAssertEqual(CloudSyncSummary(phases: [.upToDate, .authenticationRequired], pending: 0, localUnsaved: false).phase, .authenticationRequired)
    }
    func testUnsavedLocalDraftNeverShowsFullyConfirmed() {
        XCTAssertEqual(CloudSyncSummary(phases: [.upToDate, .upToDate], pending: 0, localUnsaved: true).text, "等待本机保存")
        XCTAssertEqual(CloudSyncSummary(phases: [.upToDate, .upToDate], pending: 0, localUnsaved: false).text, "服务端已确认")
    }
    func testPartialAndFullPauseAreDistinct() {
        XCTAssertEqual(CloudSyncSummary(phases: [.paused, .upToDate], pending: 0, localUnsaved: false).text, "部分同步暂停")
        XCTAssertEqual(CloudSyncSummary(phases: [.paused, .paused], pending: 3, localUnsaved: false).text, "同步已暂停 · 待同步 3 项")
    }
}
