import Foundation

extension StateRuntime {
    public func mutate(_ payload: JSON) throws -> JSON {
        let expected = payload["expectedVersion"]
        guard case .number(let version) = expected, version.isFinite, version.rounded() == version, version >= 0 else { throw RuntimeError("expected_version_required", "每次写操作都需要 expectedVersion。") }
        let mutation = payload["clientMutationId"]
        guard !mutation.trimmed.isEmpty else { throw RuntimeError("mutation_id_required", "每次写操作都需要唯一 clientMutationId。") }
        var source = payload["operations"].or(payload["ops"])
        if case .object = source { source = source["ops"].or(source["operations"]) }
        guard case .array(let ops) = source, !ops.isEmpty else { throw RuntimeError("invalid_operations", "需要非空 ops/operations 数组。") }
        return try locked {
            var state = try readJSON(file("state.json"))
            if let receipt = state["receipts"].array.first(where: { $0["clientMutationId"] == mutation }) {
                guard receipt["operations"] == .array(ops) else { throw RuntimeError("mutation_id_reused", "同一 mutation id 不得用于不同操作。") }
                return ["ok": true, "duplicate": true, "version": state["meta"]["version"], "receipt": receipt, "state": state]
            }
            guard state["meta"]["version"] == expected else { throw RuntimeError("state_conflict", "状态版本冲突：期望 \(Int(version))，当前 \(Int(state["meta"]["version"].number))。", ["currentVersion": state["meta"]["version"]]) }
            let risk = risk(state, ops)
            guard risk["level"] != "major" || payload["confirmedMajor"].bool else { throw RuntimeError("confirmation_required", "这是重大状态变更，需要明确确认。", ["risk": risk]) }
            let beforeTasks = state["tasks"].records
            let beforeHash = try Self.hash(state), timestamp = JSON.string(RuntimeDate.iso())
            var inverse: [JSON] = [], affected: [JSON] = []
            for op in ops {
                let result = try applySingle(&state, op, timestamp, mutation)
                inverse.insert(contentsOf: result.inverse, at: 0); affected.append(contentsOf: result.affected)
            }
            try validateGraph(state)
            let afterTasks = state["tasks"].records
            let graph = TaskDependencies(afterTasks)
            let beforeByID = Dictionary(beforeTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Validate new edges, so legacy mixed deadlocks can be repaired one at a time.
            for task in afterTasks {
                let prior = beforeByID[task.id]
                let added = Set(task["dependsOn"].array.map(\.string)).subtracting(prior?["dependsOn"].array.map(\.string) ?? [])
                let changedParent = !task.text("parentId").isEmpty && task.text("parentId") != prior?.text("parentId")
                if added.contains(where: { !graph.canDepend(task.id, on: $0) }) || (changedParent && !graph.canParent(task.id, under: task.text("parentId"))) {
                    throw RuntimeError("relationship_cycle", "「\(task.title)」形成循环依赖（含父任务等待子任务完成），请解除其中一条关系。")
                }
            }
            for task in afterTasks where task.status == "active" && beforeByID[task.id]?.status != "active" {
                if let date = TaskDependencies.availableDate(task), date > Date() { throw RuntimeError("time_condition_pending", "「\(task.title)」还不能开始。\(graph.blocked(task) ?? "尚未到可开始时间")") }
                if let reason = graph.blocked(task) { throw RuntimeError("dependency_incomplete", "「\(task.title)」还不能开始。\(reason)") }
            }
            state["meta"]["version"] = .number(version + 1); state["meta"]["updatedAt"] = timestamp; state["currentTruth"]["lastBuiltAt"] = timestamp
            var receipt: JSON = ["id": Self.id("receipt"), "clientMutationId": mutation, "previousVersion": expected, "version": .number(version + 1), "timestamp": timestamp, "operations": .array(ops), "inverseOps": .array(inverse), "affected": .array(affected), "risk": risk, "beforeHash": .string(beforeHash), "hashFormat": "swift-json-sorted-v1"]
            state["receipts"] = .array(Array((state["receipts"].array + [receipt]).suffix(200)))
            receipt["afterHash"] = .string(try Self.hash(state))
            var receipts = state["receipts"].array; receipts[receipts.count - 1] = receipt; state["receipts"] = .array(receipts)
            let event: JSON = ["version": .number(version + 1), "timestamp": timestamp, "mutationId": mutation, "receiptId": receipt["id"], "affected": .array(affected)]
            try writeJSON(["previousVersion": expected, "state": state, "event": event], to: file(".pending-transaction.json"))
            try recoverTransaction()
            return ["ok": true, "version": .number(version + 1), "receipt": receipt, "state": state]
        }
    }
    public func changes(consumer: String) throws -> JSON {
        guard !consumer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeError("consumer_required", "需要稳定 consumer id。") }
        return try locked {
            let state = try readJSON(file("state.json")), consumers = try readJSON(file("consumers.json"), fallback: [:])
            let ack = consumers[consumer]["version"].number
            let raw: Data
            if FileManager.default.fileExists(atPath: file("changes.jsonl").path) { raw = try Data(contentsOf: file("changes.jsonl")) } else { raw = Data() }
            let changes = try raw.split(separator: 10).map { try JSONDecoder().decode(JSON.self, from: Data($0)) }.filter { $0["version"].number > ack }
            let earliest = changes.first?["version"].number ?? state["meta"]["version"].number
            return ["consumer": .string(consumer), "acknowledgedVersion": .number(ack), "currentVersion": state["meta"]["version"], "resyncRequired": .bool(ack > 0 && earliest > ack + 1), "changes": .array(changes)]
        }
    }
    public func acknowledge(consumer: String, version: Double) throws -> JSON {
        guard !consumer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeError("consumer_required", "需要稳定 consumer id。") }
        return try locked {
            let state = try readJSON(file("state.json"))
            guard version.isFinite, version.rounded() == version, version >= 0, version <= state["meta"]["version"].number else { throw RuntimeError("invalid_ack_version", "确认版本无效。") }
            var consumers = try readJSON(file("consumers.json"), fallback: [:])
            guard version >= consumers[consumer]["version"].number else { throw RuntimeError("invalid_ack_version", "确认版本不能倒退。") }
            let value: JSON = ["version": .number(version), "acknowledgedAt": .string(RuntimeDate.iso())]
            consumers[consumer] = value; try writeJSON(consumers, to: file("consumers.json")); return value
        }
    }
    public func attention(_ state: JSON, at: Date = Date()) -> [JSON] {
        let horizon = at.addingTimeInterval(state["currentTruth"]["horizonHours"].or(72).number * 3600)
        var result: [JSON] = []
        let graph = TaskDependencies(state["tasks"].records)
        for task in state["tasks"].array {
            let status = task["status"].string
            if ["completed", "cancelled", "information", "backlog", "paused"].contains(status) { continue }
            if status == "ready", graph.blocked(Record(task.object), at: at) != nil { continue }
            if status != "active", let date = TaskDependencies.availableDate(Record(task.object)), date > at { continue }
            var type = "", due = task["due"]
            if status == "review" { type = "review"; due = task["reviewDate"] }
            else if status == "waiting", let review = RuntimeDate.parse(task["reviewDate"].string), review <= horizon { type = "waiting-review"; due = task["reviewDate"] }
            else if !["waiting", "blocked"].contains(status), let date = RuntimeDate.parse(due.string), date <= horizon { type = "due" }
            else if ["active", "ready"].contains(status) { type = status }
            if !type.isEmpty { result.append(["type": .string(type), "id": task["id"], "title": task["title"], "due": due]) }
        }
        result.append(contentsOf: state["workerItems"].array.filter { $0["status"] == "pending" }.map { ["type": "worker-review", "id": $0["id"], "title": "Quick Capture 待判断", "due": nil] as JSON })
        return result
    }
    public func currentTruth(_ state: JSON, at: Date = Date()) -> String {
        let hours = state["currentTruth"]["horizonHours"].or(72).number
        let horizon = at.addingTimeInterval(hours * 3600)
        let schedules = state["scheduleBlocks"].array.filter {
            guard $0["status"] != "completed", let date = RuntimeDate.parse($0["start"].string) else { return false }
            return date >= at.addingTimeInterval(-3600) && date <= horizon
        }.sorted { $0["start"].string < $1["start"].string }
        let ids = Set(attention(state, at: at).filter { $0["type"] != "worker-review" }.map { $0["id"].string })
        let ranks = ["active": 4, "ready": 3, "review": 2, "waiting": 1]
        let tasks = state["tasks"].array.filter { ids.contains($0["id"].string) }.sorted {
            let a = ranks[$0["status"].string] ?? 0, b = ranks[$1["status"].string] ?? 0
            return a == b ? $0["priority"].number > $1["priority"].number : a > b
        }
        let workers = state["workerItems"].array.filter { $0["status"] == "pending" }
        var lines = ["# Current Truth", "", "> 自动生成于 \(RuntimeDate.iso(at))｜窗口：未来 \(Int(hours)) 小时｜State v\(Int(state["meta"]["version"].number))", "", "## 近期日程", ""]
        lines += schedules.isEmpty ? ["- 暂无已安排日程。"] : schedules.map { "- \($0["start"].string) — \($0["end"].string)｜\($0["title"].string)" }
        lines += ["", "## 当前可执行", ""]
        lines += tasks.isEmpty ? ["- 暂无进入 \(Int(hours)) 小时窗口的任务。"] : tasks.map { task in
            var context = ""
            if task["status"] == "waiting" {
                if task["waitingCondition"] != .null { context += "｜等待 \(task["waitingCondition"].string)" }
                if task["reviewDate"] != .null { context += "｜复查 \(task["reviewDate"].string)" }
            } else if task["status"] == "review" { context = "｜待关闭复核" }
            else if task["due"] != .null { context = "｜截止 \(task["due"].string)" }
            return "- [\(task["status"].string)] P\(Int(task["priority"].or(5).number))｜\(task["title"].string)\(context)"
        }
        lines += ["", "## 待判断", ""]
        lines += workers.isEmpty ? ["- 暂无 Worker 待审项。"] : workers.map { "- \($0["type"].string)｜\($0["id"].string)" }
        lines += ["", "## 边界", "", "- 本文件由 Swift State Runtime 重建，请勿手工维护。", "- 事务更改请使用 Hero OOS 或带版本校验的 CLI。", ""]
        return lines.joined(separator: "\n")
    }
}
