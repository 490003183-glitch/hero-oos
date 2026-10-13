import Foundation

extension StateRuntime {
    func require(_ state: JSON, _ collection: String, _ id: JSON, _ entity: String) throws -> Int {
        guard !id.string.isEmpty, let index = state[collection].array.firstIndex(where: { $0["id"] == id }) else { throw RuntimeError("\(entity)_not_found", "\(entity) 不存在：\(id.string)") }
        return index
    }
    func parentCanClose(_ state: JSON, _ id: JSON) throws {
        let children = state["tasks"].array.filter { $0["parentId"] == id && !["completed", "cancelled"].contains($0["status"].string) }
        if !children.isEmpty { throw RuntimeError("parent_has_open_children", "父任务仍有 \(children.count) 个开放子任务，不能关闭。", ["openChildren": .array(children)]) }
    }
    func validateGraph(_ state: JSON) throws {
        try validateTaskPages(state)
        let tasks = state["tasks"].array
        var byID: [String: JSON] = [:]
        for task in tasks {
            let id = task["id"].string
            guard !id.isEmpty, byID[id] == nil else { throw RuntimeError("duplicate_id", "任务 ID 缺失或重复。") }
            byID[id] = task
        }
        for task in tasks {
            let space = Record(task.object).taskSpace
            let links = [task["parentId"].string]
            for id in links where !id.isEmpty {
                if let linked = byID[id], Record(linked.object).taskSpace != space {
                    throw RuntimeError("cross_task_space", "父任务和子任务必须属于同一任务页。前置依赖可以跨页面。")
                }
            }
        }
        for dependency in [false, true] {
            var done = Set<String>()
            func edges(_ id: String) -> [String] {
                guard let task = byID[id] else { return [] }
                return dependency ? task["dependsOn"].array.map(\.string) : [task["parentId"].string].filter { !$0.isEmpty }
            }
            for id in byID.keys where !done.contains(id) {
                var visiting = Set<String>()
                var stack: [(String, Bool)] = [(id, false)]
                while let (current, exiting) = stack.popLast() {
                    if exiting { visiting.remove(current); done.insert(current); continue }
                    if visiting.contains(current) { throw RuntimeError("relationship_cycle", "检测到任务关系循环：\(current)") }
                    if done.contains(current) { continue }
                    guard byID[current] != nil else { throw RuntimeError(dependency ? "missing_dependency" : "missing_parent", "关联任务不存在：\(current)") }
                    visiting.insert(current); stack.append((current, true))
                    stack.append(contentsOf: edges(current).map { ($0, false) })
                }
            }
        }
    }
    func validateTaskFields(_ fields: JSON) throws {
        _ = try TaskPeopleWaits.normalized(fields)
        try TaskBackground.validate(fields["background"])
        if fields["availableAt"] != .null {
            guard case .string(let date) = fields["availableAt"], date.isEmpty || (date.contains("T") && RuntimeDate.parse(date) != nil) else {
                throw RuntimeError("invalid_available_time", "可开始时间必须是包含时区的有效日期时间，或清空此条件。")
            }
        }
        if fields["archived"] != .null, case .bool = fields["archived"] {} else if fields["archived"] != .null {
            throw RuntimeError("invalid_archive", "归档标记必须是布尔值。")
        }
        for key in ["boardOrder", "listOrder"] where fields[key] != .null {
            guard case .number(let value) = fields[key], value.isFinite else { throw RuntimeError("invalid_order", "排序值必须是有限数字。") }
        }
        if fields["taskSpace"] != .null, TaskSpace(rawValue: fields["taskSpace"].string) == nil {
            throw RuntimeError("invalid_task_space", "任务分区必须是内置分区或有效的自定义任务页。")
        }
        if fields.object.keys.contains("title") && fields["title"].trimmed.isEmpty { throw RuntimeError("invalid_task", "任务标题不能为空。") }
        for key in ["priority", "priorityBase"] where fields[key] != .null {
            guard case .number(let value) = fields[key], value >= 1, value <= 10 else { throw RuntimeError("invalid_priority", "优先级必须在 1–10 之间。") }
        }
        for key in ["deferCount", "effortHours", "amountTaxInclusive"] where fields[key] != .null {
            guard case .number(let value) = fields[key], value.isFinite, value >= 0 else { throw RuntimeError("invalid_number", "\(key) 必须是非负数字。") }
        }
        if fields["dependsOn"] != .null {
            guard case .array(let ids) = fields["dependsOn"], ids.allSatisfy({ !$0.string.isEmpty }) else { throw RuntimeError("invalid_dependencies", "dependsOn 必须是任务 ID 数组。") }
        }
    }
    func validateSchedule(_ block: JSON) throws {
        guard !block["title"].trimmed.isEmpty, let start = RuntimeDate.parse(block["start"].string), let end = RuntimeDate.parse(block["end"].string), end > start else { throw RuntimeError("invalid_schedule", "日程需要标题和有效的起止时间，结束必须晚于开始。") }
    }
    func risk(_ state: JSON, _ operations: [JSON]) -> JSON {
        var reasons: [JSON] = []
        for op in operations {
            switch op["type"].string {
            case "task.delete", "schedule.delete", "taskPage.delete": reasons.append("操作会删除规范实体")
            case "track.update" where !op["changes"]["name"].string.isEmpty || !op["changes"]["archetype"].string.isEmpty: reasons.append("操作会改变 Track 身份或进度模型")
            case "decision.record" where op["decision"]["sensitive"].bool: reasons.append("操作包含敏感决策记录")
            case "migration.importTasks": reasons.append(.string("操作会导入 \(op["tasks"].array.count) 条外部任务并建立新的实时事实源"))
            case "schedule.move":
                if let block = state["scheduleBlocks"].array.first(where: { $0["id"] == op["id"] }), let old = RuntimeDate.parse(block["start"].string), let new = RuntimeDate.parse(op["start"].string), abs(old.timeIntervalSince(new)) > 604800 { reasons.append(.string("日程「\(block["title"].string)」将跨越 7 天以上移动")) }
            default: break
            }
        }
        return ["level": reasons.isEmpty ? "normal" : "major", "reasons": .array(reasons)]
    }

