import SwiftUI

enum LedgerSummaryLayout {
    static let sidebarWidth: CGFloat = 326
    // On smaller windows the panel is a drawer; it must not squeeze the table away.
    static func isInline(width: CGFloat) -> Bool { width >= 1140 }
}

enum LedgerSummaryFocus: Equatable {
    case pending, missing, invalid, overlap, duplicates
    case currency(String)
    case invoice(String, String), payment(String, String), client(String, String)

    var title: String {
        switch self {
        case .pending: return "当前统计范围内的待办项目"
        case .missing: return "金额未填写"
        case .invalid: return "金额异常"
        case .overlap: return "父子项目金额待核对"
        case .duplicates: return "重复任务编号待核对"
        case .currency(let code): return "\(code) 待办项目"
        case .invoice(let code, let label): return "\(code) · \(label)"
        case .payment(let code, let label): return "\(code) · 收款：\(label)"
        case .client(let code, let label): return "\(code) · \(label)"
        }
    }

    func taskIDs(in summary: StudioLedgerSummary) -> Set<String> {
        switch self {
        case .pending: return Set(summary.records.map(\.id))
        case .missing: return summary.missingAmountIDs
        case .invalid: return summary.invalidAmountIDs
        case .overlap: return summary.overlappingAmountIDs
        case .duplicates: return summary.duplicateTaskIDs
        case .currency(let code): return summary.currencies.first { $0.code == code }?.taskIDs ?? []
        case .invoice(let code, let label):
            return summary.currencies.first { $0.code == code }?.invoiceBuckets.first { $0.label == label }?.taskIDs ?? []
        case .payment(let code, let label):
            return summary.currencies.first { $0.code == code }?.paymentBuckets.first { $0.label == label }?.taskIDs ?? []
        case .client(let code, let label):
            return summary.currencies.first { $0.code == code }?.clientBuckets.first { $0.label == label }?.taskIDs ?? []
        }
    }
}

enum LedgerMoneyFormat {
    static func text(_ amount: Decimal, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
        return (currency == "CNY" ? "¥" : "\(currency) ") + number
    }
}

