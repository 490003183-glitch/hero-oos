import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum CollageMerge {
    static func merge(base: JSON, local: JSON, remote: JSON) throws -> JSON {
        if local == base { return remote }
        if remote == base || local == remote { return local }
        switch (base, local, remote) {
        case let (.object(b), .object(l), .object(r)):
            var output: [String: JSON] = [:]
            for key in Set(b.keys).union(l.keys).union(r.keys) {
                if key == "activeCanvasId", b["canvases"] != nil { output[key] = l[key] ?? r[key]; continue }
                let value = try merge(base: b[key] ?? .null, local: l[key] ?? .null, remote: r[key] ?? .null)
                if value != .null { output[key] = value }
            }
            return .object(output)
        case let (.array(b), .array(l), .array(r)):
            guard (b + l + r).allSatisfy({ !$0["id"].string.isEmpty }) else { throw NativeError.message("拼图在另一端发生冲突，当前编辑仍保留。") }
            let bm = Dictionary(uniqueKeysWithValues: b.map { ($0["id"].string, $0) })
            let lm = Dictionary(uniqueKeysWithValues: l.map { ($0["id"].string, $0) })
            let rm = Dictionary(uniqueKeysWithValues: r.map { ($0["id"].string, $0) })
            var output: [JSON] = []; var seen = Set<String>()
            for item in r + l + b {
                let id = item["id"].string
                guard seen.insert(id).inserted else { continue }
                let value = try merge(base: bm[id] ?? .null, local: lm[id] ?? .null, remote: rm[id] ?? .null)
                if value != .null { output.append(value) }
            }
            return .array(output)
        default: throw NativeError.message("拼图中的同一内容已在另一端修改。当前编辑已保留，请核对冲突。")
        }
    }
}

