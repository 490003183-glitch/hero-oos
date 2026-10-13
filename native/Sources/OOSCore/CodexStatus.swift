import Foundation
import SQLite3

public enum CodexStatus {
    private static let lock = NSLock()
    private static var cache: [String: (Date, UInt64, JSON)] = [:]
    public static func read(_ rawIDs: [String]) -> JSON {
        let ids = Array(Set(rawIDs.filter { StateRuntime.matches($0, "(?i)^[0-9a-z_-]{8,160}$") }).sorted().prefix(100))
        guard !ids.isEmpty else { return [:] }
        let database = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return .object(Dictionary(uniqueKeysWithValues: ids.map { ($0, ["id": .string($0), "status": "idle", "detail": "codex_state_unavailable"] as JSON) }))
        }
        defer { sqlite3_close(db) }
        var result: [String: JSON] = [:]
        for id in ids {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { result[id] = ["id": .string(id), "status": "idle", "detail": "codex_state_unavailable"]; continue }
            defer { sqlite3_finalize(statement) }
            _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(statement) == SQLITE_ROW, let path = sqlite3_column_text(statement, 0) else { result[id] = ["id": .string(id), "status": "idle", "detail": "thread_not_found"]; continue }
            let url = URL(fileURLWithPath: String(cString: path))
            do { result[id] = try snapshot(id, url) } catch { result[id] = ["id": .string(id), "status": "idle", "detail": "status_unavailable"] }
        }
        return .object(result)
    }
    private static func excerpt(_ text: String, user: Bool) -> String {
        var value = text
        if user {
            let markers = ["## My request:", "# My request:", "My request:", "## My request for Codex:"]
            if let range = markers.compactMap({ value.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound }) { value = String(value[range.upperBound...]) }
            value = value.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "</?image\\b[^>]*>", with: " ", options: .regularExpression)
            let regex = try! NSRegularExpression(pattern: "&#(x[0-9a-f]+|[0-9]+);", options: [.caseInsensitive])
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value), let digitsRange = Range(match.range(at: 1), in: value) else { continue }
                let digits = String(value[digitsRange]).lowercased()
                if let number = UInt32(digits.hasPrefix("x") ? String(digits.dropFirst()) : digits, radix: digits.hasPrefix("x") ? 16 : 10), let scalar = UnicodeScalar(number) { value.replaceSubrange(range, with: String(scalar)) }
            }
            if StateRuntime.matches(value, "(?i)^#\\s*Files?\\s+(mentioned|pasted)\\b|^Distinguish instructions\\b") { return "" }
        }
        value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.count > 50 ? String(value.prefix(49)) + "…" : value
    }
    private static func snapshot(_ id: String, _ url: URL) throws -> JSON {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        lock.lock(); let cached = cache[url.path]; lock.unlock()
        if let cached, cached.0 == modified, cached.1 == size, cached.2["detail"] != "turn_active" { return cached.2 }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var offset = size, suffix = Data(), lifecycle: JSON = nil, user: JSON = nil, assistant: JSON = nil
        while offset > 0 && (lifecycle == .null || user == .null || assistant == .null) {
            let count = min(UInt64(512 * 1024), offset); offset -= count
            try handle.seek(toOffset: offset)
            var chunk = try handle.read(upToCount: Int(count)) ?? Data(); chunk.append(suffix)
            var lines = chunk.split(separator: 10, omittingEmptySubsequences: false)
            suffix = offset > 0 ? Data(lines.removeFirst()) : Data()
            if suffix.count > 16 * 1024 * 1024 { suffix = Data() }
            for line in lines.reversed() {
                let textLine = String(decoding: line, as: UTF8.self)
                guard textLine.contains("\"type\":\"task_") || textLine.contains("\"type\":\"turn_aborted\"") || textLine.contains("\"type\":\"message\"") else { continue }
                guard let entry = try? JSONDecoder().decode(JSON.self, from: Data(line)) else { continue }
                let payload = entry["payload"], kind = payload["type"].string
                if lifecycle == .null, entry["type"] == "event_msg", ["task_started", "task_complete", "turn_aborted"].contains(kind) { lifecycle = ["type": .string(kind), "timestamp": entry["timestamp"]] }
                guard entry["type"] == "response_item", kind == "message" else { continue }
                let role = payload["role"].string
                guard (role == "user" && user == .null) || (role == "assistant" && assistant == .null) else { continue }
                let blocks = payload["content"].array.filter { $0["type"].string == (role == "user" ? "input_text" : "output_text") }
                let text = role == "user" ? blocks.reversed().map { excerpt($0["text"].string, user: true) }.first(where: { !$0.isEmpty }) ?? "" : excerpt(blocks.map { $0["text"].string }.joined(separator: " "), user: false)
                guard !text.isEmpty else { continue }
                let value: JSON = ["text": .string(text), "timestamp": entry["timestamp"]]
                if role == "user" { user = value } else { assistant = value }
            }
        }
        var result: JSON = ["id": .string(id), "status": "idle", "detail": "no_completed_turn", "updatedAt": .string(RuntimeDate.iso(modified)), "latestUserExcerpt": user["text"], "latestCodexExcerpt": assistant["text"], "latestUserAt": user["timestamp"], "latestCodexAt": assistant["timestamp"]]
        switch lifecycle["type"].string {
        case "task_started": let fresh = Date().timeIntervalSince(modified) <= 1800; result["status"] = fresh ? "processing" : "idle"; result["detail"] = fresh ? "turn_active" : "turn_stale"
        case "task_complete": result["status"] = "completed"; result["detail"] = "turn_completed"; result["updatedAt"] = lifecycle["timestamp"].or(result["updatedAt"])
        case "turn_aborted": result["detail"] = "turn_aborted"
        default: break
        }
        lock.lock(); cache[url.path] = (modified, size, result); lock.unlock()
        return result
    }
}
