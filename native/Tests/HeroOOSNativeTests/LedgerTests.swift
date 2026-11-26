import XCTest
@testable import HeroOOSNative

final class LedgerTests: XCTestCase {
    func testInformationIsOpenButNotPersonallyExecuted() {
        let task = Record(["status": "information"])
        XCTAssertTrue(task.isOpen)
        XCTAssertFalse(task.isClosed)
        XCTAssertFalse(task.isExecutionTracked)
        for status in ["completed", "cancelled", "paused"] {
            let closed = Record(["status": .string(status)])
            XCTAssertFalse(closed.isOpen)
            XCTAssertFalse(closed.isExecutionTracked)
        }
        for status in ["ready", "active", "waiting", "review", "backlog", "blocked"] {
            let task = Record(["status": .string(status)])
            XCTAssertTrue(task.isOpen)
            XCTAssertTrue(task.isExecutionTracked)
        }
    }
    func testAllSourceColumnsHaveDedicatedFields() {
        XCTAssertEqual(StudioLedger.fields.count, 16)
        XCTAssertEqual(Set(StudioLedger.fields.map(\.key)).count, 16)
        XCTAssertEqual(Set(StudioLedger.fields.map(\.title)).count, 16)
    }
    func testDeliveredDoesNotMeanCompleted() {
        XCTAssertEqual(StudioLedger.initialStatus(delivery: "已交付"), "review")
        XCTAssertEqual(StudioLedger.initialStatus(delivery: "待执行"), "ready")
        XCTAssertEqual(StudioLedger.initialStatus(delivery: "仅知情"), "information")
        XCTAssertEqual(StudioLedger.initialStatus(delivery: "等待中"), "waiting")
        XCTAssertEqual(StudioLedger.initialStatus(delivery: "暂未排期"), "backlog")
        XCTAssertEqual(TaskStatus(rawValue: "backlog")?.title, "暂未排期")
    }
    func testZeroAmountIsDifferentFromMissing() {
        XCTAssertEqual(StudioLedger.amountText(Record(["amountTaxInclusive": 0])), "0")
        XCTAssertEqual(StudioLedger.amountText(Record()), "未填写")
    }
    func testSearchIncludesPeopleCategoriesChannelsAndDetails() {
        let record = Record(["title": "项目", "contact": "周老师", "subcategory": "校园活动", "sourceChannelOwner": "赵先生", "details": ["定稿版本"]])
        for query in ["周老师", "校园活动", "赵先生", "定稿版本"] { XCTAssertTrue(StudioLedger.matches(record, query: query)) }
        XCTAssertFalse(StudioLedger.matches(record, query: "不存在"))
    }
    @MainActor func testUnscheduledTasksRankAfterExecutableTasks() {
        let store = OOSStore(recoverDrafts: false)
        let backlog = Record(["id": "later", "status": "backlog", "priority": 10, "due": "2020-01-01"])
        let ready = Record(["id": "now", "status": "ready", "priority": 1])
        XCTAssertEqual(store.ranked([backlog, ready]).first?.id, "now")
    }
}

final class LedgerIntegrationTests: SwiftIntegrationCase {
    func testInformationWithDueDateDoesNotEnterAttention() throws {
        _ = try mutate([["type": "task.create", "task": ["id": "delegated", "title": "代管项目", "status": "information", "due": "2020-01-01", "reviewDate": "2020-01-01"]]])
        let state = try runtime.readState()
        XCTAssertTrue(state["tasks"].records[0].isOpen)
        XCTAssertFalse(runtime.attention(state).contains { $0["id"] == "delegated" })
    }
    @MainActor func testLedgerFieldsAutosaveAndPreserveOriginalCells() async throws {
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let created = await store.createTask(title: "台账测试", fields: ["ledgerEnabled": true, "recordType": "项目"])
        let id = try XCTUnwrap(created)
        let source: JSON = ["filename": "台账.csv", "fields": ["金额(含税)": "0", "子分类": "无", "备注": "原文\n第二行"]]
        let values: [String: JSON] = ["ledgerID": "项目-测试", "startDate": "2026-09-22", "mustExecuteAt": "2026-09-22T15:00:00+08:00", "subcategory": "无", "nextAction": "核查", "blockedBy": "甲", "client": "公司", "contact": "乙", "executor": "丙", "amountTaxInclusive": 0, "deliveryStatus": "已交付", "invoiceStatus": "未开票", "sourceChannelOwner": "丁", "currentChannelOwner": "戊", "note": "原文\n第二行", "ledgerSource": source]
        for (key, value) in values { store.edit(id, key, value) }
        try await Task.sleep(for: .seconds(1.2))
        let reopened = OOSStore(api: api, recoverDrafts: false); await reopened.refresh()
        let record = try XCTUnwrap(reopened.task(id))
        for (key, value) in values { XCTAssertEqual(record[key], value, key) }
        XCTAssertEqual(record.status, "ready")
        XCTAssertFalse(record.isClosed)
        XCTAssertEqual(record["due"], .null)
        XCTAssertEqual(record["reviewDate"], .null)
        XCTAssertEqual(Dates.parse(record.text("mustExecuteAt")), Dates.parse("2026-09-22T07:00:00Z"))
        reopened.edit(id, "amountTaxInclusive", .null)
        let saved = await reopened.flush(); XCTAssertTrue(saved)
        XCTAssertEqual(reopened.task(id)?["amountTaxInclusive"], .null)
        XCTAssertEqual(reopened.task(id)?["ledgerSource"], source)
    }
    func testInvalidLedgerAmountRejectedBySharedCore() throws {
        for value: JSON in [-1, "3000"] {
            XCTAssertThrowsError(try mutate([["type": "task.create", "task": ["id": "bad", "title": "非法金额", "amountTaxInclusive": value]]]))
        }
        XCTAssertEqual(try runtime.readState()["tasks"].array.count, 0)
    }
    @MainActor func testDifferentLedgerFieldsMergeAcrossEditors() async throws {
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let created = await store.createTask(title: "台账并发", fields: ["ledgerEnabled": true])
        let id = try XCTUnwrap(created)
        store.edit(id, "contact", "本地联系人")
        _ = try mutate([["type": "task.update", "id": .string(id), "changes": ["invoiceStatus": "已开票"]]])
        let saved = await store.flush(); XCTAssertTrue(saved)
        XCTAssertEqual(store.task(id)?.text("contact"), "本地联系人")
        XCTAssertEqual(store.task(id)?.text("invoiceStatus"), "已开票")
    }
}