@MainActor final class CollageStore: ObservableObject {
    @Published var document: JSON = .object([:]) {
        willSet {
            if document["activeCanvasId"] != newValue["activeCanvasId"] { surface?.persistViewport() }
        }
        didSet {
            if oldValue["activeCanvasId"] != document["activeCanvasId"] {
                if let surface { surface.restoreViewportIfNeeded() } else { selection = [] }
            }
        }
    }
    @Published var selection = Set<String>() {
        didSet {
            endCropAdjustment(); endSizeAdjustment()
            if oldValue != selection { surface?.scheduleViewportSave() }
        }
    }
    @Published var dirty = false
    @Published var saving = false
    @Published var importing = false
    @Published var hasConflict = false
    @Published var message = "正在加载"
    @Published var error: String?
    @Published var importError: String?
    @Published var zoom: Double = 1
    @Published var history: [JSON] = []
    @Published var future: [JSON] = []
    weak var surface: CollageSurface?
    let api: OOSAPI
    private var baseline: JSON = .object([:])
    private var timer: Task<Void, Never>?
    private var adjustingCrop = false
    private var cropCheckpointed = false
    private var adjustingSize = false
    private var sizeCheckpointed = false
    private let draftsEnabled: Bool
    private var draftKey: String { "HeroOOS.collageDraft.\(api.draftIdentity)" }
    var canvases: [Record] { document["canvases"].records }
    var activeID: String { document["activeCanvasId"].string }
    var canvas: Record? { canvases.first { $0.id == activeID } }
    var items: [Record] { canvas?["items"].records.sorted { $0.number("z") < $1.number("z") } ?? [] }
    var selectedItems: [Record] { items.filter { selection.contains($0.id) } }
    init(api: OOSAPI = OOSAPI(), recoverDrafts: Bool = true) {
        self.api = api; self.draftsEnabled = recoverDrafts
        if recoverDrafts, let data = UserDefaults.standard.data(forKey: draftKey), let saved = try? JSONDecoder().decode(JSON.self, from: data) {
            document = saved["document"]; baseline = saved["baseline"]; dirty = true; message = "已恢复未保存编辑"
        }
    }
    deinit { timer?.cancel() }
    func load() async {
        if dirty { _ = await save(); return }
        guard !dirty && !saving else { return }
        let before = document
        do {
            let response = try await api.request("/api/collages")
            guard !dirty && !saving && document == before else { return }
            if document != response["collages"] { history = []; future = [] }
            document = response["collages"]; baseline = document; message = "已同步"; error = nil
            surface?.retryMissingImages(); surface?.restoreViewportIfNeeded()
        } catch { self.error = error.localizedDescription; message = "加载失败" }
    }
    func checkpoint() {
        history.append(document); if history.count > 50 { history.removeFirst() }; future = []
    }
    func mutate(recordHistory: Bool = true, _ body: (inout JSON) -> Void) {
        if recordHistory { checkpoint() }
        body(&document); changed()
    }
    func mutateCanvas(id: String? = nil, recordHistory: Bool = true, _ body: (inout JSON) -> Void) {
        mutate(recordHistory: recordHistory) { doc in
            var list = doc["canvases"].array
            guard let i = list.firstIndex(where: { $0["id"].string == (id ?? doc["activeCanvasId"].string) }) else { return }
            body(&list[i]); doc["canvases"] = .array(list)
        }
    }
    func updateItems(_ updates: [String: Record], history: Bool = false) {
        mutateCanvas(recordHistory: history) { canvas in
            canvas["items"] = .array(canvas["items"].array.map { updates[$0["id"].string]?.json ?? $0 })
        }
    }
    @discardableResult func updateSelected(_ key: String, _ value: JSON, recordHistory: Bool = true) -> Bool {
        if ["width", "height"].contains(key), !value.number.isFinite { return false }
        let changes = Dictionary(uniqueKeysWithValues: selectedItems.filter { !$0["locked"].bool || key == "locked" }.compactMap { item -> (String, Record)? in
            var r = item; var v = value
            if ["width", "height"].contains(key) { v = .number(min(20000, max(40, value.number))) }
            if ["x", "y"].contains(key) { v = .number(min(200000, max(0, value.number))) }
            if key == "fontSize" { v = .number(min(500, max(8, value.number))) }
            if item.text("kind") == "image", ["width", "height"].contains(key) {
                let ratio = v.number / max(1, item.number(key))
                let dimension = key == "width" ? "imageWidth" : "imageHeight"
                let offset = key == "width" ? "imageOffsetX" : "imageOffsetY"
                r[dimension] = .number(item.number(dimension, item.number(key)) * ratio)
                r[offset] = .number(item.number(offset) * ratio)
            }
            r[key] = v; return r == item ? nil : (r.id, r)
        })
        guard !changes.isEmpty else { return false }
        updateItems(changes, history: recordHistory)
        return true
    }
    func beginSizeAdjustment() { adjustingSize = true; sizeCheckpointed = false }
    func endSizeAdjustment() { adjustingSize = false; sizeCheckpointed = false }
    func resizeSelected(_ key: String, value: Double) {
        guard ["width", "height"].contains(key), value.isFinite else { return }
        if updateSelected(key, .number(value), recordHistory: !adjustingSize || !sizeCheckpointed), adjustingSize { sizeCheckpointed = true }
    }
    func beginCropAdjustment() { adjustingCrop = true; cropCheckpointed = false }
    func endCropAdjustment() { adjustingCrop = false; cropCheckpointed = false }
    func cropSelected(_ edge: CropEdge, fraction: Double) {
        let changes = Dictionary(uniqueKeysWithValues: selectedItems.compactMap { item -> (String, Record)? in
            let result = ImageCrop.applying(edge, fraction: fraction, to: item)
            return result == item ? nil : (item.id, result)
        })
        guard !changes.isEmpty else { return }
        if !adjustingCrop || !cropCheckpointed { checkpoint(); cropCheckpointed = true }
        updateItems(changes)
    }
    func changed() {
        dirty = true; message = "尚未保存"; timer?.cancel()
        persistDraft()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700)); guard !Task.isCancelled else { return }
            self?.timer = nil; _ = await self?.save()
        }
    }
    private func persistDraft() {
        guard draftsEnabled else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(JSON.object(["document": document, "baseline": baseline])), forKey: draftKey)
    }
    @discardableResult func save() async -> Bool {
        surface?.persistViewport()
        timer?.cancel(); timer = nil
        while saving { do { try await Task.sleep(for: .milliseconds(50)) } catch { return false } }
        guard dirty else { return true }
        saving = true; defer { saving = false }
        do {
            while dirty {
                let snapshot = document
                let remote = try await api.request("/api/collages")["collages"]
                let merged: JSON
                do { merged = try CollageMerge.merge(base: baseline, local: snapshot, remote: remote) }
                catch { hasConflict = true; throw error }
                let response = try await api.request("/api/collages", method: "PUT", body: .object(["collages": merged, "expectedCollages": remote]))
                let saved = response["collages"]
                document = try CollageMerge.merge(base: snapshot, local: document, remote: saved)
                history = history.compactMap { try? CollageMerge.merge(base: snapshot, local: $0, remote: saved) }
                future = future.compactMap { try? CollageMerge.merge(base: snapshot, local: $0, remote: saved) }
                baseline = saved; dirty = document != saved
                persistDraft()
            }
            if draftsEnabled { UserDefaults.standard.removeObject(forKey: draftKey) }
            error = nil; hasConflict = false; message = "已保存"; return true
        } catch { self.error = error.localizedDescription; message = "未保存"; return false }
    }
    func keepLocalCopies() async {
        guard !saving else { return }
        do {
            let remote = try await api.request("/api/collages")["collages"]
            let original = baseline["canvases"].records
            var copies: [JSON] = []
            for var canvas in canvases where original.first(where: { $0.id == canvas.id }) != canvas {
                canvas["id"] = .string("collage-\(UUID().uuidString)")
                canvas["name"] = .string(canvas.text("name") + " · 本地副本")
                canvas["items"] = .array(canvas["items"].array.map { item in var copy = item; copy["id"] = .string("collage-item-\(UUID().uuidString)"); return copy })
                copies.append(canvas.json)
            }
            guard !copies.isEmpty else { error = "本地只有删除操作，没有可另存的画布。未同步编辑仍保留。"; return }
            document = remote; baseline = remote
            document["canvases"] = .array(remote["canvases"].array + copies)
            document["activeCanvasId"] = copies[0]["id"]
            history = []; future = []; changed(); _ = await save()
        } catch { self.error = error.localizedDescription }
    }
    func switchCanvas(_ id: String) {
        guard activeID != id, canvases.contains(where: { $0.id == id }) else { return }
        mutate(recordHistory: false) { $0["activeCanvasId"] = .string(id) }
    }
    func addCanvas() {
        let id = "collage-\(UUID().uuidString)"
        let name = "拼图 \(canvases.count + 1)"
        mutate { doc in
            doc["canvases"] = .array(doc["canvases"].array + [.object(["id": .string(id), "name": .string(name), "background": .string("#ffffff"), "items": .array([])])])
            doc["activeCanvasId"] = .string(id)
        }
    }
    func removeCanvas() {
        guard canvases.count > 1 else { return }
        let alert = NSAlert(); alert.messageText = "删除画布「\(canvas?.text("name") ?? "")」？"
        alert.informativeText = "可以通过撤销恢复，原图文件会保留。"; alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removedID = activeID
        mutate { doc in let remaining = doc["canvases"].array.filter { $0["id"].string != removedID }; doc["canvases"] = .array(remaining); doc["activeCanvasId"] = remaining.first?["id"] ?? .null }
    }
    func addText() {
        let alert = NSAlert()
        alert.messageText = "添加文字"
        alert.informativeText = "创建后可在右侧调整字体、字号和颜色。"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: scroll.bounds)
        editor.string = "输入文字"
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 16)
        scroll.documentView = editor
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = editor
        editor.selectAll(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        insertText(editor.string.isEmpty ? "输入文字" : editor.string)
    }
    func insertText(_ text: String) {
        let p = surface?.visibleCenter ?? CGPoint(x: 100, y: 100)
        let viewScale = max(0.015, surface?.displayScale ?? 1)
        let width = min(20_000, max(720, 420 / viewScale))
        let height = min(20_000, max(200, 150 / viewScale))
        let fontSize = min(500, max(72, 36 / viewScale))
        let background = NSColor(hex: canvas?.text("background") ?? "#ffffff").usingColorSpace(.sRGB)!
        let luminance = background.redComponent * 0.2126 + background.greenComponent * 0.7152 + background.blueComponent * 0.0722
        let item = Record(["id": .string("collage-item-\(UUID().uuidString)"), "kind": .string("text"), "text": .string(String(text.prefix(5000))), "fontFamily": .string("PingFang SC"), "fontSize": .number(fontSize), "color": .string(luminance < 0.5 ? "#ffffff" : "#222222"), "x": .number(max(0, p.x - width / 2)), "y": .number(max(0, p.y - height / 2)), "width": .number(width), "height": .number(height), "rotation": .number(0), "z": .number((items.map { $0.number("z") }.max() ?? 0) + 1), "locked": .bool(false)])
        mutateCanvas { $0["items"] = .array($0["items"].array + [item.json]) }; selection = [item.id]
        surface?.needsDisplay = true
    }
    func addImages(_ urls: [URL], point: CGPoint? = nil) async {
        guard !importing, let target = canvas, !urls.isEmpty else { return }
        importError = nil
        importing = true; defer { importing = false }
        var added: [Record] = []; var failures: [String] = []
            let center = point ?? surface?.visibleCenter ?? CGPoint(x: 100, y: 100)
            for (index, url) in urls.enumerated() {
                do {
                let data = try Data(contentsOf: url)
                guard let image = NSImage(data: data), let rep = image.representations.first else { throw NativeError.message("无法读取图片：\(url.lastPathComponent)") }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
                guard ["image/jpeg", "image/png", "image/webp", "image/gif"].contains(mime) else { throw NativeError.message("请选择 JPG、PNG、WebP 或 GIF。") }
                var components = URLComponents(); components.path = "/api/collage-assets"
                components.queryItems = [URLQueryItem(name: "filename", value: url.lastPathComponent)]
                let response = try await api.request(components.string!, method: "POST", raw: data, contentType: mime)
                var item = Record(response["asset"].object)
                item["id"] = .string("collage-item-\(UUID().uuidString)")
                item["kind"] = .string("image"); item["x"] = .number(max(0, center.x + Double(index) * 40)); item["y"] = .number(max(0, center.y + Double(index) * 40))
                for key in ["width", "naturalWidth", "imageWidth"] { item[key] = .number(Double(rep.pixelsWide)) }
                for key in ["height", "naturalHeight", "imageHeight"] { item[key] = .number(Double(rep.pixelsHigh)) }
                for key in ["rotation", "imageOffsetX", "imageOffsetY", "cropX", "cropY"] { item[key] = .number(0) }
                item["cropZoom"] = .number(1); item["locked"] = .bool(false)
                item["z"] = .number((target["items"].records.map { $0.number("z") }.max() ?? 0) + Double(index) + 1)
                added.append(item)
                } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
        guard canvases.contains(where: { $0.id == target.id }) else { importError = "原画布已移除，导入图片未加入其他画布。"; return }
        if !added.isEmpty {
            mutateCanvas(id: target.id) { $0["items"] = .array($0["items"].array + added.map(\.json)) }
            if activeID == target.id { selection = Set(added.map(\.id)); surface?.fit() }
        }
        if !failures.isEmpty { importError = failures.joined(separator: "\n") }
    }
    func importImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png, .webP, .gif]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { Task { await addImages(panel.urls) } }
    }
    func deleteSelection() {
        let ids = Set(selectedItems.filter { !$0["locked"].bool }.map(\.id))
        guard !ids.isEmpty else { return }
        mutateCanvas { $0["items"] = .array($0["items"].array.filter { !ids.contains($0["id"].string) }) }; selection.subtract(ids)
    }
    func duplicate() {
        var additions: [JSON] = []; var ids = Set<String>()
        let top = items.map { $0.number("z") }.max() ?? 0
        for (index, selected) in selectedItems.enumerated() {
            var item = selected; let id = "collage-item-\(UUID().uuidString)"; ids.insert(id)
            item["id"] = .string(id); item["x"] = .number(item.number("x") + 40); item["y"] = .number(item.number("y") + 40)
            item["z"] = .number(top + Double(index) + 1); item["locked"] = .bool(false); additions.append(item.json)
        }
        guard !additions.isEmpty else { return }
        mutateCanvas { $0["items"] = .array($0["items"].array + additions) }; selection = ids
    }
    func undo() {
        guard let old = history.popLast() else { return }
        let previousID = activeID
        future.append(document); document = old
        if activeID == previousID { selection = [] }
        changed()
    }
    func redo() {
        guard let next = future.popLast() else { return }
        let previousID = activeID
        history.append(document); document = next
        if activeID == previousID { selection = [] }
        changed()
    }
    func resetImage() {
        let changes = Dictionary(uniqueKeysWithValues: selectedItems.filter { $0.text("kind") == "image" && !$0["locked"].bool }.map { item in
            var r = item
            for key in ["width", "imageWidth"] { r[key] = r["naturalWidth"] }
            for key in ["height", "imageHeight"] { r[key] = r["naturalHeight"] }
            r["imageOffsetX"] = .number(0); r["imageOffsetY"] = .number(0); r["rotation"] = .number(0)
            return (r.id, r)
        })
        updateItems(changes, history: true)
    }
}

