import SwiftUI
import AppKit
import ImageIO

struct CollageView: NSViewRepresentable {
    @Environment(\.pageBackgroundVisible) private var pageBackgroundVisible
    @ObservedObject var model: CollageStore
    func makeNSView(context: Context) -> CollageSurface {
        let view = CollageSurface(); view.model = model; model.surface = view; return view
    }
    func updateNSView(_ view: CollageSurface, context: Context) {
        view.pageBackgroundVisible = pageBackgroundVisible
        view.restoreViewportIfNeeded()
        view.needsDisplay = true
        if view.needsFit { DispatchQueue.main.async { if view.needsFit { view.fit() } } }
    }
    static func dismantleNSView(_ view: CollageSurface, coordinator: ()) { view.persistViewport() }
}

/// This is a device-local viewing preference, never part of the collage document or cloud payload.
struct CollageViewportState: Codable, Equatable {
    var scale: Double
    var offsetX: Double
    var offsetY: Double
    var selectedIDs: [String]
    var isValid: Bool {
        scale.isFinite && (0.015...8).contains(scale) && offsetX.isFinite && offsetY.isFinite &&
        abs(offsetX) <= 1_000_000_000 && abs(offsetY) <= 1_000_000_000 && selectedIDs.count <= 10_000 &&
        selectedIDs.allSatisfy { !$0.isEmpty && $0.count <= 512 }
    }
    static func key(identity: String, canvasID: String) -> String {
        let encoded = (try? JSONEncoder().encode([identity, canvasID]))?.base64EncodedString() ?? ""
        return "HeroOOS.collageViewport.v1." + encoded
    }
    static func load(identity: String, canvasID: String, defaults: UserDefaults) -> Self? {
        guard !identity.isEmpty, !canvasID.isEmpty,
              let data = defaults.data(forKey: key(identity: identity, canvasID: canvasID)),
              let state = try? JSONDecoder().decode(Self.self, from: data), state.isValid else { return nil }
        return state
    }
    func save(identity: String, canvasID: String, defaults: UserDefaults) {
        guard isValid, !identity.isEmpty, !canvasID.isEmpty, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(identity: identity, canvasID: canvasID))
    }
}

