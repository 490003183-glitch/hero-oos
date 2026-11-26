import Foundation

/// A read-only projection of open ledger project amounts. Amounts attached to
/// invoice/payment states are project amounts, not invoiced/remaining balances.
/// Callers must supply all authorized tasks; scopeIDs only narrows presentation.
public struct StudioLedgerSummary: Sendable {
    public struct Bucket: Identifiable, Sendable {
        public let label: String
        public let total: Decimal
        public let taskIDs: Set<String>
        public let countedIDs: Set<String>
        public var id: String { label }
        public var pendingCount: Int { taskIDs.count }
        public var countedAmountCount: Int { countedIDs.count }
    }

    public struct CurrencySummary: Identifiable, Sendable {
        public let code: String
        public let total: Decimal
        public let taskIDs: Set<String>
        public let countedIDs: Set<String>
        public let invoiceBuckets: [Bucket]
        public let paymentBuckets: [Bucket]
        public let clientBuckets: [Bucket]
        public var id: String { code }
        public var pendingCount: Int { taskIDs.count }
        public var countedAmountCount: Int { countedIDs.count }
    }

    public let records: [Record]
    public let countedIDs: Set<String>
    public let missingAmountIDs: Set<String>
    public let invalidAmountIDs: Set<String>
    public let overlappingAmountIDs: Set<String>
    public let duplicateTaskIDs: Set<String>
    public let legacyCurrencyIDs: Set<String>
    public let currencies: [CurrencySummary]
    public var pendingCount: Int { records.count }
    public var countedAmountCount: Int { countedIDs.count }

    public init(tasks: [Record], scopeIDs: Set<String>? = nil) {
        var seen = Set<String>(), duplicates = Set<String>()
        var allRecords = [Record]()
        for task in tasks where StudioLedger.contains(task) && task.isOpen && !task.id.isEmpty {
            if seen.insert(task.id).inserted { allRecords.append(task) }
            else { duplicates.insert(task.id) }
        }
        // A duplicate elsewhere in the input is ambiguous even when its second
        // version is closed/non-ledger. Never count both or silently pick money.
        var allIDs = Set<String>()
        for task in tasks where !task.id.isEmpty {
            if !allIDs.insert(task.id).inserted { duplicates.insert(task.id) }
        }
        var amounts = [String: Decimal](), missing = Set<String>(), invalid = Set<String>()
        for task in allRecords {
            if task["amountTaxInclusive"] == .null { missing.insert(task.id) }
            else if let amount = Self.amount(task) { amounts[task.id] = amount }
            else { invalid.insert(task.id) }
        }

        // Search the complete parent graph, including non-ledger intermediates.
        // Ancestor amounts are ambiguous with descendant amounts, including
        // when one side is hidden by the table's current search/filter.
        var parents = [String: Set<String>]()
        for task in tasks where !task.id.isEmpty && !task.text("parentId").isEmpty {
            parents[task.id, default: []].insert(task.text("parentId"))
        }
        var overlaps = Set<String>()
        // Inspect every version of duplicate IDs for hierarchy ambiguity, even
        // when the first version lacks an amount and a later version has one.
        let numericIDs = Set(tasks.filter {
            StudioLedger.contains($0) && $0.isOpen && !$0.id.isEmpty && Self.amount($0) != nil
        }.map(\.id))
        for id in numericIDs {
            var visited: Set<String> = [id]
            var remaining = Array(parents[id] ?? [])
            while let ancestor = remaining.popLast() {
                guard visited.insert(ancestor).inserted else { continue }
                if numericIDs.contains(ancestor) {
                    overlaps.insert(id); overlaps.insert(ancestor)
                }
                remaining.append(contentsOf: parents[ancestor] ?? [])
            }
        }

        let records = allRecords.filter { scopeIDs?.contains($0.id) ?? true }
        let visibleIDs = Set(records.map(\.id))
        var counted = Set(amounts.keys).intersection(visibleIDs).subtracting(overlaps).subtracting(duplicates)
        let grouped = Dictionary(grouping: records, by: Self.currency)
        // Decimal has bounded precision. An unrepresentable aggregate must not
        // silently become NaN, infinity, or a rounded financial total.
        for group in grouped.values {
            let ids = Set(group.map(\.id)).intersection(counted)
            if Self.sum(ids: ids, amounts: amounts) == nil {
                invalid.formUnion(ids); counted.subtract(ids)
            }
        }
        self.records = records
        countedIDs = counted
        missingAmountIDs = missing.intersection(visibleIDs)
        invalidAmountIDs = invalid.intersection(visibleIDs)
        overlappingAmountIDs = overlaps.intersection(visibleIDs)
        duplicateTaskIDs = duplicates.intersection(visibleIDs)
        legacyCurrencyIDs = Set(records.filter { $0.text("currency").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id))
        currencies = grouped.keys.sorted { lhs, rhs in
            if lhs == "CNY" { return rhs != "CNY" }
            if rhs == "CNY" { return false }
            return lhs < rhs
        }.map { code in
            let group = grouped[code] ?? []
            let ids = Set(group.map(\.id)), included = ids.intersection(counted)
            return CurrencySummary(
                code: code, total: Self.sum(ids: included, amounts: amounts) ?? 0,
                taskIDs: ids, countedIDs: included,
                invoiceBuckets: Self.buckets(group, counted: counted, amounts: amounts,
                    order: ["未开票", "部分开票", "已开票", "不适用", "未填写"], label: Self.invoiceStatus),
                paymentBuckets: Self.buckets(group, counted: counted, amounts: amounts,
                    order: ["未收款", "部分收款", "已收款", "不适用", "待确认"], label: Self.paymentStatus),
                clientBuckets: Self.buckets(group, counted: counted, amounts: amounts, order: []) {
                    let client = $0.text("client").trimmingCharacters(in: .whitespacesAndNewlines)
                    return client.isEmpty ? "客户未填写" : client
                }
            )
        }
    }

