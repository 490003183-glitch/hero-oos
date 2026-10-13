import SwiftUI

/// Full explanation and condition management remain in the task inspector.
struct TaskConditionsFields: View {
    @EnvironmentObject var store: OOSStore
    let id: String
    var revealSatisfied: (() -> Void)?
    @State private var showCompletedTasks = false
    private func text(_ key: String) -> Binding<String> {
        Binding(get: { store.task(id)?.text(key) ?? "" }, set: { store.edit(id, key, .string($0)) })
    }
    var body: some View {
        if let task = store.task(id) {
            let dependencies = TaskDependencies(store.tasks)
            Section("阻断条件 · 全部满足才可开始") {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let pending = dependencies.pendingConditions(task, at: context.date)
                    let configured = !dependencies.conditions(task, at: context.date).isEmpty
                    Text(pending.isEmpty ? "\(configured ? "条件已齐" : "未设置阻断条件")\(dependencies.readyToBegin(task, at: context.date) ? " · 可开始" : "")" : "还差 \(pending.count) 项 · \(dependencies.conditionCounts(task, at: context.date))")
                        .font(.headline).foregroundStyle(pending.isEmpty ? (configured ? Color.green : Color.secondary) : Color.orange)
                }
                Text("条件解除不改变任务状态；进行中的任务也能再次被阻断。")
                    .font(.caption).foregroundStyle(.secondary)
                if !task.text("waitingCondition").isEmpty {
                    Text("原等待说明：\(task.text("waitingCondition"))\n这是文字记录，可在下方设置具体阻断条件。")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("等人 · 当前卡谁") { PeopleWaitsEditor(id: id) }
            Section("等时间") {
                DateTimeField(title: "可开始时间", value: text("availableAt"))
                if let date = TaskDependencies.availableDate(task) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(date <= context.date ? "✓ 时间已到，这一项已满足" : "◷ 尚未到时")
                            .font(.caption).foregroundStyle(date <= context.date ? .green : .orange)
                    }
                }
                Text("到点自动满足这一项；仍在等人或前置任务时不会提示可开始。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("等任务") {
                let ids = task["dependsOn"].array.map(\.string)
                let unfinished = ids.filter { store.task($0)?.status != "completed" }
                let finished = ids.filter { store.task($0)?.status == "completed" }
                if ids.isEmpty { Text("未设置任务阻断").foregroundStyle(.secondary).font(.caption) }
                ForEach(unfinished, id: \.self) { upstream in dependencyRow(upstream, owner: task, satisfied: false) }
                if !finished.isEmpty {
                    Button("\(showCompletedTasks ? "▾" : "▸") 已满足 \(finished.count) 项前置") { showCompletedTasks.toggle() }.buttonStyle(.borderless)
                    if showCompletedTasks {
                        ForEach(finished, id: \.self) { upstream in dependencyRow(upstream, owner: task, satisfied: true) }
                        if let revealSatisfied { Button("展开 / 收起画布中的已完成前置", action: revealSatisfied) }
                    }
                }
                Menu("添加前置任务") {
                    ForEach(Relations.choices(for: task, tasks: store.tasks).dependencies) { upstream in
                        Button(upstream.title) { store.edit(id, "dependsOn", .array(task["dependsOn"].array + [.string(upstream.id)])) }
                    }
                }
                Text("也可在画布上连线。已放弃、归档不等于完成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func dependencyRow(_ upstream: String, owner: Record, satisfied: Bool) -> some View {
        HStack {
            Image(systemName: satisfied ? "checkmark.circle.fill" : "circle").foregroundStyle(satisfied ? .green : .orange)
            Text(store.task(upstream)?.title ?? "前置任务缺失").lineLimit(2)
            Spacer(minLength: 4)
            Button {
                store.edit(id, "dependsOn", .array(owner["dependsOn"].array.filter { $0.string != upstream }))
            } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("解除这项依赖，不删除任务")
        }
    }
}

struct PeopleWaitsEditor: View {
    @EnvironmentObject var store: OOSStore
    let id: String
    @State private var editing: Record?
    @State private var person = ""
    @State private var outcome = ""
    @State private var showResolved = false
    init(id: String, initialEntry: Record? = nil) {
        self.id = id
        _editing = State(initialValue: initialEntry)
        _person = State(initialValue: initialEntry?.text("person") ?? "")
        _outcome = State(initialValue: initialEntry?.text("outcome") ?? "")
    }
    private var entries: [Record] { store.task(id).map(TaskPeopleWaits.entries) ?? [] }
    private func save(_ values: [Record]) { store.edit(id, "peopleWaits", .array(values.map(\.json))) }
    private func begin(_ entry: Record) { editing = entry; person = entry.text("person"); outcome = entry.text("outcome") }
    private var canSave: Bool { !person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func cancelEditing() { editing = nil }
    private func saveEditing() {
        guard let editing, canSave else { return }
        var entry = entries.first { $0.id == editing.id } ?? editing
        entry["person"] = .string(person.trimmingCharacters(in: .whitespacesAndNewlines))
        entry["outcome"] = .string(outcome.trimmingCharacters(in: .whitespacesAndNewlines))
        var next = entries
        if let index = next.firstIndex(where: { $0.id == entry.id }) { next[index] = entry } else { next.append(entry) }
        save(next); cancelEditing()
    }
    var body: some View {
        let pending = entries.filter { !$0["resolved"].bool }
        let resolved = entries.filter { $0["resolved"].bool }
        ForEach(pending) { row($0) }
        if entries.isEmpty { Text("未设置等人条件").font(.caption).foregroundStyle(.secondary) }
        if !resolved.isEmpty {
            Button("\(showResolved ? "▾" : "▸") 已解决 \(resolved.count) 项") { showResolved.toggle() }.buttonStyle(.borderless)
            if showResolved { ForEach(resolved) { row($0) } }
        }
        if editing != nil {
            VStack(alignment: .leading, spacing: 8) {
                TextField("等谁", text: $person).textFieldStyle(.roundedBorder)
                TextField("等什么结果（可选）", text: $outcome, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                HStack {
                    Button("取消", action: cancelEditing).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保存条件", action: saveEditing).keyboardShortcut(.defaultAction).disabled(!canSave)
                }
            }.onSubmit(saveEditing).onExitCommand(perform: cancelEditing)
        } else {
            Button("＋ 添加等人条件") { begin(Record(["id": .string(UUID().uuidString), "person": "", "outcome": "", "resolved": false])) }
        }
    }
    private func row(_ entry: Record) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(get: { entry["resolved"].bool }, set: { value in
                save(entries.map { current in
                    guard current.id == entry.id else { return current }
                    var next = current; next["resolved"] = .bool(value); return next
                })
            })) { Text(TaskPeopleWaits.label(entry)).textSelection(.enabled) }
                .toggleStyle(.checkbox).help(entry["resolved"].bool ? "取消勾选，重新设为未解决" : "确认已收到 / 已解决")
            Spacer(minLength: 0)
            Button { begin(entry) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("修改等谁及等待结果")
            Button { save(entries.filter { $0.id != entry.id }); if editing?.id == entry.id { editing = nil } }
                label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除这项条件，不删除任务")
        }
    }
}

struct TaskConditionsPanel: View {
    @ObservedObject var store: OOSStore
    let id: String
    @State var kind: TaskConditionKind
    var resize: (CGSize) -> Void
    var close: () -> Void
    static func size(for kind: TaskConditionKind, task: Record?) -> CGSize {
        let height: Double
        switch kind {
        case .person: height = min(300, 240 + Double(max(0, (task.map(TaskPeopleWaits.entries)?.count ?? 0) - 1)) * 24)
        case .time: height = 152
        case .task: height = min(300, 132 + Double(task?["dependsOn"].array.count ?? 0) * 32)
        }
        return CGSize(width: 330, height: height)
    }
    private var size: CGSize { Self.size(for: kind, task: store.task(id)) }
    private func firstEntry(_ task: Record) -> Record? {
        let entries = TaskPeopleWaits.entries(task)
        if entries.count == 1 { return entries[0] }
        if entries.isEmpty { return Record(["id": .string(UUID().uuidString), "person": "", "outcome": "", "resolved": false]) }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("阻断条件").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭阻断条件")
            }
            Picker("条件类型", selection: $kind) {
                Text("等人").tag(TaskConditionKind.person)
                Text("等时间").tag(TaskConditionKind.time)
                Text("等任务").tag(TaskConditionKind.task)
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let task = store.task(id) {
                        switch kind {
                        case .person:
                            PeopleWaitsEditor(id: id, initialEntry: firstEntry(task))
                        case .time:
                            DateTimeField(title: "可开始时间", value: Binding(get: { store.task(id)?.text("availableAt") ?? "" }, set: { store.edit(id, "availableAt", .string($0)) }))
                        case .task:
                            ForEach(task["dependsOn"].array.map(\.string), id: \.self) { upstream in
                                HStack(spacing: 8) {
                                    let satisfied = store.task(upstream)?.status == "completed"
                                    Image(systemName: satisfied ? "checkmark.circle.fill" : "circle").foregroundStyle(satisfied ? .green : .orange)
                                    Text(store.task(upstream)?.title ?? "前置任务缺失").lineLimit(2)
                                    Spacer(minLength: 0)
                                    Button {
                                        store.edit(id, "dependsOn", .array(task["dependsOn"].array.filter { $0.string != upstream }))
                                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除这项阻断")
                                }
                            }
                            Menu("＋ 添加前置任务") {
                                ForEach(Relations.choices(for: task, tasks: store.tasks).dependencies) { upstream in
                                    Button(upstream.title) { store.edit(id, "dependsOn", .array(task["dependsOn"].array + [.string(upstream.id)])) }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }.padding(12).frame(width: size.width, height: size.height).environmentObject(store)
            .onChange(of: size) { _, newSize in resize(newSize) }
    }
}
