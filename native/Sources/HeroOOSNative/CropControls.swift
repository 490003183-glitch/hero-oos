import SwiftUI

enum CropEdge: String, CaseIterable, Identifiable {
    case top, bottom, left, right
    var id: String { rawValue }
    init?(handle: Int) {
        switch handle { case 1: self = .top; case 3: self = .right; case 5: self = .bottom; case 7: self = .left; default: return nil }
    }
    var title: String {
        switch self { case .top: return "上"; case .bottom: return "下"; case .left: return "左"; case .right: return "右" }
    }
}

enum ImageCrop {
    static func imageRect(_ item: Record) -> CGRect {
        let frame = CanvasGeometry.rect(item)
        let width = max(1, item.number("imageWidth", frame.width))
        let height = max(1, item.number("imageHeight", frame.height))
        return CGRect(x: (frame.width - width) / 2 + item.number("imageOffsetX"),
                      y: (frame.height - height) / 2 + item.number("imageOffsetY"), width: width, height: height)
    }
    static func fraction(_ edge: CropEdge, item: Record) -> Double {
        let image = imageRect(item), frame = CanvasGeometry.rect(item)
        let value: Double
        switch edge {
        case .top: value = -image.minY / image.height
        case .bottom: value = (image.maxY - frame.height) / image.height
        case .left: value = -image.minX / image.width
        case .right: value = (image.maxX - frame.width) / image.width
        }
        return value > 0 ? min(1, value) : 0
    }
    static func applying(_ edge: CropEdge, fraction: Double, to original: Record) -> Record {
        guard original.text("kind") == "image", !original["locked"].bool, fraction.isFinite else { return original }
        let amount = min(1, max(0, fraction))
        let image = imageRect(original), frame = CanvasGeometry.rect(original)
        var left = 0.0, top = 0.0, right = frame.width, bottom = frame.height
        switch edge {
        case .top: top = min(bottom - 40, max(bottom - 20000, image.minY + amount * image.height))
        case .bottom: bottom = max(40, min(20000, image.maxY - amount * image.height))
        case .left: left = min(right - 40, max(right - 20000, image.minX + amount * image.width))
        case .right: right = max(40, min(20000, image.maxX - amount * image.width))
        }
        let width = right - left, height = bottom - top
        let center = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
        // Move only the clipping frame; keep the source image fixed in world space, including rotation.
        let worldCenter = CanvasGeometry.world(center, item: original)
        var result = original
        result["x"] = .number(worldCenter.x - width / 2)
        result["y"] = .number(worldCenter.y - height / 2)
        result["width"] = .number(width); result["height"] = .number(height)
        result["imageWidth"] = .number(image.width); result["imageHeight"] = .number(image.height)
        result["imageOffsetX"] = .number(original.number("imageOffsetX") - (center.x - frame.width / 2))
        result["imageOffsetY"] = .number(original.number("imageOffsetY") - (center.y - frame.height / 2))
        return result
    }
    static func dragging(_ edge: CropEdge, delta: CGSize, item: Record) -> Record {
        let image = imageRect(item)
        let change: Double
        switch edge {
        case .top: change = delta.height / image.height
        case .bottom: change = -delta.height / image.height
        case .left: change = delta.width / image.width
        case .right: change = -delta.width / image.width
        }
        return applying(edge, fraction: fraction(edge, item: item) + change, to: item)
    }
}

enum CanvasTransform {
    static func draggingHandle(_ handle: Int, delta: CGSize, item original: Record, proportional: Bool = false) -> Record {
        guard (0...7).contains(handle), !original["locked"].bool, delta.width.isFinite, delta.height.isFinite else { return original }
        let angle = original.number("rotation") * .pi / 180
        let dx = delta.width * cos(angle) + delta.height * sin(angle)
        let dy = -delta.width * sin(angle) + delta.height * cos(angle)
        let image = original.text("kind") == "image"
        if image, let edge = CropEdge(handle: handle) {
            return ImageCrop.dragging(edge, delta: CGSize(width: dx, height: dy), item: original)
        }
        let r = CanvasGeometry.rect(original)
        let left = [0, 6, 7].contains(handle), right = [2, 3, 4].contains(handle)
        let top = [0, 1, 2].contains(handle), bottom = [4, 5, 6].contains(handle)
        var w = min(20000, max(40, r.width + (left ? -dx : right ? dx : 0)))
        var h = min(20000, max(40, r.height + (top ? -dy : bottom ? dy : 0)))
        if image || proportional {
            let proposed = 1 + ((left ? -dx : dx) * r.width + (top ? -dy : dy) * r.height) / max(1, r.width * r.width + r.height * r.height)
            let factor = min(20000 / max(r.width, r.height), max(40 / max(1, min(r.width, r.height)), proposed))
            w = r.width * factor; h = r.height * factor
        }
        let cx = (left ? -(w - r.width) : right ? w - r.width : 0) / 2
        let cy = (top ? -(h - r.height) : bottom ? h - r.height : 0) / 2
        var item = original
        item["x"] = .number(r.midX + cx * cos(angle) - cy * sin(angle) - w / 2)
        item["y"] = .number(r.midY + cx * sin(angle) + cy * cos(angle) - h / 2)
        item["width"] = .number(w); item["height"] = .number(h)
        if image {
            item["imageWidth"] = .number(original.number("imageWidth", r.width) * w / r.width)
            item["imageHeight"] = .number(original.number("imageHeight", r.height) * h / r.height)
            item["imageOffsetX"] = .number(original.number("imageOffsetX") * w / r.width)
            item["imageOffsetY"] = .number(original.number("imageOffsetY") * h / r.height)
        }
        return item
    }
}
