import SwiftUI
import AppKit

enum ImageDimensionScale {
    static let range = log10(40.0)...log10(20000.0)
    static func position(_ pixels: Double) -> Double { log10(min(20000, max(40, pixels.isFinite ? pixels : 40))) }
    static func pixels(_ position: Double) -> Double { min(20000, max(40, pow(10, position))).rounded() }
}

struct ImageDimensionControl: View {
    @EnvironmentObject var model: CollageStore
    let key: String
    let title: String
    @Binding var value: Double
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, value: $value, format: .number.precision(.fractionLength(0)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
            }
            // A fixed logarithmic range keeps small and large images adjustable without a moving thumb scale.
            DimensionSlider(value: Binding(get: { ImageDimensionScale.position(value) }, set: {
                model.resizeSelected(key, value: ImageDimensionScale.pixels($0))
            }), title: key == "width" ? "宽度" : "高度", onEditingChanged: { editing in
                if editing { model.beginSizeAdjustment() } else { model.endSizeAdjustment() }
            }).frame(height: 24)
                .help(key == "width" ? "调整宽度，不改变高度" : "调整高度，不改变宽度")
        }.frame(maxWidth: .infinity).onDisappear { model.endSizeAdjustment() }
    }
}

struct DimensionSlider: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Binding var value: Double
    let title: String
    var onEditingChanged: (Bool) -> Void
    func makeNSView(context: Context) -> DimensionSliderView {
        let slider = DimensionSliderView()
        slider.minValue = ImageDimensionScale.range.lowerBound
        slider.maxValue = ImageDimensionScale.range.upperBound
        slider.isContinuous = true
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        return slider
    }
    func updateNSView(_ slider: DimensionSliderView, context: Context) {
        context.coordinator.owner = self
        slider.doubleValue = value; slider.isEnabled = enabled
        slider.editingChanged = onEditingChanged
        slider.setAccessibilityLabel(title)
        slider.setAccessibilityValueDescription("\(Int(ImageDimensionScale.pixels(value))) 像素")
    }
    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }
    final class Coordinator: NSObject {
        var owner: DimensionSlider
        init(owner: DimensionSlider) { self.owner = owner }
        @objc func changed(_ slider: NSSlider) { owner.value = slider.doubleValue }
    }
}

final class DimensionSliderView: NSSlider {
    var editingChanged: ((Bool) -> Void)?
    private var trackingDrag = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        trackingDrag = true; editingChanged?(true)
        applyPointer(event)
    }
    override func mouseDragged(with event: NSEvent) {
        if trackingDrag { applyPointer(event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard trackingDrag else { return }
        applyPointer(event); trackingDrag = false; editingChanged?(false)
    }
    private func applyPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let knob = (cell as? NSSliderCell)?.knobRect(flipped: isFlipped).width ?? 16
        let fraction = min(1, max(0, (point.x - bounds.minX - knob / 2) / max(1, bounds.width - knob)))
        doubleValue = minValue + fraction * (maxValue - minValue)
        sendAction(action, to: target)
    }
}