struct CollageWorkspace: View {
    @EnvironmentObject var model: CollageStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("画布", selection: Binding(get: { model.activeID }, set: { model.switchCanvas($0) })) {
                    ForEach(model.canvases) { Text($0.text("name")).tag($0.id) }
                }.labelsHidden().frame(width: 160)
                tool("plus", "新建画布", model.addCanvas)
                Divider().frame(height: 20)
                tool("photo.badge.plus", "添加图片", model.importImages).disabled(model.importing)
                if model.importing { ProgressView().controlSize(.small) }
                Button(action: model.addText) {
                    Label("添加文字", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .help("在当前视野中心创建文字框（⌘T）")
                .keyboardShortcut("t", modifiers: .command)
                .accessibilityLabel("添加文字")
                tool("arrow.uturn.backward", "撤销", model.undo).disabled(model.history.isEmpty)
                tool("arrow.uturn.forward", "重做", model.redo).disabled(model.future.isEmpty)
                Spacer(minLength: 4)
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                tool("arrow.down.to.line", "导出 JPG") { Task { await model.surface?.exportJPG() } }.disabled(model.items.isEmpty)
            }.padding(12)
            Divider()
            if let error = model.importError {
                HStack { Text(error).font(.callout).foregroundStyle(.orange); Spacer(); Button { model.importError = nil } label: { Image(systemName: "xmark") }.help("关闭导入提示") }.padding(10)
            }
            if let error = model.error {
                HStack { Text(error).font(.callout).foregroundStyle(.orange); Spacer()
                    if model.hasConflict { Button("另存本地画布") { Task { await model.keepLocalCopies() } }.help("保留另一端画布，将本地修改保存为独立副本") }
                    Button("重试保存") { Task { await model.save() } }
                }.padding(10)
            }
            HSplitView {
                ZStack(alignment: .bottomLeading) {
                    CollageView(model: model)
                    HStack(spacing: 12) {
                        tool("minus.magnifyingglass", "缩小") { model.surface?.zoomBy(0.8) }
                        Text("\(Int(model.zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 45)
                        tool("plus.magnifyingglass", "放大") { model.surface?.zoomBy(1.25) }
                        tool("arrow.up.left.and.arrow.down.right", "定位全部内容") { model.surface?.fit() }
                        Button("1:1") { model.surface?.zoomTo(1) }.buttonStyle(.borderless).help("原始像素比例")
                    }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(12)
                }.frame(minWidth: 300)
                CollageInspector().frame(minWidth: 210, idealWidth: 235, maxWidth: 290)
            }
        }
    }
    func tool(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 20, height: 20) }.buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}