enum CanvasGeometry {
    static func rect(_ item: Record) -> CGRect { CGRect(x: item.number("x"), y: item.number("y"), width: item.number("width", 360), height: item.number("height", 240)) }
    static func local(_ point: CGPoint, item: Record) -> CGPoint {
        let r = rect(item), angle = -item.number("rotation") * .pi / 180
        let dx = point.x - r.midX, dy = point.y - r.midY
        return CGPoint(x: dx * cos(angle) - dy * sin(angle) + r.width / 2, y: dx * sin(angle) + dy * cos(angle) + r.height / 2)
    }
    static func world(_ point: CGPoint, item: Record) -> CGPoint {
        let r = rect(item), angle = item.number("rotation") * .pi / 180
        let dx = point.x - r.width / 2, dy = point.y - r.height / 2
        return CGPoint(x: dx * cos(angle) - dy * sin(angle) + r.midX, y: dx * sin(angle) + dy * cos(angle) + r.midY)
    }
    static func bounds(_ item: Record) -> CGRect {
        let r = rect(item)
        let points = [CGPoint.zero, CGPoint(x: r.width, y: 0), CGPoint(x: 0, y: r.height), CGPoint(x: r.width, y: r.height)].map { world($0, item: item) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

@MainActor final class CollageSurface: NSView {
    var pageBackgroundVisible = false
    weak var model: CollageStore? { didSet { if oldValue !== model { restoreViewportIfNeeded() } } }
    var needsFit = true
    var offset = CGPoint(x: 50, y: 50) { didSet { scheduleViewportSave() } }
    private var scale: Double = 1 { didSet { scheduleViewportSave() } }
    private let viewportDefaults: UserDefaults
    private var viewportIdentity: String?
    private var viewportCanvasID: String?
    private var viewportSelection = Set<String>()
    private var restoringViewport = false
    private var viewportSaveTask: Task<Void, Never>?
    private var lastSavedViewport: CollageViewportState?
    private var loaded = NSCache<NSString, NSImage>()
    private var loading = Set<String>()
    private var failed = Set<String>()
    private var downPoint = CGPoint.zero
    private var downWorld = CGPoint.zero
    private var downOffset = CGPoint.zero
    private var originals: [String: Record] = [:]
    private var action = ""
    private var handle = -1
    private var marquee: CGRect?
    private var space = false
    private var checkpointed = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var visibleCenter: CGPoint { world(CGPoint(x: bounds.midX, y: bounds.midY)) }
    var displayScale: Double { scale }
    override init(frame frameRect: NSRect) {
        viewportDefaults = .standard
        super.init(frame: frameRect)
        configureSurface()
    }
    init(frame frameRect: NSRect, viewportDefaults: UserDefaults) {
        self.viewportDefaults = viewportDefaults
        super.init(frame: frameRect)
        configureSurface()
    }
    private func configureSurface() {
        loaded.totalCostLimit = 180 * 1024 * 1024
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("拼图画布")
        NotificationCenter.default.addObserver(self, selector: #selector(flushViewportForLifecycle), name: .commitInlineTaskTitle, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(flushViewportForLifecycle), name: NSApplication.willTerminateNotification, object: nil)
    }
    deinit { viewportSaveTask?.cancel(); NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func flushViewportForLifecycle() { persistViewport() }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { persistViewport() }
        super.viewWillMove(toSuperview: newSuperview)
    }
    func scheduleViewportSave() {
        guard !restoringViewport, !needsFit, let model,
              viewportIdentity == model.api.draftIdentity, viewportCanvasID == model.activeID else { return }
        viewportSelection = model.selection
        viewportSaveTask?.cancel()
        viewportSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.persistViewport()
        }
    }
    func persistViewport() {
        viewportSaveTask?.cancel(); viewportSaveTask = nil
        guard !restoringViewport, !needsFit, let identity = viewportIdentity, let canvasID = viewportCanvasID else { return }
        if let model, model.api.draftIdentity == identity, model.activeID == canvasID { viewportSelection = model.selection }
        let state = CollageViewportState(scale: scale, offsetX: offset.x, offsetY: offset.y, selectedIDs: viewportSelection.sorted())
        guard state.isValid, state != lastSavedViewport else { return }
        state.save(identity: identity, canvasID: canvasID, defaults: viewportDefaults)
        lastSavedViewport = state
    }
    func restoreViewportIfNeeded() {
        guard let model, model.canvas != nil, !model.activeID.isEmpty else { return }
        let identity = model.api.draftIdentity, canvasID = model.activeID
        guard viewportIdentity != identity || viewportCanvasID != canvasID else {
            let validSelection = model.selection.intersection(Set(model.items.map(\.id)))
            if validSelection != model.selection { model.selection = validSelection }
            return
        }
        persistViewport()
        viewportIdentity = identity; viewportCanvasID = canvasID
        restoringViewport = true
        if let saved = CollageViewportState.load(identity: identity, canvasID: canvasID, defaults: viewportDefaults) {
            scale = saved.scale; offset = CGPoint(x: saved.offsetX, y: saved.offsetY); needsFit = false
            model.zoom = scale
            model.selection = Set(saved.selectedIDs).intersection(Set(model.items.map(\.id)))
            viewportSelection = model.selection; lastSavedViewport = saved
        } else {
            lastSavedViewport = nil; viewportSelection = []; model.selection = []
            needsFit = true
            fit()
        }
        restoringViewport = false
        needsDisplay = true
        scheduleViewportSave()
    }
    private var imageGeneration = 0
    func resetImageCache() { imageGeneration += 1; loaded.removeAllObjects(); loading.removeAll(); failed.removeAll(); needsDisplay = true }
    func retryMissingImages() { failed = []; needsDisplay = true }
    private func world(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale) }
    override func layout() { super.layout(); restoreViewportIfNeeded(); if needsFit && bounds.width > 100 { fit() } }
    func fit() {
        guard bounds.width > 100, bounds.height > 100, let model, model.canvas != nil else { return }
        needsFit = false
        guard let first = model.items.first else { scale = 1; offset = CGPoint(x: 60, y: 60); model.zoom = scale; needsDisplay = true; return }
        let content = model.items.dropFirst().reduce(CanvasGeometry.bounds(first)) { $0.union(CanvasGeometry.bounds($1)) }
        scale = max(0.02, min(1, min((bounds.width - 100) / max(1, content.width), (bounds.height - 100) / max(1, content.height))))
        offset = CGPoint(x: bounds.midX - content.midX * scale, y: bounds.midY - content.midY * scale)
        model.zoom = scale; needsDisplay = true
    }
    func zoomTo(_ value: Double, anchor: CGPoint? = nil) {
        let p = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY), before = world(p)
        scale = min(8, max(0.015, value))
        offset = CGPoint(x: p.x - before.x * scale, y: p.y - before.y * scale)
        model?.zoom = scale; needsDisplay = true
    }
    func zoomBy(_ multiplier: Double) { zoomTo(scale * multiplier) }
    override func magnify(with event: NSEvent) { zoomTo(scale * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { zoomTo(scale * exp(-event.scrollingDeltaY * 0.01), anchor: convert(event.locationInWindow, from: nil)) }
        else { offset.x += event.scrollingDeltaX; offset.y += event.scrollingDeltaY; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        if !pageBackgroundVisible { NSColor(hex: model.canvas?.text("background") ?? "#ffffff").setFill(); bounds.fill() }
        context.saveGState(); context.translateBy(x: offset.x, y: offset.y); context.scaleBy(x: scale, y: scale)
        let visible = CGRect(origin: world(.zero), size: CGSize(width: bounds.width / scale, height: bounds.height / scale))
        for item in model.items where CanvasGeometry.bounds(item).intersects(visible) {
            let image = item.text("kind") == "image" ? imageFor(item) : nil
            drawItem(item, image: image)
        }
        for item in model.selectedItems { drawSelection(item) }
        if let marquee {
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor); context.fill(marquee)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1 / scale); context.stroke(marquee)
        }
        context.restoreGState()
    }
    private func imageFor(_ item: Record) -> NSImage? {
        let file = item.text("assetFile")
        if let image = loaded.object(forKey: file as NSString) { return image }
        guard !loading.contains(file), !failed.contains(file), let api = model?.api else { return nil }
        loading.insert(file)
        let generation = imageGeneration
        Task { [weak self] in
            do {
                let data = try await api.assetData(file)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw NativeError.message("图片无法解码") }
                guard self?.imageGeneration == generation else { return }
                self?.loaded.setObject(NSImage(cgImage: cg, size: .zero), forKey: file as NSString, cost: cg.width * cg.height * 4)
            } catch { if self?.imageGeneration == generation { self?.failed.insert(file) } }
            if self?.imageGeneration == generation { self?.loading.remove(file); self?.needsDisplay = true }
        }
        return nil
    }
    func drawItem(_ item: Record, image: NSImage?) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = CanvasGeometry.rect(item)
        context.saveGState(); context.translateBy(x: rect.midX, y: rect.midY); context.rotate(by: item.number("rotation") * .pi / 180)
        context.translateBy(x: -rect.width / 2, y: -rect.height / 2)
        context.clip(to: CGRect(origin: .zero, size: rect.size))
        if item.text("kind") == "text" {
            let size = item.number("fontSize", 72)
            let font = NSFont(name: item.text("fontFamily"), size: size) ?? NSFont.systemFont(ofSize: size)
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
            (item.text("text") as NSString).draw(in: CGRect(origin: .zero, size: rect.size), withAttributes: [.font: font, .foregroundColor: NSColor(hex: item.text("color")), .paragraphStyle: style])
        } else if let image {
            let w = item.number("imageWidth", rect.width), h = item.number("imageHeight", rect.height)
            let r = CGRect(x: (rect.width - w) / 2 + item.number("imageOffsetX"), y: (rect.height - h) / 2 + item.number("imageOffsetY"), width: w, height: h)
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            NSColor.gray.withAlphaComponent(0.15).setFill(); CGRect(origin: .zero, size: rect.size).fill()
            let text = failed.contains(item.text("assetFile")) ? "图片不可用" : "载入中"
            (text as NSString).draw(at: CGPoint(x: 12, y: 12), withAttributes: [.font: NSFont.systemFont(ofSize: min(28, rect.width / 10)), .foregroundColor: NSColor.gray])
        }
        context.restoreGState()
    }
    private func handles(_ item: Record) -> [CGPoint] {
        let r = CanvasGeometry.rect(item)
        return [CGPoint(x: 0, y: 0), CGPoint(x: r.width / 2, y: 0), CGPoint(x: r.width, y: 0), CGPoint(x: r.width, y: r.height / 2), CGPoint(x: r.width, y: r.height), CGPoint(x: r.width / 2, y: r.height), CGPoint(x: 0, y: r.height), CGPoint(x: 0, y: r.height / 2), CGPoint(x: r.width / 2, y: -28 / scale)].map { CanvasGeometry.world($0, item: item) }
    }
    private func drawSelection(_ item: Record) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        let h = handles(item)
        c.setStrokeColor(NSColor.controlAccentColor.cgColor); c.setLineWidth(1.5 / scale)
        c.move(to: h[0]); c.addLine(to: h[2]); c.addLine(to: h[4]); c.addLine(to: h[6]); c.closePath(); c.strokePath()
        guard !item["locked"].bool else { return }
        c.move(to: h[1]); c.addLine(to: h[8]); c.strokePath()
        for (index, point) in h.enumerated() {
            let crop = item.text("kind") == "image" && CropEdge(handle: index) != nil
            let w = crop ? ([1, 5].contains(index) ? 16.0 : 6.0) : 8.0
            let height = crop ? ([1, 5].contains(index) ? 6.0 : 16.0) : 8.0
            let r = CGRect(x: -w / scale / 2, y: -height / scale / 2, width: w / scale, height: height / scale)
            c.saveGState(); c.translateBy(x: point.x, y: point.y); c.rotate(by: item.number("rotation") * .pi / 180)
            c.setFillColor(NSColor.white.cgColor); c.fill(r); c.stroke(r)
            c.restoreGState()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        window?.makeFirstResponder(self)
        downPoint = convert(event.locationInWindow, from: nil); downWorld = world(downPoint); downOffset = offset
        checkpointed = false; handle = -1
        if space || event.buttonNumber == 2 { action = "pan"; return }
        for item in model.selectedItems.reversed() where !item["locked"].bool {
            if let i = handles(item).firstIndex(where: { hypot($0.x - downWorld.x, $0.y - downWorld.y) < 8 / scale }) {
                handle = i; action = i == 8 ? "rotate" : "resize"; originals = [item.id: item]; return
            }
        }
        if let item = model.items.reversed().first(where: {
            CGRect(origin: .zero, size: CanvasGeometry.rect($0).size).contains(CanvasGeometry.local(downWorld, item: $0))
        }) {
            if event.modifierFlags.contains(.shift) {
                if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
            } else if !model.selection.contains(item.id) { model.selection = [item.id] }
            originals = Dictionary(uniqueKeysWithValues: model.selectedItems.filter { !$0["locked"].bool }.map { ($0.id, $0) })
            action = "move"
            if event.clickCount == 2 && item.text("kind") == "text" && !item["locked"].bool { editText(item) }
        } else {
            if !event.modifierFlags.contains(.shift) { model.selection = [] }
            action = "marquee"; marquee = CGRect(origin: downWorld, size: .zero)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil), p = world(point)
        let dx = p.x - downWorld.x, dy = p.y - downWorld.y
        if action == "pan" { offset = CGPoint(x: downOffset.x + point.x - downPoint.x, y: downOffset.y + point.y - downPoint.y); needsDisplay = true; return }
        if action == "marquee" { marquee = CGRect(x: min(p.x, downWorld.x), y: min(p.y, downWorld.y), width: abs(dx), height: abs(dy)); needsDisplay = true; return }
        guard !originals.isEmpty else { return }
        if !checkpointed { model.checkpoint(); checkpointed = true }
        var updates: [String: Record] = [:]
        for (id, original) in originals {
            var item = original
            if action == "move" {
                item["x"] = .number(max(0, original.number("x") + dx)); item["y"] = .number(max(0, original.number("y") + dy))
            } else if action == "rotate" {
                let r = CanvasGeometry.rect(original)
                let start = atan2(downWorld.y - r.midY, downWorld.x - r.midX), end = atan2(p.y - r.midY, p.x - r.midX)
                var rotation = original.number("rotation") + (end - start) * 180 / .pi
                if event.modifierFlags.contains(.shift) { rotation = (rotation / 15).rounded() * 15 }
                item["rotation"] = .number(rotation)
            } else if action == "resize" {
                item = CanvasTransform.draggingHandle(handle, delta: CGSize(width: dx, height: dy), item: original, proportional: event.modifierFlags.contains(.shift))
            }
            updates[id] = item
        }
        model.updateItems(updates); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let marquee, let model { model.selection.formUnion(model.items.filter { CanvasGeometry.bounds($0).intersects(marquee) }.map(\.id)) }
        marquee = nil; action = ""; originals = [:]; needsDisplay = true
    }
    private func editText(_ item: Record) {
        let alert = NSAlert(); alert.messageText = "编辑文字"; alert.addButton(withTitle: "完成"); alert.addButton(withTitle: "取消")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 180)); scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: scroll.bounds); editor.string = item.text("text"); editor.isRichText = false; editor.font = .systemFont(ofSize: 16); scroll.documentView = editor; alert.accessoryView = scroll
        alert.window.initialFirstResponder = editor
        if alert.runModal() == .alertFirstButtonReturn { model?.updateSelected("text", .string(editor.string)) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { space = true; NSCursor.openHand.set(); return }
        if event.keyCode == 51 || event.keyCode == 117 { model?.deleteSelection(); return }
        if event.keyCode == 53 { model?.selection = []; return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": model?.selection = Set(model?.items.map(\.id) ?? [])
            case "d": model?.duplicate()
            case "z": if event.modifierFlags.contains(.shift) { model?.redo() } else { model?.undo() }
            case "v": pasteImages()
            case "c": copySelected()
            case "t": model?.addText()
            default: super.keyDown(with: event)
            }
        } else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { space = false; NSCursor.arrow.set() } else { super.keyUp(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command), ["a", "d", "z", "v", "c", "t"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    private func copySelected() {
        guard let items = model?.selectedItems, !items.isEmpty, let data = try? JSONEncoder().encode(items) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .init("com.hero-oos.items"))
    }
    private func pasteImages() {
        if let data = NSPasteboard.general.data(forType: .init("com.hero-oos.items")), let items = try? JSONDecoder().decode([Record].self, from: data), let model {
            let top = model.items.map { $0.number("z") }.max() ?? 0
            var pasted: [JSON] = []
            for (i, var item) in items.enumerated() { item["id"] = .string("collage-item-\(UUID().uuidString)"); item["x"] = .number(item.number("x") + 40); item["y"] = .number(item.number("y") + 40); item["z"] = .number(top + Double(i) + 1); pasted.append(item.json) }
            model.mutateCanvas { $0["items"] = .array($0["items"].array + pasted) }; model.selection = Set(pasted.map { $0["id"].string }); return
        }
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty { Task { await model?.addImages(urls) }; return }
        if let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("oos-paste-\(UUID().uuidString).png")
            do { try png.write(to: url); Task { await model?.addImages([url]); try? FileManager.default.removeItem(at: url) } }
            catch { model?.error = error.localizedDescription }
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
        let point = world(convert(sender.draggingLocation, from: nil))
        Task { await model?.addImages(urls, point: point) }; return true
    }
    func exportJPG() async {
        guard let model else { return }
        let items = model.selection.isEmpty ? model.items : model.selectedItems
        guard let first = items.first else { return }
        let content = items.dropFirst().reduce(CanvasGeometry.bounds(first)) { $0.union(CanvasGeometry.bounds($1)) }.integral
        guard content.width * content.height <= 64_000_000, content.width > 0, content.height > 0 else { model.error = "导出区域超过 6400 万像素，请缩小导出范围。"; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.jpeg]; panel.nameFieldStringValue = "\(model.canvas?.text("name") ?? "拼图").jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var originals: [String: NSImage] = [:]
            for item in items where item.text("kind") == "image" {
                let file = item.text("assetFile")
                if originals[file] == nil {
                    let data = try await model.api.assetData(file)
                    guard let image = NSImage(data: data) else { throw NativeError.message("原图不可用：\(item.text("originalName"))") }
                    originals[file] = image
                }
            }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(content.width), pixelsHigh: Int(content.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { throw NativeError.message("无法创建导出图片") }
            NSGraphicsContext.saveGraphicsState()
            let cg = graphics.cgContext; cg.translateBy(x: 0, y: content.height); cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            cg.setFillColor(NSColor(hex: model.canvas?.text("background") ?? "#ffffff").cgColor); cg.fill(CGRect(origin: .zero, size: content.size)); cg.translateBy(x: -content.minX, y: -content.minY)
            for item in items { drawItem(item, image: originals[item.text("assetFile")]) }
            NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else { throw NativeError.message("JPG 编码失败") }
            try data.write(to: url, options: .atomic); model.message = "已导出 JPG"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { model.error = error.localizedDescription }
    }
}
