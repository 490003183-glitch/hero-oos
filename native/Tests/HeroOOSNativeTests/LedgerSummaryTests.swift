import XCTest
@testable import HeroOOSNative

final class LedgerSummaryTests: XCTestCase {
    private func task(_ id: String, amount: JSON = .null, fields: [String: JSON] = [:]) -> Record {
        Record(["id": .string(id), "title": .string(id), "taskSpace": "work", "status": "ready", "ledgerEnabled": true,
                "amountTaxInclusive": amount].merging(fields) { _, new in new })
    }

    private func currency(_ summary: StudioLedgerSummary, _ code: String = "CNY") throws -> StudioLedgerSummary.CurrencySummary {
        try XCTUnwrap(summary.currencies.first { $0.code == code })
    }

    func testOpenLedgerEligibilityIncludesInformationButNotPrivateOrClosed() throws {
        let open = ["ready", "active", "waiting", "review", "backlog", "blocked", "information"]
        let records = open.map { task($0, amount: 10, fields: ["status": .string($0)]) }
            + [task("completed", amount: 99, fields: ["status": "completed"]),
               task("cancelled", amount: 99, fields: ["status": "cancelled"]),
               task("paused", amount: 99, fields: ["status": "paused"]),
               task("archived", amount: 99, fields: ["archived": true]),
               task("private", amount: 99, fields: ["taskSpace": "personal"]),
               task("not-ledger", amount: 99, fields: ["ledgerEnabled": false]),
               task("legacy", amount: 5, fields: ["ledgerEnabled": false, "ledgerID": "历史项目"])]
        let summary = StudioLedgerSummary(tasks: records)
        XCTAssertEqual(summary.pendingCount, 8)
        XCTAssertEqual(summary.countedAmountCount, 8)
        XCTAssertEqual(try currency(summary).total, 75)
        XCTAssertEqual(summary.countedIDs, Set(open + ["legacy"]))
    }

    func testMissingZeroAndInvalidAmountsAreDistinct() throws {
        let summary = StudioLedgerSummary(tasks: [task("missing"), task("zero", amount: 0),
            task("negative", amount: -1), task("text", amount: "3000"), task("empty-text", amount: ""),
            task("bool", amount: true), task("infinite", amount: .number(.infinity)),
            task("nan", amount: .number(.nan)), task("too-large", amount: .number(.greatestFiniteMagnitude))])
        XCTAssertEqual(summary.pendingCount, 9)
        XCTAssertEqual(summary.countedIDs, ["zero"])
        XCTAssertEqual(summary.missingAmountIDs, ["missing"])
        XCTAssertEqual(summary.invalidAmountIDs, ["negative", "text", "empty-text", "bool", "infinite", "nan", "too-large"])
        XCTAssertEqual(try currency(summary).total, 0)
        XCTAssertEqual(try currency(summary).pendingCount, 9)
    }

    func testDecimalAdditionDoesNotAccumulateBinaryFloatingPointError() throws {
        let summary = StudioLedgerSummary(tasks: [task("one", amount: 0.1), task("two", amount: 0.2), task("three", amount: 1000.01)])
        XCTAssertEqual(try currency(summary).total, Decimal(string: "1000.31"))
        XCTAssertEqual(try currency(summary).invoiceBuckets.first?.total, Decimal(string: "1000.31"))
    }

    func testCurrenciesAreNormalizedButNeverConvertedOrMixed() throws {
        let summary = StudioLedgerSummary(tasks: [task("legacy", amount: 1), task("blank", amount: 2, fields: ["currency": " "]),
            task("rmb", amount: 3, fields: ["currency": " rmb "]), task("chinese", amount: 4, fields: ["currency": "人民币"]),
            task("yuan", amount: 5, fields: ["currency": "元"]), task("cny", amount: 6, fields: ["currency": "CNY"]),
            task("usd", amount: 7, fields: ["currency": "usd"]), task("eur", amount: 8, fields: ["currency": "EUR"]),
            task("hkd-missing", fields: ["currency": "HKD"])])
        XCTAssertEqual(summary.legacyCurrencyIDs, ["legacy", "blank"])
        XCTAssertEqual(try currency(summary).total, 21)
        XCTAssertEqual(try currency(summary, "USD").total, 7)
        XCTAssertEqual(try currency(summary, "EUR").total, 8)
        XCTAssertEqual(try currency(summary, "HKD").total, 0)
        XCTAssertEqual(try currency(summary, "HKD").taskIDs, ["hkd-missing"])
        XCTAssertEqual(summary.currencies.map(\.code), ["CNY", "EUR", "HKD", "USD"])
    }

