import SwiftUI

struct LedgerView: View {
    @EnvironmentObject var store: OOSStore
    @Binding var selected: String?
    let search: String
    @AppStorage private var kind: String
    @AppStorage private var category: String
    @AppStorage private var delivery: String
    @AppStorage private var invoice: String
    init(selected: Binding<String?>, search: String, workspaceIdentity: String) {
        _selected = selected; self.search = search
        _kind = AppStorage(wrappedValue: "all", WorkspaceViewState.preferenceKey("ledger.kind", identity: workspaceIdentity))
        _category = AppStorage(wrappedValue: "all", WorkspaceViewState.preferenceKey("ledger.category", identity: workspaceIdentity))
        _delivery = AppStorage(wrappedValue: "all", WorkspaceViewState.preferenceKey("ledger.delivery", identity: workspaceIdentity))
        _invoice = AppStorage(wrappedValue: "all", WorkspaceViewState.preferenceKey("ledger.invoice", identity: workspaceIdentity))
    }
    private var records: [Record] { store.tasks.filter(StudioLedger.contains) }
    private func values(_ key: String) -> [String] {
        Array(Set(records.map { $0.text(key) }.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var filtered: [Record] {
        records.filter {
            (kind == "all" || $0.text("recordType") == kind) &&
            (category == "all" || $0.text("subcategory") == category) &&
            (delivery == "all" || $0.text("deliveryStatus") == delivery) &&
            (invoice == "all" || $0.text("invoiceStatus") == invoice) && StudioLedger.matches($0, query: search)
        }.sorted { $0.text("ledgerID").localizedStandardCompare($1.text("ledgerID")) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            filter("类型", key: "recordType", selection: $kind)
                            filter("子分类", key: "subcategory", selection: $category)
                        }.fixedSize()
                        VStack(alignment: .leading) {
                            filter("类型", key: "recordType", selection: $kind)
                            filter("子分类", key: "subcategory", selection: $category)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(filtered.count) / \(records.count) 项").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            filter("交付", key: "deliveryStatus", selection: $delivery)
                            filter("开票", key: "invoiceStatus", selection: $invoice)
                        }.fixedSize()
                        VStack(alignment: .leading) {
                            filter("交付", key: "deliveryStatus", selection: $delivery)
                            filter("开票", key: "invoiceStatus", selection: $invoice)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { kind = "all"; category = "all"; delivery = "all"; invoice = "all" } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }.help("清除台账筛选").disabled(kind == "all" && category == "all" && delivery == "all" && invoice == "all")
                }
            }.padding(16)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView("没有匹配的台账记录", systemImage: "tablecells")
            } else {
                Table(filtered, selection: $selected) {
                    TableColumn("项目") { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title).fontWeight(record.status == "active" ? .bold : .medium).lineLimit(2)
                            Text([record.text("ledgerID"), record.text("subcategory")].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }.width(min: 210, ideal: 270)
                    TableColumn("事务状态") { StatusLabel(status: $0.status) }.width(85)
                    TableColumn("当前待办 / 卡谁") { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.text("nextAction").isEmpty ? "未填写" : record.text("nextAction")).lineLimit(2)
                            if !TaskPeopleWaits.summary(record).isEmpty { Text(TaskPeopleWaits.summary(record)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.width(min: 140, ideal: 185)
                    TableColumn("交付") { Text($0.text("deliveryStatus").isEmpty ? "未填写" : $0.text("deliveryStatus")) }.width(80)
                    TableColumn("开票") { Text($0.text("invoiceStatus").isEmpty ? "未填写" : $0.text("invoiceStatus")) }.width(80)
                    TableColumn("含税金额") { Text(StudioLedger.amountText($0)).monospacedDigit() }.width(90)
                    TableColumn("执行人") { Text($0.text("executor")) }.width(90)
                }
            }
        }
    }
    private func filter(_ label: String, key: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            Text("全部").tag("all")
            Text("未填写").tag("")
            ForEach(values(key), id: \.self) { Text($0).tag($0) }
        }.frame(width: 190)
    }
}