struct CollageInspector: View {
    @EnvironmentObject var model: CollageStore
    var selected: Record? { model.selectedItems.first }
    func number(_ key: String, _ fallback: Double = 0) -> Binding<Double> {
        Binding(get: { selected?.number(key, fallback) ?? fallback }, set: { model.updateSelected(key, .number($0)) })
    }
    var body: some View {
        Form {
            if let item = selected {
                Section(model.selection.count > 1 ? "已选 \(model.selection.count) 项" : "所选内容") {
                    if item.text("kind") == "text" {
                        TextField("文字", text: Binding(get: { item.text("text") }, set: { model.updateSelected("text", .string($0)) }), axis: .vertical).lineLimit(3...12)
                        Picker("字体", selection: Binding(get: { item.text("fontFamily") }, set: { model.updateSelected("fontFamily", .string($0)) })) {
                            ForEach(["PingFang SC", "Songti SC", "Kaiti SC", "Heiti SC", "Arial", "Helvetica", "Georgia", "Times New Roman"], id: \.self) { Text($0).tag($0) }
                        }
                        TextField("字号", value: number("fontSize", 72), format: .number)
                        ColorPicker("文字颜色", selection: Binding(get: { Color(nsColor: NSColor(hex: item.text("color"))) }, set: { model.updateSelected("color", .string(NSColor($0).hex)) }), supportsOpacity: false)
                    } else { Text(item.text("originalName")).font(.caption).textSelection(.enabled).lineLimit(4) }
                    HStack { TextField("X", value: number("x"), format: .number.precision(.fractionLength(0))); TextField("Y", value: number("y"), format: .number.precision(.fractionLength(0))) }
                    if item.text("kind") != "image" {
                        HStack { TextField("宽", value: number("width"), format: .number.precision(.fractionLength(0))); TextField("高", value: number("height"), format: .number.precision(.fractionLength(0))) }
                    }
                    TextField("旋转角度", value: number("rotation"), format: .number.precision(.fractionLength(1)))
                    Toggle("锁定", isOn: Binding(get: { item["locked"].bool }, set: { model.updateSelected("locked", .bool($0)) }))
                }
                Section {
                    HStack {
                        icon("doc.on.doc", "复制", model.duplicate)
                        icon("rotate.right", "旋转 90 度") { model.updateSelected("rotation", .number(item.number("rotation") + 90)) }
                        icon("square.3.layers.3d.top.filled", "置顶") { model.updateSelected("z", .number((model.items.map { $0.number("z") }.max() ?? 0) + 1)) }
                        icon("square.3.layers.3d.bottom.filled", "置底") {
                            model.updateSelected("z", .number((model.items.map { $0.number("z") }.min() ?? 0) - 1))
                        }
                        icon("trash", "移除", model.deleteSelection)
                    }
                    if item.text("kind") == "image" {
                        Button("恢复原图尺寸", action: model.resetImage)
                    }
                }
                if item.text("kind") == "image" {
                    Section("非等比缩放") {
                        ImageDimensionControl(key: "width", title: "宽", value: number("width"))
                        ImageDimensionControl(key: "height", title: "高", value: number("height"))
                    }.disabled(item["locked"].bool)
                }
            }
            Section("画布") {
                TextField("名称", text: Binding(get: { model.canvas?.text("name") ?? "" }, set: { value in model.mutateCanvas { $0["name"] = .string(value) } }))
                ColorPicker("背景", selection: Binding(get: { Color(nsColor: NSColor(hex: model.canvas?.text("background") ?? "#ffffff")) }, set: { color in model.mutateCanvas { $0["background"] = .string(NSColor(color).hex) } }), supportsOpacity: false)
                Text("\(model.items.count) 项内容").font(.caption).foregroundStyle(.secondary)
                Button("删除画布", role: .destructive, action: model.removeCanvas).disabled(model.canvases.count < 2)
            }
        }.formStyle(.grouped)
    }
    func icon(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}