    func applySingle(_ state: inout JSON, _ op: JSON, _ timestamp: JSON, _ mutationID: JSON, depth: Int = 0) throws -> (inverse: [JSON], affected: [JSON]) {
        guard depth < 64 else { throw RuntimeError("invalid_undo", "撤销嵌套异常。") }
        let type = op["type"].string
        let pieces = type.split(separator: ".").map(String.init)
        guard pieces.count == 2 else { throw RuntimeError("unsupported_operation", "不支持的操作：\(type)") }
        let entity = pieces[0], action = pieces[1]
        let collections = ["task": "tasks", "taskPage": "taskPages", "schedule": "scheduleBlocks", "track": "tracks", "metric": "metrics", "checkin": "checkins", "capture": "captures", "worker": "workerItems", "memory": "memories", "decision": "decisions"]
        let collection = collections[entity] ?? ""
        var inverse: [JSON] = [], affected: [JSON] = []
        func touch(_ id: JSON, entity override: String? = nil, track: JSON = .null) {
            var value: JSON = ["entity": .string(override ?? entity), "id": id]
            if track != .null { value["trackId"] = track }; affected.append(value)
        }
        func insert(_ value: JSON, inverseType: String, extra: [String: JSON] = [:]) throws {
            var list = state[collection].array
            guard !value["id"].string.isEmpty, !list.contains(where: { $0["id"] == value["id"] }) else { throw RuntimeError("duplicate_id", "\(entity) ID 缺失或已存在。") }
            list.append(value); state[collection] = .array(list)
            inverse.append(.object(extra.merging(["type": .string(inverseType), "id": value["id"], "internal": true]) { _, b in b }))
            touch(value["id"])
        }
        func update(_ changes: JSON, stamp: Bool = false) throws {
            let index = try require(state, collection, op["id"], entity)
            var list = state[collection].array, value = list[index], previous: JSON = [:]
            var removed: [JSON] = []
            var fields = changes.object; fields.removeValue(forKey: "id")
            if stamp { fields["updatedAt"] = timestamp }
            for (key, next) in fields {
                if value.object[key] == nil { removed.append(.string(key)) } else { previous[key] = value[key] }
                value[key] = next
            }
            for key in op["removeKeys"].array.map(\.string) where key != "id" {
                if value.object[key] != nil { previous[key] = value[key] }
                var object = value.object; object.removeValue(forKey: key); value = .object(object)
            }
            list[index] = value; state[collection] = .array(list)
            inverse.append(["type": .string("\(entity).update"), "id": op["id"], "changes": previous, "removeKeys": .array(removed), "internal": true]); touch(op["id"])
        }

        switch type {
        case "taskPage.create", "taskPage.restore":
            var page = op["taskPage"]
            if type == "taskPage.create" {
                if page["id"] == .null { page["id"] = .string("page-\(UUID().uuidString)") }
                page["title"] = .string(page["title"].trimmed)
                page["createdAt"] = timestamp
            }
            try validateTaskPage(page, in: state)
            try insert(page, inverseType: "taskPage.delete")
        case "taskPage.update":
            let index = try require(state, collection, op["id"], entity)
            var page = state[collection].array[index]
            // Page editing changes its label, never its identity or the tasks it contains.
            page["title"] = .string(op["changes"]["title"].trimmed)
            try validateTaskPage(page, in: state)
            try update(["title": page["title"]])
        case "taskPage.delete":
            let index = try require(state, collection, op["id"], entity)
            guard !state["tasks"].records.contains(where: { $0.taskSpace.rawValue == op["id"].string }) else {
                throw RuntimeError("task_page_not_empty", "任务页中还有任务（含归档记录），请先移出任务。")
            }
            var pages = state[collection].array
            let removed = pages.remove(at: index); state[collection] = .array(pages)
            inverse.append(["type": "taskPage.restore", "taskPage": removed, "internal": true]); touch(op["id"])
        case "task.create":
            var task = try TaskPeopleWaits.normalized(op["task"])
            if task["taskSpace"] == .null {
                let parent = state["tasks"].records.first { $0.id == task["parentId"].string }
                task["taskSpace"] = .string(parent?.taskSpace.rawValue ?? TaskSpace.work.rawValue)
            }
            try validateTaskFields(task)
            guard !task["title"].trimmed.isEmpty else { throw RuntimeError("invalid_task", "任务标题不能为空。") }
            if task["trackId"] != .null { _ = try require(state, "tracks", task["trackId"], "track") }
            let defaults: JSON = ["id": Self.id("task"), "trackId": nil, "status": "ready", "priority": 5, "priorityBase": task["priority"].or(5), "priorityOrigin": "system-default", "deferCount": 0, "stage": nil, "due": nil, "deadlineKind": nil, "reviewDate": nil, "effortHours": nil, "project": nil, "taskType": "task", "requester": nil, "managedBy": "Hero OOS", "waitingCondition": nil, "statusNote": "", "details": [], "externalCommitment": false, "parentId": nil, "dependsOn": [], "note": "", "source": "manual"]
            for (key, value) in defaults.object where task[key] == .null { task[key] = value }
            task["title"] = .string(task["title"].trimmed); task["createdAt"] = timestamp; task["updatedAt"] = timestamp
            try insert(task, inverseType: "task.delete")
        case "task.restore", "schedule.restore", "decision.restore":
            try insert(op[entity == "schedule" ? "block" : entity], inverseType: "\(entity).delete")
        case "task.update":
            let current = state["tasks"].records.first { $0.id == op["id"].string }
            let changes = op["internal"].bool ? op["changes"] : try TaskPeopleWaits.normalized(op["changes"], current: current)
            try validateTaskFields(changes)
            if op["changes"]["trackId"] != .null { _ = try require(state, "tracks", op["changes"]["trackId"], "track") }
            if ["completed", "cancelled"].contains(op["changes"]["status"].string) { try parentCanClose(state, op["id"]) }
            try update(changes, stamp: true)
        case "task.dependency":
            let index = try require(state, "tasks", op["id"], "task")
            _ = try require(state, "tasks", op["upstreamId"], "task")
            guard case .bool(let connected) = op["connected"] else { throw RuntimeError("invalid_dependency", "需要明确建立或解除依赖。") }
            var ids = state["tasks"].array[index]["dependsOn"].array
            ids.removeAll { $0 == op["upstreamId"] }
            if connected { ids.append(op["upstreamId"]) }
            try update(["dependsOn": .array(ids)], stamp: true)
        case "task.reorder":
            let index = try require(state, "tasks", op["id"], "task")
            let moved = Record(state["tasks"].array[index].object)
            let mode = op["mode"].string, placement = op["placement"].string
            guard ["board", "list"].contains(mode), ["first", "last", "before", "after"].contains(placement), !moved.isArchived else {
                throw RuntimeError("invalid_order", "排序位置或任务无效。")
            }
            let targetStatus = op["status"].or(.string(moved.status)).string
            if mode == "board" {
                guard ["ready", "active", "waiting", "review", "backlog", "blocked", "information", "paused", "completed", "cancelled"].contains(targetStatus) else {
                    throw RuntimeError("invalid_status", "目标状态无效。")
                }
                if ["completed", "cancelled"].contains(targetStatus) { try parentCanClose(state, op["id"]) }
            }
            let peers = state["tasks"].records.filter {
                !$0.isArchived && $0.taskSpace == moved.taskSpace && $0.id != moved.id &&
                (mode == "board" ? $0.status == targetStatus : $0.text("parentId") == moved.text("parentId"))
            }
            let seed = op["seedIds"].array.map(\.string)
            let fallback = peers.enumerated().sorted {
                (seed.firstIndex(of: $0.element.id) ?? (seed.count + $0.offset)) <
                (seed.firstIndex(of: $1.element.id) ?? (seed.count + $1.offset))
            }.map(\.element)
            var ordered = TaskOrdering.sorted(fallback, mode: mode)
            let insertion: Int
            if placement == "first" { insertion = 0 }
            else if placement == "last" { insertion = ordered.count }
            else {
                guard let anchor = ordered.firstIndex(where: { $0.id == op["anchorId"].string }) else {
                    throw RuntimeError("invalid_order", "只能在同一分区及同一层级或状态列内排序。")
                }
                insertion = anchor + (placement == "after" ? 1 : 0)
            }
            ordered.insert(moved, at: insertion)
            for (position, task) in ordered.enumerated() {
                var changes: JSON = [TaskOrdering.key(mode): .number(Double(position))]
                if task.id == moved.id && mode == "board" { changes["status"] = .string(targetStatus) }
                if changes.object.allSatisfy({ task[$0.key] == $0.value }) { continue }
                let applied = try applySingle(&state, ["type": "task.update", "id": .string(task.id), "changes": changes], timestamp, mutationID, depth: depth + 1)
                inverse.insert(contentsOf: applied.inverse, at: 0); affected += applied.affected
            }
        case "task.complete":
            try parentCanClose(state, op["id"])
            try update(["status": "completed", "completedAt": op["completedAt"].or(timestamp)], stamp: true)
        case "task.delete", "schedule.delete", "decision.delete", "metric.delete", "checkin.delete":
            let index = try require(state, collection, op["id"], entity)
            var list = state[collection].array; let removed = list.remove(at: index); state[collection] = .array(list)
            if ["metric", "checkin"].contains(entity) {
                var restore = removed; restore["type"] = .string("\(entity).record"); restore["internal"] = true; inverse.append(restore)
            } else { inverse.append(["type": .string("\(entity).restore"), entity == "schedule" ? "block" : entity: removed, "internal": true]) }
            touch(op["id"])
        case "schedule.create":
            var block = op["block"]; try validateSchedule(block)
            if block["taskId"] != .null { _ = try require(state, "tasks", block["taskId"], "task") }
            for (key, value) in (["id": Self.id("schedule"), "taskId": nil, "trackId": nil, "status": "scheduled"] as JSON).object where block[key] == .null { block[key] = value }
            block["title"] = .string(block["title"].trimmed); block["createdAt"] = timestamp; block["updatedAt"] = timestamp
            try insert(block, inverseType: "schedule.delete")
        case "schedule.move", "schedule.update", "schedule.complete":
            let index = try require(state, collection, op["id"], entity)
            let old = state[collection].array[index]
            var changes = op["changes"].or([:])
            if action == "complete" { changes = ["status": "completed", "completedAt": op["completedAt"].or(timestamp)] }
            if action == "move" {
                guard let oldStart = RuntimeDate.parse(old["start"].string), let oldEnd = RuntimeDate.parse(old["end"].string), let next = RuntimeDate.parse(op["start"].or(old["start"]).string) else { throw RuntimeError("invalid_date", "日程日期无效。") }
                changes = ["start": op["start"].or(old["start"]), "end": op["end"].or(.string(RuntimeDate.iso(next.addingTimeInterval(oldEnd.timeIntervalSince(oldStart)))))]
            }
            var candidate = old; for (key, value) in changes.object { candidate[key] = value }; try validateSchedule(candidate)
            try update(changes, stamp: true)
        case "track.update", "worker.update": try update(op["changes"])
        case "metric.record", "checkin.record":
            _ = try require(state, "tracks", op["trackId"], "track")
            var record: JSON = ["id": op["id"].or(Self.id(entity)), "trackId": op["trackId"], "date": op["date"].or(.string(String(timestamp.string.prefix(10)))), "note": op["note"].or(""), "createdAt": timestamp]
            if entity == "metric" {
                guard case .number = op["value"] else { throw RuntimeError("invalid_metric", "metric.record 需要有效数字。") }
                record["value"] = op["value"]; record["name"] = op["name"].or("metric"); record["unit"] = op["unit"].or(""); record["source"] = op["source"].or("manual")
            } else { record["value"] = op["value"].or(true) }
            try insert(record, inverseType: "\(entity).delete"); affected[0]["trackId"] = record["trackId"]
        case "capture.add":
            guard !op["text"].trimmed.isEmpty else { throw RuntimeError("invalid_capture", "Quick Capture 不能为空。") }
            let capture: JSON = ["id": op["id"].or(Self.id("capture")), "text": .string(op["text"].trimmed), "createdAt": timestamp, "status": "committed"]
            let worker: JSON = ["id": Self.id("worker"), "type": "capture.review", "captureId": capture["id"], "status": "pending", "createdAt": timestamp]
            try insert(capture, inverseType: "capture.delete", extra: ["workerItemId": worker["id"]])
            state["workerItems"] = .array(state["workerItems"].array + [worker]); touch(worker["id"], entity: "worker")
        case "capture.delete":
            let index = try require(state, collection, op["id"], entity)
            var list = state[collection].array; let removed = list.remove(at: index); state[collection] = .array(list)
            var workers = state["workerItems"].array; var worker: JSON = nil
            if let i = workers.firstIndex(where: { $0["id"] == op["workerItemId"] || $0["captureId"] == op["id"] }) { worker = workers.remove(at: i) }
            state["workerItems"] = .array(workers)
            inverse.append(["type": "capture.restore", "capture": removed, "workerItem": worker, "internal": true]); touch(op["id"])
        case "capture.restore":
            try insert(op["capture"], inverseType: "capture.delete", extra: ["workerItemId": op["workerItem"]["id"]])
            if op["workerItem"] != .null { state["workerItems"] = .array(state["workerItems"].array + [op["workerItem"]]) }
        case "worker.resolve": try update(["status": "resolved", "resolvedAt": timestamp, "resolution": op["resolution"].or("handled")])
        case "memory.observe":
            var memory = op["memory"]
            guard !memory["text"].trimmed.isEmpty else { throw RuntimeError("invalid_memory", "memory.observe 需要文本。") }
            let defaults: JSON = ["id": Self.id("memory"), "type": memory["kind"].or("observation"), "evidence": [], "relatedTrackIds": [], "confidence": 1, "sensitive": false]
            for (key, value) in defaults.object where memory[key] == .null { memory[key] = value }
            memory["createdAt"] = timestamp; memory["status"] = "active"
            try insert(memory, inverseType: "memory.forget")
        case "memory.correct", "memory.forget", "memory.replace", "decision.replace", "decision.review", "decision.outcome":
            let index = try require(state, collection, op["id"], entity)
            var list = state[collection].array; let old = list[index]; var value = old
            switch action {
            case "replace": value = op[entity]
            case "correct": for (key, next) in op["changes"].object where key != "id" { value[key] = next }; value["correctedAt"] = timestamp
            case "forget": value["status"] = "forgotten"; value["forgottenAt"] = timestamp
            case "review": value["lastReviewedAt"] = timestamp; value["reviewNote"] = op["note"].or("")
            default: value["outcome"] = op["outcome"]; value["outcomeAt"] = timestamp
            }
            value["id"] = old["id"]; list[index] = value; state[collection] = .array(list)
            inverse.append(["type": .string("\(entity).replace"), "id": op["id"], entity: old, "internal": true]); touch(op["id"])
        case "memory.update": try update(op["changes"])
        case "decision.record":
            var decision = op["decision"]
            guard !decision["title"].trimmed.isEmpty else { throw RuntimeError("invalid_decision", "decision.record 需要标题。") }
            let defaults: JSON = ["id": Self.id("decision"), "outcome": nil, "sensitive": false, "evidence": [], "relatedTrackIds": []]
            for (key, value) in defaults.object where decision[key] == .null { decision[key] = value }
            decision["status"] = "active"; decision["createdAt"] = timestamp
            try insert(decision, inverseType: "decision.delete")
        case "onboarding.step", "onboarding.replace":
            let old = state["onboarding"]
            if action == "replace" { state["onboarding"] = op["onboarding"] }
            else {
                guard !op["step"].trimmed.isEmpty else { throw RuntimeError("invalid_onboarding_step", "onboarding.step 需要 step。") }
                let step = JSON.string(op["step"].trimmed)
                var steps = state["onboarding"]["completedSteps"].array
                if !steps.contains(step) { steps.append(step) }
                state["onboarding"]["completedSteps"] = .array(steps)
                if op["status"] != .null { state["onboarding"]["firstFlight"] = op["status"] }
            }
            inverse.append(["type": "onboarding.replace", "onboarding": old, "internal": true]); touch(op["step"].or("firstFlight"))
        case "migration.importTasks":
            let tasks = op["tasks"].array
            guard !tasks.isEmpty else { throw RuntimeError("invalid_migration", "需要非空 tasks 数组。") }
            let id = op["migration"]["id"].or(Self.id("migration"))
            guard !state["migrations"].array.contains(where: { $0["id"] == id }) else { throw RuntimeError("duplicate_migration", "迁移记录已存在。") }
            for var task in tasks {
                guard !task["id"].string.isEmpty, !task["title"].trimmed.isEmpty else { throw RuntimeError("invalid_migration_task", "迁移任务必须包含 id 与 title。") }
                if task["trackId"] != .null { _ = try require(state, "tracks", task["trackId"], "track") }
                guard !state["tasks"].array.contains(where: { $0["id"] == task["id"] }) else { throw RuntimeError("duplicate_id", "任务 ID 重复。") }
                task["title"] = .string(task["title"].trimmed); task["createdAt"] = task["createdAt"].or(timestamp); task["updatedAt"] = task["updatedAt"].or(timestamp)
                state["tasks"] = .array(state["tasks"].array + [task]); touch(task["id"], entity: "task")
            }
            var migration = op["migration"].or([:]); migration["id"] = id; migration["sourceSystem"] = migration["sourceSystem"].or("external")
            for key in ["sourcePath", "sourceHash", "sourceSchemaVersion"] { migration[key] = migration[key] }
            migration["importedAt"] = timestamp; migration["importedCount"] = .number(Double(tasks.count)); migration["importedIds"] = .array(tasks.map { $0["id"] }); migration["cutover"] = migration["cutover"].or(false); migration["notes"] = migration["notes"].or("")
            state["migrations"] = .array(state["migrations"].array + [migration]); touch(id)
            inverse.append(["type": "migration.remove", "id": id, "importedIds": migration["importedIds"], "internal": true])
        case "migration.remove":
            let index = try require(state, "migrations", op["id"], "migration")
            var migrations = state["migrations"].array; let removed = migrations.remove(at: index); state["migrations"] = .array(migrations)
            let ids = op["importedIds"].or(removed["importedIds"]).array
            let tasks = state["tasks"].array.filter { ids.contains($0["id"]) }
            state["tasks"] = .array(state["tasks"].array.filter { !ids.contains($0["id"]) })
            inverse.append(["type": "migration.importTasks", "tasks": .array(tasks), "migration": removed, "internal": true])
            for task in tasks { touch(task["id"], entity: "task") }; touch(op["id"])
        case "receipt.undo":
            let index = try require(state, "receipts", op["receiptId"], "receipt")
            let receipt = state["receipts"].array[index]
            guard receipt["undoneAt"] == .null else { throw RuntimeError("already_undone", "该回执已经撤销。") }
            let keys = Set(receipt["affected"].array.map { "\($0["entity"].string):\($0["id"].string)" })
            let later = state["receipts"].array.filter { $0["version"].number > receipt["version"].number }
            guard !later.contains(where: { $0["affected"].array.contains { keys.contains("\($0["entity"].string):\($0["id"].string)") } }) else { throw RuntimeError("undo_conflict", "后续已有修改，不能撤销并覆盖其他端的更新。") }
            for undo in receipt["inverseOps"].array {
                let result = try applySingle(&state, undo, timestamp, mutationID, depth: depth + 1)
                inverse.insert(contentsOf: result.inverse, at: 0); affected.append(contentsOf: result.affected)
            }
            var receipts = state["receipts"].array; receipts[index]["undoneAt"] = timestamp; receipts[index]["undoneBy"] = mutationID; state["receipts"] = .array(receipts); touch(receipt["id"])
        default: throw RuntimeError("unsupported_operation", "不支持的操作：\(type)")
        }
        return (inverse, affected)
    }
}