struct LedgerInspectorFields: View {
    @EnvironmentObject var store: OOSStore
    let id: String
    private func text(_ key: String) -> Binding<String> {
        Binding(get: { store.task(id)?.text(key) ?? "" }, set: { store.edit(id, key, .string($0)) })
    }
    var body: some View {
        if let task = store.task(id) {
            Section("分类与渠道") {
                TextField("项目ID", text: text("ledgerID"))
                LedgerChoice(title: "类型", value: text("recordType"), options: StudioLedger.recordTypes)
                TextField("子分类", text: text("subcategory"))
                TextField("客户单位", text: text("client"))
                TextField("对接人", text: text("contact"))
                TextField("执行人", text: text("executor"))
                TextField("源渠道所有", text: text("sourceChannelOwner"))
                TextField("现渠道所有", text: text("currentChannelOwner"))
            }
            Section("执行与交付") {
                DateField(title: "开始执行", value: text("startDate"))
                DateTimeField(title: "必须执行", value: text("mustExecuteAt"))
                TextField("当前待办事项", text: text("nextAction"), axis: .vertical).lineLimit(1...6)
                LedgerChoice(title: "交付状态", value: text("deliveryStatus"), options: StudioLedger.deliveryStatuses)
                LedgerChoice(title: "开票状态", value: text("invoiceStatus"), options: StudioLedger.invoiceStatuses)
                AmountField(value: Binding(get: { store.task(id)?["amountTaxInclusive"] ?? .null }, set: { store.edit(id, "amountTaxInclusive", $0) }))
            }
            if !task["ledgerSource"].object.isEmpty {
                Section("导入来源") {
                    Text(task["ledgerSource"]["filename"].string).font(.caption).textSelection(.enabled)
                    if !task["importWarnings"].array.isEmpty {
                        ForEach(task["importWarnings"].array.map(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    }
                    DisclosureGroup("导入原文") {
                        ForEach(StudioLedger.fields, id: \.key) { field in
                            LabeledContent(field.title) {
                                Text(task["ledgerSource"]["fields"][field.title].string.isEmpty ? "（空）" : task["ledgerSource"]["fields"][field.title].string).textSelection(.enabled)
                            }.font(.caption)
                        }
                    }
                }
            }
        }
    }
}

struct LedgerChoice: View {
    let title: String
    @Binding var value: String
    let options: [String]
    var body: some View {
        Picker(title, selection: $value) {
            Text("未填写").tag("")
            ForEach(Array(Set(options + [value]).subtracting([""])).sorted(), id: \.self) { Text($0).tag($0) }
        }
    }
}

struct DateTimeField: View {
    let title: String
    @Binding var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if value.isEmpty {
                HStack { Text(title); Spacer(); Button("设置") { value = Dates.iso(Date()) }.buttonStyle(.borderless) }
            } else {
                HStack {
                    Text(title); Spacer()
                    Button { value = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("清除\(title)")
                }
                DatePicker(title, selection: Binding(get: { Dates.parse(value) ?? Date() }, set: { value = Dates.iso($0) }), displayedComponents: [.date, .hourAndMinute]).labelsHidden()
            }
        }
    }
}

struct AmountField: View {
    @Binding var value: JSON
    @State private var input = ""
    @FocusState private var focused: Bool
    private var valid: Bool { input.isEmpty || Double(input).map { $0.isFinite && $0 >= 0 } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("金额(含税)", text: $input).focused($focused)
                .onAppear { sync() }
                .onChange(of: value) { _, _ in if !focused { sync() } }
                .onChange(of: input) { _, raw in
                    if raw.isEmpty { value = .null }
                    else if let amount = Double(raw), amount.isFinite && amount >= 0 { value = .number(amount) }
                }
            if !valid { Text("请输入非负金额，此项尚未保存").font(.caption).foregroundStyle(.red) }
        }
    }
    private func sync() { input = value == .null ? "" : String(value.number) }
}
