import Foundation

extension StateRuntime {
    static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    public static func validAsset(_ name: String) -> Bool { matches(name, "(?i)^[a-z0-9-]+\\.(?:jpe?g|png|webp|gif)$") }
    public static var defaultCollages: JSON { ["version": 1, "activeCanvasId": "collage-default", "canvases": [["id": "collage-default", "name": "拼图 1", "background": "#000000", "items": []]]] }
    public func normalizeCollages(_ source: JSON) -> JSON {
        var seen = Set<String>()
        let canvases: [JSON] = source["canvases"].array.enumerated().map { index, original in
            var canvas = original
            let id = canvas["id"].string
            if !Self.matches(id, "^[a-zA-Z0-9-]+$") || !seen.insert(id).inserted { canvas["id"] = Self.id("collage"); seen.insert(canvas["id"].string) }
            let name = String(canvas["name"].or(.string("拼图 \(index + 1)")).trimmed.prefix(60))
            canvas["name"] = .string(name.isEmpty ? "拼图 \(index + 1)" : name)
            canvas["background"] = .string(Self.matches(canvas["background"].string, "(?i)^#[0-9a-f]{6}$") ? canvas["background"].string.lowercased() : "#000000")
            canvas["items"] = .array(canvas["items"].array.compactMap { original in
                guard Self.matches(original["id"].string, "^[a-zA-Z0-9-]+$") else { return nil }
                var item = original
                func n(_ key: String, _ fallback: Double, _ min: Double, _ max: Double) -> Double {
                    let raw = original[key]; let number: Double?
                    switch raw { case .number(let v): number = v; case .string(let v): number = Double(v); default: number = nil }
                    return number.map { $0.isFinite ? Swift.min(max, Swift.max(min, $0)) : fallback } ?? fallback
                }
                let width = n("width", 360, 40, 20000), height = n("height", 240, 40, 20000)
                item["width"] = .number(width); item["height"] = .number(height)
                item["x"] = .number(n("x", 80, 0, 200000)); item["y"] = .number(n("y", 80, 0, 200000))
                item["rotation"] = .number(n("rotation", 0, -100000, 100000)); item["z"] = .number(n("z", 1, 0, 1000000)); item["locked"] = .bool(item["locked"].bool)
                if item["kind"] == "text" {
                    let fonts = ["PingFang SC", "Songti SC", "Kaiti SC", "Heiti SC", "Arial", "Helvetica", "Georgia", "Times New Roman"]
                    item["text"] = .string(String(item["text"].or("输入文字").string.prefix(5000)))
                    item["fontFamily"] = fonts.contains(item["fontFamily"].string) ? item["fontFamily"] : "PingFang SC"
                    item["fontSize"] = .number(n("fontSize", 72, 8, 500))
                    item["color"] = .string(Self.matches(item["color"].string, "(?i)^#[0-9a-f]{6}$") ? item["color"].string.lowercased() : "#ffffff")
                    return item
                }
                guard Self.validAsset(item["assetFile"].string) else { return nil }
                let nw = n("naturalWidth", 1, 1, 40000), nh = n("naturalHeight", 1, 1, 40000)
                let zoom = n("cropZoom", 1, 1, 8), x = n("cropX", 0, -1, 1), y = n("cropY", 0, -1, 1)
                let scale = max(width * zoom / nw, height * zoom / nh)
                let hasLayout = item["imageWidth"] != .null && item["imageHeight"] != .null
                item["kind"] = "image"; item["originalName"] = .string(String(item["originalName"].or("图片").string.prefix(240)))
                for (key, value) in ["naturalWidth": nw, "naturalHeight": nh, "cropZoom": zoom, "cropX": x, "cropY": y, "imageWidth": hasLayout ? n("imageWidth", width * zoom, 1, 200000) : nw * scale, "imageHeight": hasLayout ? n("imageHeight", height * zoom, 1, 200000) : nh * scale, "imageOffsetX": n("imageOffsetX", x * (width * zoom - width) / 2, -200000, 200000), "imageOffsetY": n("imageOffsetY", y * (height * zoom - height) / 2, -200000, 200000)] { item[key] = .number(value) }
                return item
            })
            return canvas
        }
        guard !canvases.isEmpty else { return Self.defaultCollages }
        var result = source; result["version"] = 1; result["canvases"] = .array(canvases)
        result["activeCanvasId"] = canvases.contains { $0["id"] == source["activeCanvasId"] } ? source["activeCanvasId"] : canvases[0]["id"]
        return result
    }
    func readCollagesUnlocked() throws -> JSON { normalizeCollages(try readJSON(file("collages.json"), fallback: Self.defaultCollages)) }
    public func readCollages() throws -> JSON { try locked { try readCollagesUnlocked() } }
    public func saveCollages(_ collages: JSON, expected: JSON?) throws -> JSON {
        try locked {
            guard let expected else { throw RuntimeError("collage_expected_required", "拼图写入需要原始版本。") }
            guard normalizeCollages(expected) == (try readCollagesUnlocked()) else { throw RuntimeError("collage_conflict", "拼图刚刚在另一端更新。你的编辑已保留，请重试保存。") }
            let next = normalizeCollages(collages)
            try writeJSON(next, to: file("collages.json")); return next
        }
    }
    public func assetURL(_ name: String) throws -> URL {
        guard Self.validAsset(name) else { throw RuntimeError("invalid_asset", "图片文件名无效。") }
        let directory = file("collage-assets").resolvingSymlinksInPath()
        let url = directory.appendingPathComponent(name).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == directory else { throw RuntimeError("invalid_asset", "图片路径越界。") }
        return url
    }
    public func importAsset(_ data: Data, name: String, contentType: String) throws -> JSON {
        guard let ext = ["image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif"][contentType.lowercased()] else { throw RuntimeError("unsupported_image", "仅支持 JPG、PNG、WebP 和 GIF 图片。") }
        guard !data.isEmpty, data.count <= 80_000_000 else { throw RuntimeError("invalid_image_size", "图片为空或超过 80 MB。") }
        return try locked {
            try FileManager.default.createDirectory(at: file("collage-assets"), withIntermediateDirectories: true)
            let id = UUID().uuidString.lowercased(), nameOnDisk = "\(id).\(ext)"
            try data.write(to: assetURL(nameOnDisk), options: .withoutOverwriting)
            return ["id": .string(id), "assetFile": .string(nameOnDisk), "originalName": .string(String(name.prefix(240))), "url": .string("/api/collage-assets/\(nameOnDisk)")]
        }
    }
    public func cleanupAssets() throws -> Int {
        try locked {
            let referenced = Set(try readCollagesUnlocked()["canvases"].array.flatMap { $0["items"].array.map { $0["assetFile"].string } })
            let directory = file("collage-assets")
            guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
            var removed = 0
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) where Self.validAsset(url.lastPathComponent) && !referenced.contains(url.lastPathComponent) {
                // Other processes may have imported an image but not saved their canvas yet.
                let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
                guard modified < Date().addingTimeInterval(-86400) else { continue }
                try FileManager.default.removeItem(at: url); removed += 1
            }
            return removed
        }
    }
}
