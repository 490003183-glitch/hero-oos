import Foundation

extension StateRuntime {
    public func request(_ path: String, method: String = "GET", body: JSON? = nil, raw: Data? = nil, contentType: String = "application/json") throws -> JSON {
        guard let url = URLComponents(string: path) else { throw RuntimeError("invalid_path", "无效操作路径。") }
        let payload = body ?? [:]
        switch (method, url.path) {
        case ("GET", "/api/health"):
            let state = try readState(); return ["ok": true, "instanceId": state["meta"]["instanceId"], "version": state["meta"]["version"], "runtimeVersion": "1.1.0-swift", "transport": "swift-local"]
        case ("GET", "/api/meta"): return ["ok": true, "meta": try readState()["meta"]]
        case ("GET", "/api/state"): return ["ok": true, "state": try readState()]
        case ("GET", "/api/attention"):
            let state = try readState(); return ["ok": true, "version": state["meta"]["version"], "attention": .array(attention(state))]
        case ("POST", "/api/state-ops"): return try mutate(payload)
        case ("GET", "/api/codex-status"):
            let ids = (url.queryItems?.first { $0.name == "ids" }?.value ?? "").split(separator: ",").map(String.init)
            return ["ok": true, "statuses": CodexStatus.read(ids)]
        case ("GET", "/api/collages"): return ["ok": true, "collages": try readCollages()]
        case ("PUT", "/api/collages"): return ["ok": true, "collages": try saveCollages(payload["collages"], expected: payload.object["expectedCollages"])]
        case ("POST", "/api/collages/cleanup-assets"): return ["ok": true, "removedCount": .number(Double(try cleanupAssets()))]
        case ("POST", "/api/collage-assets"):
            return ["ok": true, "asset": try importAsset(raw ?? Data(), name: url.queryItems?.first { $0.name == "filename" }?.value ?? "图片", contentType: contentType)]
        default: throw RuntimeError("unsupported_request", "不支持的本地操作：\(method) \(url.path)")
        }
    }
}