struct LedgerSummarySidebar: View {
    let summary: StudioLedgerSummary
    @Binding var scope: String
    @Binding var focus: LedgerSummaryFocus?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("金额统计", systemImage: "chart.bar.xaxis").font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "sidebar.right").frame(width: 24, height: 24) }
                        .buttonStyle(.borderless).help("收起金额统计")
                        .accessibilityLabel("收起统计侧栏")
                }
                Picker("统计范围", selection: $scope) {
                    Text("全部待办").tag("all")
                    Text("当前筛选").tag("filtered")
                }.pickerStyle(.segmented)
                Text(scope == "filtered" ? "跟随搜索与上方筛选，仅统计其中的开放任务。" : "统计整个工作室台账的待办，不受左侧列表筛选影响。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    totals
                    if !summary.missingAmountIDs.isEmpty || !summary.invalidAmountIDs.isEmpty ||
                        !summary.overlappingAmountIDs.isEmpty || !summary.duplicateTaskIDs.isEmpty {
                        issues
                    }
                    ForEach(summary.currencies, id: \.code) { currency in
                        currencySections(currency)
                    }
                    methodology
                }.padding(16)
            }
        }
        .accessibilityIdentifier("ledger.summary.sidebar")
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待办项目金额").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("含税").font(.caption).foregroundStyle(.secondary)
            }
            if summary.pendingCount == 0 {
                Text("暂无待办项目").font(.title3.weight(.semibold))
            } else {
                ForEach(summary.currencies, id: \.code) { currency in
                    Button { select(.currency(currency.code)) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            if summary.currencies.count > 1 {
                                Text(currency.code).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(currency.countedAmountCount == 0 ? "暂无可合计金额" : LedgerMoneyFormat.text(currency.total, currency: currency.code))
                                .font(.system(size: 29, weight: .semibold, design: .rounded))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(currency.countedAmountCount) 项金额已计入 / \(currency.pendingCount) 项待办")
                                .font(.caption).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help("查看 \(currency.code) 的全部待办项目；未填写和待核对金额不计入合计")
                }
            }
            Divider()
            if !summary.legacyCurrencyIDs.isEmpty {
                Text("\(summary.legacyCurrencyIDs.count) 项未标币种，按人民币统计。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { select(.pending) } label: {
                HStack {
                    Text("查看待办明细")
                    Spacer()
                    Text("\(summary.pendingCount) 项").monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption)
                }.font(.callout)
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(summary.pendingCount == 0)
        }
        .padding(14).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("金额待补与核对", systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            if !summary.missingAmountIDs.isEmpty {
                issue("金额未填写", count: summary.missingAmountIDs.count, focus: .missing)
            }
            if !summary.invalidAmountIDs.isEmpty {
                issue("金额格式异常", count: summary.invalidAmountIDs.count, focus: .invalid)
            }
            if !summary.overlappingAmountIDs.isEmpty {
                issue("父子金额可能重复", count: summary.overlappingAmountIDs.count, focus: .overlap)
            }
            if !summary.duplicateTaskIDs.isEmpty {
                issue("重复任务编号", count: summary.duplicateTaskIDs.count, focus: .duplicates)
            }
            Text("以上未计入合计；空金额不是 0。点击可查看原项目。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func issue(_ title: String, count: Int, focus target: LedgerSummaryFocus) -> some View {
        Button { select(target) } label: {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                Text("\(count) 项").monospacedDigit()
                Image(systemName: "chevron.right").font(.caption)
            }.font(.callout).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func currencySections(_ currency: StudioLedgerSummary.CurrencySummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if summary.currencies.count > 1 { Text("\(currency.code) 金额分布").font(.headline) }
            VStack(alignment: .leading, spacing: 8) {
                Text("按开票状态 · 项目金额").font(.subheadline.weight(.semibold))
                ForEach(currency.invoiceBuckets, id: \.label) { bucket in
                    bucketRow(bucket, currency: currency.code, target: .invoice(currency.code, bucket.label))
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("按收款状态 · 项目金额").font(.subheadline.weight(.semibold))
                ForEach(currency.paymentBuckets, id: \.label) { bucket in
                    bucketRow(bucket, currency: currency.code, target: .payment(currency.code, bucket.label))
                }
                Text("按项目全额分组，不等于实际待收余额；部分收款不自动推算余款。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("按客户查看") {
                VStack(spacing: 8) {
                    ForEach(currency.clientBuckets, id: \.label) { bucket in
                        bucketRow(bucket, currency: currency.code, target: .client(currency.code, bucket.label))
                    }
                }.padding(.top, 8)
            }.font(.subheadline.weight(.semibold))
        }
    }

    private func bucketRow(_ bucket: StudioLedgerSummary.Bucket, currency: String, target: LedgerSummaryFocus) -> some View {
        Button { select(target) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bucket.label).font(.callout).lineLimit(2)
                    Spacer(minLength: 2)
                    Text(bucket.countedAmountCount == 0 ? "待补 / 核对" : LedgerMoneyFormat.text(bucket.total, currency: currency))
                        .font(.callout.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        .layoutPriority(1)
                }
                Text("\(bucket.pendingCount) 项 · \(bucket.countedAmountCount) 项金额计入")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(focus == target ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("查看\(bucket.label)项目，包含金额未填写的项目")
    }

    private var methodology: some View {
        DisclosureGroup("统计口径") {
            VStack(alignment: .leading, spacing: 8) {
                Text("仅统计工作室台账中的开放任务；完成、放弃、暂停、归档不计入。只知情与报价按现有类型保留，可用类型筛选区分。")
                Text("合计取已填写的含税项目金额，不解析标题或备注猜金额，也不代表收入、利润或实际未收款。开票、收款、客户是同一批项目的不同分组，不能再次相加。")
                Text("部分开票保留独立分组，不把项目总额当作已开票额或未开票额。金额为 0 会明确计入，未填写和异常金额另列。")
                Text("父子待办同时填写金额时，相关项目暂不计入合计并提示核对；筛选隐藏其中一项也不会重复计入。不自动修改任何项目。")
                if !summary.legacyCurrencyIDs.isEmpty {
                    Text("\(summary.legacyCurrencyIDs.count) 项未标币种，沿用人民币 CNY 口径。可在详情里补充币种；其他币种独立合计，不做汇率换算。")
                } else {
                    Text("不同币种分别合计，不做汇率换算。")
                }
                Text("统计随本机数据与同步结果更新；展开状态和统计范围只保存在本机，按工作区隔离。")
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }.font(.subheadline)
    }

    private func select(_ target: LedgerSummaryFocus) {
        focus = focus == target ? nil : target
    }
}
