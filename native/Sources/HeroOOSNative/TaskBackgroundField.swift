import SwiftUI
import AppKit
import OOSCore

struct TaskBackgroundField: View {
    @Binding var text: String
    @State private var reachedLimit = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("任务基础背景")
                Spacer()
                Text("\(TaskBackground.count(text)) / \(TaskBackground.limit)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            BackgroundTextEditor(text: $text, reachedLimit: $reachedLimit)
            .frame(height: 132)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            if reachedLimit {
                Text("最多 2000 字，超出的内容未加入。").font(.caption).foregroundStyle(.orange)
            }
        }.padding(.vertical, 4)
    }
}

struct BackgroundTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var reachedLimit: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let editor = BackgroundTextView(frame: scroll.bounds)
        editor.isRichText = false; editor.importsGraphics = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor; editor.drawsBackground = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 7, height: 9)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.allowsUndo = true
        editor.setAccessibilityLabel("任务基础背景")
        editor.setAccessibilityHelp("最多 2000 字，支持换行，自动保存")
        editor.string = text
        editor.delegate = context.coordinator
        editor.compositionCommitted = { [weak coordinator = context.coordinator, weak editor] in
            if let editor { coordinator?.publish(editor) }
        }
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? BackgroundTextView,
              !editor.hasMarkedText(), editor.string != text else { return }
        let selection = editor.selectedRange()
        editor.string = text
        editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BackgroundTextEditor
        init(_ parent: BackgroundTextEditor) { self.parent = parent }
        func textView(_ editor: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !editor.hasMarkedText(), (editor as? BackgroundTextView)?.changingMarkedText != true,
                  let replacementString, let range = Range(affectedCharRange, in: editor.string) else { return true }
            let remaining = TaskBackground.limit - TaskBackground.count(editor.string.replacingCharacters(in: range, with: ""))
            guard TaskBackground.count(replacementString) > remaining else { return true }
            let accepted = TaskBackground.clipped(replacementString, limit: remaining)
            if !accepted.isEmpty { editor.insertText(accepted, replacementRange: affectedCharRange) }
            parent.reachedLimit = true
            return false
        }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { publish(editor) }
        }
        func publish(_ editor: NSTextView) {
            // Never truncate or save the temporary pinyin / marked composition.
            guard !editor.hasMarkedText(), (editor as? BackgroundTextView)?.changingMarkedText != true else { return }
            let value = editor.string
            if TaskBackground.count(value) > TaskBackground.limit {
                // An over-limit IME commit must not delete the existing text after the caret.
                let selection = editor.selectedRange()
                editor.string = parent.text
                editor.setSelectedRange(NSRange(location: min(selection.location, (parent.text as NSString).length), length: 0))
                parent.reachedLimit = true
                return
            }
            parent.reachedLimit = false
            if parent.text != value { parent.text = value }
        }
    }
}

final class BackgroundTextView: NSTextView {
    var compositionCommitted: (() -> Void)?
    var changingMarkedText = false
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        changingMarkedText = true
        defer { changingMarkedText = false }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func unmarkText() {
        super.unmarkText()
        DispatchQueue.main.async { [weak self] in self?.compositionCommitted?() }
    }
}
