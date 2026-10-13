import SwiftUI

extension OOSStore {
    func createTaskPage(title: String) async -> String? {
        let id = "page-\(UUID().uuidString)"
        return await perform([["type": "taskPage.create", "taskPage": ["id": .string(id), "title": .string(title)]]]) ? id : nil
    }
    func renameTaskPage(_ id: String, title: String) async -> Bool {
        await perform([["type": "taskPage.update", "id": .string(id), "changes": ["title": .string(title)]]])
    }
    func deleteEmptyTaskPage(_ id: String) async -> Bool {
        await perform([["type": "taskPage.delete", "id": .string(id)]], confirmed: true)
    }
}

struct TaskPageEditor: View {
    @EnvironmentObject var store: OOSStore
    @Environment(\.dismiss) private var dismiss
    let page: Record
    var onSaved: (String) -> Void
    @State private var title = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(page.id.isEmpty ? "添加任务页" : "重命名任务页").font(.title2.bold())
            TextField("页面名称", text: $title).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "保存中…" : "保存", action: save).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || store.busy)
            }
        }.padding(24).frame(width: 380)
            .onAppear { title = page.title }
            .task { await Task.yield(); focused = true }
    }
    private func save() {
        guard !saving, !store.busy else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        saving = true; failure = nil
        Task {
            defer { saving = false }
            if page.id.isEmpty {
                if let id = await store.createTaskPage(title: name) { onSaved(id); dismiss() }
                else { failure = store.error }
            } else if await store.renameTaskPage(page.id, title: name) { onSaved(page.id); dismiss() }
            else { failure = store.error }
        }
    }
}

struct TaskPageViewPreference: View {
    let space: TaskSpace
    let title: String
    @AppStorage private var mode: TaskViewMode
    init(space: TaskSpace, title: String) {
        self.space = space; self.title = title
        _mode = AppStorage(wrappedValue: .board, TaskViewPreferences.key(for: space))
    }
    var body: some View {
        Picker(title, selection: $mode) {
            ForEach(TaskViewMode.available(for: space)) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
    }
}