    func testInvoiceAndPaymentBucketsKeepPartialAndUnknownStatuses() throws {
        let summary = StudioLedgerSummary(tasks: [
            task("unpaid", amount: 1, fields: ["invoiceStatus": "未开票", "paymentStatus": "未收款"]),
            task("partial", amount: 2, fields: ["invoiceStatus": "部分开票", "paymentStatus": "部分收款"]),
            task("paid", amount: 3, fields: ["invoiceStatus": "已开票", "paymentStatus": "已收款"]),
            task("booked", amount: 4, fields: ["paymentStatus": "已入账"]),
            task("arrived", amount: 5, fields: ["paymentStatus": "已到账"]),
            task("settled", amount: 6, fields: ["paymentStatus": "已结清"]),
            task("na", amount: 7, fields: ["invoiceStatus": "不适用", "paymentStatus": "不适用"]),
            task("unknown", amount: 8, fields: ["invoiceStatus": "核实中", "paymentStatus": "待付款"]),
            task("not-provided", amount: 9, fields: ["paymentStatus": "未提供"]), task("empty", amount: 10)
        ])
        let value = try currency(summary)
        let payments = Dictionary(uniqueKeysWithValues: value.paymentBuckets.map { ($0.label, $0) })
        let invoices = Dictionary(uniqueKeysWithValues: value.invoiceBuckets.map { ($0.label, $0) })
        XCTAssertEqual(payments["已收款"]?.total, 18)
        XCTAssertEqual(payments["已收款"]?.taskIDs, ["paid", "booked", "arrived", "settled"])
        XCTAssertEqual(payments["部分收款"]?.total, 2)
        XCTAssertEqual(payments["待付款"]?.total, 8)
        XCTAssertEqual(payments["待确认"]?.taskIDs, ["not-provided", "empty"])
        XCTAssertEqual(invoices["部分开票"]?.total, 2)
        XCTAssertEqual(invoices["核实中"]?.taskIDs, ["unknown"])
        XCTAssertEqual(invoices["未填写"]?.pendingCount, 5)
    }

    func testNoInferenceFromTitleNotesDeliveryOrOtherMoneyFields() throws {
        let misleading = task("real", amount: 100, fields: ["title": "已开票已入账 6k", "note": "已收款3000", "deliveryStatus": "已交付", "feeAmount": 6000])
        let missing = task("missing", fields: ["title": "5000元", "note": "未收款", "feeAmount": 6000])
        let summary = StudioLedgerSummary(tasks: [misleading, missing])
        let value = try currency(summary)
        XCTAssertEqual(value.total, 100)
        XCTAssertEqual(value.paymentBuckets.map(\.label), ["待确认"])
        XCTAssertEqual(value.invoiceBuckets.map(\.label), ["未填写"])
        XCTAssertEqual(summary.missingAmountIDs, ["missing"])
    }

    func testClientBucketsKeepMissingAndExcludedRecordsDiscoverable() throws {
        let summary = StudioLedgerSummary(tasks: [task("a", amount: 10, fields: ["client": " 客户甲 "]),
            task("b", fields: ["client": "客户甲"]), task("c", amount: 0)])
        let buckets = try currency(summary).clientBuckets
        let named = try XCTUnwrap(buckets.first { $0.label == "客户甲" })
        XCTAssertEqual(named.total, 10)
        XCTAssertEqual(named.taskIDs, ["a", "b"])
        XCTAssertEqual(named.countedIDs, ["a"])
        XCTAssertEqual(buckets.first { $0.label == "客户未填写" }?.taskIDs, ["c"])
    }

    func testScopeNarrowsSummaryWithoutChangingUnderlyingRecords() throws {
        let records = [task("a", amount: 10), task("b", amount: 20), task("c")]
        let before = try JSON.array(records.map(\.json)).encoded()
        let summary = StudioLedgerSummary(tasks: records, scopeIDs: ["b", "c", "absent"])
        XCTAssertEqual(summary.records.map(\.id), ["b", "c"])
        XCTAssertEqual(summary.countedIDs, ["b"])
        XCTAssertEqual(summary.missingAmountIDs, ["c"])
        XCTAssertEqual(try currency(summary).total, 20)
        XCTAssertEqual(try JSON.array(records.map(\.json)).encoded(), before)
        XCTAssertEqual(StudioLedgerSummary(tasks: records, scopeIDs: []).pendingCount, 0)
        XCTAssertTrue(StudioLedgerSummary(tasks: records, scopeIDs: []).currencies.isEmpty)
    }

