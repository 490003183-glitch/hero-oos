import Foundation

public enum StudioLedger {
    public static let fields: [(key: String, title: String)] = [
        ("ledgerID", "项目ID"), ("startDate", "开始执行日期"),
        ("mustExecuteAt", "必须执行日期"), ("title", "项目名称"),
        ("subcategory", "子分类"), ("nextAction", "当前待办事项"),
        ("blockedBy", "当前卡谁"), ("client", "客户单位"),
        ("contact", "对接人"), ("executor", "执行人"),
        ("amountTaxInclusive", "金额(含税)"), ("deliveryStatus", "交付状态"),
        ("invoiceStatus", "开票状态"), ("sourceChannelOwner", "源渠道所有"),
        ("currentChannelOwner", "现渠道所有"), ("note", "备注")
    ]
    public static let recordTypes = ["项目", "报价", "日常", "创作", "知情"]
    public static let deliveryStatuses = ["待执行", "制作中", "等待中", "暂未排期", "已交付", "仅知情"]
    public static let invoiceStatuses = ["未开票", "已开票", "部分开票", "不适用"]
    public static func contains(_ record: Record) -> Bool {
        record.taskSpace == .work && (record["ledgerEnabled"].bool || !record.text("ledgerID").isEmpty)
    }
    public static func initialStatus(delivery: String) -> String {
        // Delivery and invoicing never close the overall task implicitly.
        switch delivery {
        case "已交付": return "review"
        case "等待中": return "waiting"
        case "暂未排期": return "backlog"
        case "仅知情": return "information"
        case "制作中": return "active"
        case "待执行": return "ready"
        default: return "review"
        }
    }
    public static func matches(_ record: Record, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let keys = fields.map(\.key) + ["recordType", "project", "statusNote", "waitingCondition", "managedBy"]
        let values = keys.map { record.text($0) } + record["details"].array.map(\.string) + TaskPeopleWaits.entries(record).map(TaskPeopleWaits.label)
        return values.joined(separator: "\n").localizedCaseInsensitiveContains(query)
    }
    public static func amountText(_ record: Record) -> String {
        guard case .number(let amount) = record["amountTaxInclusive"] else { return "未填写" }
        return amount.formatted(.number.precision(.fractionLength(0...2)))
    }
}
