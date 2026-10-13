import Foundation

extension StateRuntime {
    public func initializeIfNeeded() throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try locked {
            guard !FileManager.default.fileExists(atPath: file("state.json").path) else { return }
            let state: JSON = ["meta": ["version": 1, "instanceId": .string(UUID().uuidString)],
                "tasks": [], "tracks": [], "taskPages": [], "scheduleBlocks": [], "metrics": [], "checkins": [],
                "captures": [], "workerItems": [], "memories": [], "decisions": [], "receipts": [], "migrations": [],
                "currentTruth": ["horizonHours": 72], "onboarding": ["completedSteps": [], "firstFlight": "active"]]
            try writeJSON(state, to: file("state.json"))
        }
    }

    /// Task-system data only. Device journals, Codex live status and collage assets are not uploaded.
    public static func cloudProjection(_ state: JSON) -> JSON {
        var object = state.object
        for key in ["meta", "receipts", "migrations"] { object.removeValue(forKey: key) }
        if var truth = object["currentTruth"]?.object { truth.removeValue(forKey: "lastBuiltAt"); object["currentTruth"] = .object(truth) }
        for key in ["tasks", "tracks", "taskPages", "scheduleBlocks", "metrics", "checkins", "captures", "workerItems", "memories", "decisions"] {
            if case .array(let entities) = object[key] {
                object[key] = .array(entities.map { entity in
                    var value = entity.object; value.removeValue(forKey: "updatedAt"); return .object(value)
                })
            }
        }
        return .object(object)
    }
    public func cloudState() throws -> JSON { Self.cloudProjection(try readState()) }

    public func validateCloudState(_ incoming: JSON) throws {
        guard case .object = incoming, case .array = incoming["tasks"], incoming["meta"] == .null,
              incoming["receipts"] == .null, incoming["migrations"] == .null else {
            throw RuntimeError("cloud_document_invalid", "云端任务格式不兼容，本机内容未更改。")
        }
        for key in ["tasks", "tracks", "taskPages", "scheduleBlocks", "metrics", "checkins", "captures", "workerItems", "memories", "decisions"] {
            if incoming[key] == .null { continue }
            guard case .array(let entities) = incoming[key], entities.count <= 100_000 else {
                throw RuntimeError("cloud_document_invalid", "云端集合格式不兼容。")
            }
            var ids = Set<String>()
            for entity in entities {
                guard case .object = entity, !entity["id"].string.isEmpty, ids.insert(entity["id"].string).inserted else {
                    throw RuntimeError("cloud_document_invalid", "云端实体标识缺失或重复。")
                }
            }
        }
        for task in incoming["tasks"].array { try validateTaskFields(task) }
        try validateGraph(incoming)
        let graph = TaskDependencies(incoming["tasks"].records)
        for task in incoming["tasks"].records {
            if task["dependsOn"].array.contains(where: { !graph.canDepend(task.id, on: $0.string) }) ||
                (!task.text("parentId").isEmpty && !graph.canParent(task.id, under: task.text("parentId"))) {
                throw RuntimeError("relationship_cycle", "跨设备合并形成依赖循环，已停止同步并保留两端内容。")
            }
        }
    }

    /// CAS plus the existing crash-recovery journal; never overwrite a concurrent local edit.
    @discardableResult public func applyCloudState(_ incoming: JSON, expected: JSON) throws -> JSON {
        try validateCloudState(incoming)
        return try locked {
            let current = try readJSON(file("state.json"))
            guard Self.cloudProjection(current) == expected else {
                throw RuntimeError("cloud_local_conflict", "同步期间本机有新编辑，已保留编辑并等待重新合并。")
            }
            if incoming == expected { return current }
            // Keep full local recovery evidence, including old undo receipts, outside the live undo stack.
            let directory = file("cloud-history")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeJSON(current, to: directory.appendingPathComponent("before-\(Int(current["meta"]["version"].number))-\(UUID().uuidString).json"))
            var next = incoming
            next["meta"] = current["meta"]
            next["meta"]["version"] = .number(current["meta"]["version"].number + 1)
            next["meta"]["updatedAt"] = .string(RuntimeDate.iso())
            next["migrations"] = current["migrations"].or([])
            next["receipts"] = [] // Old inverse operations must not undo someone else's new cloud changes.
            let event: JSON = ["version": next["meta"]["version"], "timestamp": next["meta"]["updatedAt"],
                "mutationId": .string("cloud-\(UUID().uuidString)"), "affected": [], "source": "private-cloud"]
            try writeJSON(["previousVersion": current["meta"]["version"], "state": next, "event": event], to: file(".pending-transaction.json"))
            try recoverTransaction()
            return next
        }
    }
}

public enum CloudStateMerge {
    public static func merge(base: JSON, local: JSON, remote: JSON) throws -> JSON {
        try value(base, local, remote, path: "state", depth: 0) ?? .null
    }
    private static func conflict(_ path: String) -> RuntimeError {
        RuntimeError("cloud_merge_conflict", "两台设备修改了同一内容（\(path)）。同步已暂停，两端内容都已保留。")
    }
    private static func value(_ base: JSON?, _ local: JSON?, _ remote: JSON?, path: String, depth: Int) throws -> JSON? {
        guard depth < 64 else { throw conflict(path) }
        if local == base { return remote }
        if remote == base || local == remote { return local }
        switch (base, local, remote) {
        case let (.some(.object(b)), .some(.object(l)), .some(.object(r))):
            var output: [String: JSON] = [:]
            for key in Set(b.keys).union(l.keys).union(r.keys) {
                output[key] = try value(b[key], l[key], r[key], path: path + "." + key, depth: depth + 1)
            }
            return .object(output)
        case let (.some(.array(b)), .some(.array(l)), .some(.array(r))):
            func indexed(_ items: [JSON]) throws -> [String: JSON] {
                var output: [String: JSON] = [:]
                for item in items {
                    let id = item["id"].string
                    guard !id.isEmpty, output[id] == nil else { throw conflict(path) }
                    output[id] = item
                }
                return output
            }
            let bm = try indexed(b), lm = try indexed(l), rm = try indexed(r)
            var result: [JSON] = [], seen = Set<String>()
            for item in r + l + b {
                let id = item["id"].string
                guard seen.insert(id).inserted else { continue }
                if let merged = try value(bm[id], lm[id], rm[id], path: path + "[" + id + "]", depth: depth + 1) { result.append(merged) }
            }
            return .array(result)
        default: throw conflict(path)
        }
    }
}