    func testParentAndChildrenAmountsAreAllExcludedIncludingHiddenAncestors() throws {
        let records = [task("parent", amount: 100), task("middle", fields: ["ledgerEnabled": false, "parentId": "parent"]),
            task("child", amount: 60, fields: ["parentId": "middle"]), task("sibling", amount: 40, fields: ["parentId": "parent"]),
            task("separate", amount: 7)]
        let all = StudioLedgerSummary(tasks: records)
        XCTAssertEqual(all.overlappingAmountIDs, ["parent", "child", "sibling"])
        XCTAssertEqual(all.countedIDs, ["separate"])
        XCTAssertEqual(try currency(all).total, 7)
        let filtered = StudioLedgerSummary(tasks: records, scopeIDs: ["child"])
        XCTAssertEqual(filtered.overlappingAmountIDs, ["child"])
        XCTAssertEqual(filtered.countedAmountCount, 0)
        XCTAssertEqual(try currency(filtered).total, 0)
        XCTAssertEqual(try currency(filtered).invoiceBuckets.first?.taskIDs, ["child"])
    }

    func testSiblingAmountsAreNotDuplicatesWhenAncestorHasNoAmount() throws {
        let records = [task("parent"), task("child", amount: 60, fields: ["parentId": "parent"]),
            task("sibling", amount: 40, fields: ["parentId": "parent"])]
        let summary = StudioLedgerSummary(tasks: records)
        XCTAssertTrue(summary.overlappingAmountIDs.isEmpty)
        XCTAssertEqual(try currency(summary).total, 100)
        XCTAssertEqual(summary.missingAmountIDs, ["parent"])
    }

    func testClosedParentDoesNotMakeOpenChildAmountAmbiguous() throws {
        let summary = StudioLedgerSummary(tasks: [task("parent", amount: 100, fields: ["status": "completed"]),
            task("child", amount: 60, fields: ["parentId": "parent"])])
        XCTAssertTrue(summary.overlappingAmountIDs.isEmpty)
        XCTAssertEqual(try currency(summary).total, 60)
    }

    func testHierarchyCyclesAndDuplicateIDsTerminateWithoutDoubleCounting() throws {
        let summary = StudioLedgerSummary(tasks: [task("a", amount: 10, fields: ["parentId": "b"]),
            task("b", amount: 20, fields: ["parentId": "a"]), task("duplicate", amount: 30),
            task("duplicate", amount: 40), task("self", amount: 5, fields: ["parentId": "self"])])
        XCTAssertEqual(summary.pendingCount, 4)
        XCTAssertEqual(summary.overlappingAmountIDs, ["a", "b"])
        XCTAssertEqual(summary.duplicateTaskIDs, ["duplicate"])
        XCTAssertEqual(summary.countedIDs, ["self"])
        XCTAssertEqual(try currency(summary).total, 5)
    }

    func testZeroAmountsStillParticipateInHierarchyAmbiguity() {
        let summary = StudioLedgerSummary(tasks: [task("parent", amount: 0), task("child", amount: 10, fields: ["parentId": "parent"])])
        XCTAssertEqual(summary.overlappingAmountIDs, ["parent", "child"])
        XCTAssertEqual(summary.countedAmountCount, 0)
    }

    func testDuplicateIDWithClosedVersionIsStillFlagged() throws {
        let summary = StudioLedgerSummary(tasks: [task("a", amount: 10), task("a", amount: 20, fields: ["status": "completed"])])
        XCTAssertEqual(summary.pendingCount, 1)
        XCTAssertEqual(summary.duplicateTaskIDs, ["a"])
        XCTAssertEqual(summary.countedAmountCount, 0)
        XCTAssertEqual(try currency(summary).total, 0)
    }

    func testDuplicateVersionWithAmountStillFlagsItsNumericAncestor() throws {
        let summary = StudioLedgerSummary(tasks: [task("parent", amount: 100),
            task("child", fields: ["parentId": "parent"]), task("child", amount: 40, fields: ["parentId": "parent"])])
        XCTAssertEqual(summary.pendingCount, 2)
        XCTAssertEqual(summary.duplicateTaskIDs, ["child"])
        XCTAssertEqual(summary.overlappingAmountIDs, ["parent", "child"])
        XCTAssertEqual(summary.countedAmountCount, 0)
        XCTAssertEqual(try currency(summary).total, 0)
    }

    func testPrecisionOverflowIsFlaggedInsteadOfReturningRoundedOrInvalidTotal() throws {
        let summary = StudioLedgerSummary(tasks: [task("large", amount: .number(1e100)), task("small", amount: 0.1)])
        XCTAssertEqual(summary.invalidAmountIDs, ["large", "small"])
        XCTAssertTrue(summary.countedIDs.isEmpty)
        XCTAssertEqual(try currency(summary).total, 0)
    }
}
