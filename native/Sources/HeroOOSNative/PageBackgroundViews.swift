import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name { static let configurePageBackground = Notification.Name("HeroOOS.configurePageBackground") }

private struct PageBackgroundVisibleKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var pageBackgroundVisible: Bool {
        get { self[PageBackgroundVisibleKey.self] }
        set { self[PageBackgroundVisibleKey.self] = newValue }
    }
}

/// The wallpaper is viewport decoration, never a canvas item or an export layer.
struct PageBackgroundLayer: View {
    let image: NSImage?
    let configuration: PageBackgroundConfiguration?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let image, let configuration {
                    Image(nsImage: image).resizable()
                        .aspectRatio(contentMode: configuration.fit == .fill ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .brightness(configuration.brightness - 1)
                        .opacity(configuration.opacity)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PageBackgroundChoice: Identifiable {
    let id: String
    let title: String
}

struct PageBackgroundSettings: View {
    @ObservedObject var backgrounds: PageBackgroundStore
    let pages: [PageBackgroundChoice]
    @Environment(\.dismiss) private var dismiss
    @State private var scope: String
    @State private var importing = false
    @State private var error: String?
    private static let allPages = "__all_pages__"

    init(backgrounds: PageBackgroundStore, pages: [PageBackgroundChoice], currentPage: String) {
        self.backgrounds = backgrounds; self.pages = pages
        _scope = State(initialValue: currentPage)
    }
    private var isGlobal: Bool { scope == Self.allPages }
    private var configuration: PageBackgroundConfiguration? {
        isGlobal ? backgrounds.global : backgrounds.effective(for: scope)
    }
    private var previewImage: NSImage? { configuration.flatMap { backgrounds.image(for: $0) } }
    private var scopeDescription: String {
        if isGlobal { return "此处的更改会统一应用到所有页面，并替换原有单页配置。之后仍可分别设置。" }
        if let rule = backgrounds.overrides[scope] {
            if case .none = rule { return "此页面已关闭背景图片；不会影响其他页面。" }
            return "此页面使用独立背景；不会影响其他页面。"
        }
        return "此页面跟随统一背景。选择图片或调节参数后，会变为此页独立配置。"
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("页面背景", systemImage: "photo.on.rectangle").font(.title2.weight(.semibold))
                Spacer()
                Text("仅本机 · 不上传").font(.callout).foregroundStyle(.secondary)
            }
            Picker("配置页面", selection: $scope) {
                Text("全部页面（统一背景）").tag(Self.allPages)
                Divider()
                ForEach(pages) { page in Text(page.title).tag(page.id) }
            }.disabled(importing)
            Text(scopeDescription).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ZStack {
                PageBackgroundLayer(image: previewImage, configuration: configuration)
                if previewImage == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.largeTitle)
                        Text(configuration == nil ? "未设置背景图片" : "背景图片不可用，请重新选择")
                    }.foregroundStyle(.secondary)
                } else {
                    Text("页面文字预览").font(.headline).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }.frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
            HStack {
                Button(configuration == nil ? "选择背景图片…" : "更换背景图片…", action: chooseImage)
                    .disabled(importing)
                if importing { ProgressView().controlSize(.small); Text("正在复制图片…").foregroundStyle(.secondary) }
                if !isGlobal, let configuration {
                    Button("应用到全部页面") {
                        save { try backgrounds.applyToAll(configuration); scope = Self.allPages }
                    }.disabled(importing).help("替换全部页面的独立背景；之后仍可分别设置")
                }
                Spacer()
                Text("JPG / PNG · 原图保留").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                Picker("显示方式", selection: Binding(get: { configuration?.fit ?? .fill }, set: { fit in update { $0.fit = fit } })) {
                    Text("等比铺满（允许裁边）").tag(PageBackgroundFit.fill)
                    Text("完整显示（可能留白）").tag(PageBackgroundFit.fit)
                }.pickerStyle(.segmented)
                parameter("透明度", value: Binding(get: { 1 - (configuration?.opacity ?? 0.30) }, set: { value in update { $0.opacity = 1 - value } }), range: 0...1)
                parameter("亮度", value: Binding(get: { configuration?.brightness ?? 1 }, set: { value in update { $0.brightness = value } }), range: 0...2)
                Text("透明度 0% 为不透明，100% 为完全透明；亮度 100% 为原图亮度。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(configuration == nil || importing)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).lineLimit(3) }
            Text("修改自动保存在此 Mac 的当前账号下。图片已复制到 App 本机文件区，移动原文件不会影响背景；不共享给组织或其他设备。拼图导出不包含页面背景。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24)
        }
        Divider()
            HStack {
                if !isGlobal {
                    Button("跟随统一背景") { save { try backgrounds.setOverride(nil, for: scope) } }
                        .disabled(importing || backgrounds.overrides[scope] == nil)
                    Button("此页不显示背景") { save { try backgrounds.setOverride(PageBackgroundRule.none, for: scope) } }.disabled(importing)
                } else {
                    Button("全部恢复默认") { save { try backgrounds.applyToAll(nil) } }.disabled(importing)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).disabled(importing)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 640, height: 590)
            .interactiveDismissDisabled(importing)
    }

    private func parameter(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 48, alignment: .leading)
            Slider(value: value, in: range, step: 0.01).accessibilityLabel(title)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }
    private func update(_ change: (inout PageBackgroundConfiguration) -> Void) {
        guard var value = configuration else { return }
        change(&value); apply(value)
    }
    private func apply(_ value: PageBackgroundConfiguration) {
        save {
            if isGlobal { try backgrounds.applyToAll(value) }
            else { try backgrounds.setOverride(.image(value), for: scope) }
        }
    }
    private func save(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "选择页面背景图片"; panel.prompt = "使用图片"
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importing = true; error = nil
            Task { @MainActor in
                defer { importing = false }
                do { let configuration = try await backgrounds.importImage(from: url); apply(configuration) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