    private static func amount(_ task: Record) -> Decimal? {
        guard case .number(let number) = task["amountTaxInclusive"], number.isFinite, number >= 0,
              let value = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }

    /// Historical ledger rows predate currency selection. Their empty currency
    /// is interpreted as CNY, never silently written back, and disclosed through
    /// legacyCurrencyIDs. Explicit currencies are never converted.
    private static func currency(_ task: Record) -> String {
        let value = task.text("currency").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || ["CNY", "RMB", "人民币", "元"].contains(value.uppercased()) { return "CNY" }
        return value.uppercased()
    }

    private static func invoiceStatus(_ task: Record) -> String {
        let value = task.text("invoiceStatus").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未填写" : value
    }

    private static func paymentStatus(_ task: Record) -> String {
        let value = task.text("paymentStatus").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "未提供" { return "待确认" }
        if ["已入账", "已到账", "已结清"].contains(value) { return "已收款" }
        return value
    }

    private static func sum(ids: Set<String>, amounts: [String: Decimal]) -> Decimal? {
        var total: Decimal = 0
        for id in ids.sorted() {
            guard var amount = amounts[id] else { continue }
            var next: Decimal = 0
            guard NSDecimalAdd(&next, &total, &amount, .plain) == .noError, !next.isNaN else { return nil }
            total = next
        }
        return total
    }

    private static func buckets(_ records: [Record], counted: Set<String>, amounts: [String: Decimal],
                                order: [String], label: (Record) -> String) -> [Bucket] {
        let grouped = Dictionary(grouping: records, by: label)
        return grouped.keys.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs) ?? order.count, right = order.firstIndex(of: rhs) ?? order.count
            return left == right ? lhs < rhs : left < right
        }.map { label in
            let ids = Set((grouped[label] ?? []).map(\.id)), included = ids.intersection(counted)
            return Bucket(label: label, total: sum(ids: included, amounts: amounts) ?? 0, taskIDs: ids, countedIDs: included)
        }
    }
}
