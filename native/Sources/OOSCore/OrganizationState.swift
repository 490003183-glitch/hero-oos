import Foundation

/// A deliberately small wire contract. A new local field is private until explicitly added here.
/// Keep these sets in sync with the server's organization document validator.
public enum OrganizationStateSchema {
    public static let taskStringFields: Set<String> = [
        "id", "title", "taskSpace", "status", "priorityOrigin", "stage", "due", "deadlineKind",
        "reviewDate", "project", "taskType", "requester", "managedBy", "waitingCondition", "statusNote",
        "parentId", "note", "notes", "background", "createdAt", "completedAt", "archivedAt", "availableAt", "blockedBy",
        "trackId", "ledgerID", "startDate", "mustExecuteAt", "subcategory", "nextAction", "client", "contact",
        "executor", "deliveryStatus", "invoiceStatus", "sourceChannelOwner", "currentChannelOwner", "recordType",
        "paymentStatus", "currency", "taxBasis", "settlementContact", "completionMode", "nodeKind", "outcome", "receivedDate"
    ]
    public static let taskNumberFields: Set<String> = [
        "priority", "priorityBase", "deferCount", "effortHours", "amountTaxInclusive", "boardOrder", "listOrder",
        "feeAmount", "progressPercent"
    ]
    public static let taskBooleanFields: Set<String> = ["archived", "externalCommitment", "ledgerEnabled"]
    public static let taskArrayFields: Set<String> = ["details", "dependsOn", "peopleWaits"]
    public static let taskFields = taskStringFields.union(taskNumberFields).union(taskBooleanFields).union(taskArrayFields)
    public static let trackStringFields: Set<String> = ["id", "name", "navLabel", "archetype", "status", "createdAt"]
    public static let trackFields = trackStringFields.union(["stages"])
    public static let pageFields: Set<String> = ["id", "title", "createdAt"]
    public static let peopleWaitFields: Set<String> = ["id", "person", "outcome", "resolved"]

    static func scalarProjection(_ entity: JSON, strings: Set<String>, numbers: Set<String> = [], booleans: Set<String> = []) -> JSON {
        var output: [String: JSON] = [:]
        for (key, value) in entity.object {
            switch value {
            case .null where strings.contains(key) || numbers.contains(key) || booleans.contains(key): output[key] = value
            case .string where strings.contains(key): output[key] = value
            case .number(let number) where numbers.contains(key) && number.isFinite: output[key] = value
            case .bool where booleans.contains(key): output[key] = value
            default: break
            }
        }
        return .object(output)
    }
}

extension StateRuntime {
    /// Only non-private task management information belongs to the organization. Codex references,
    /// collage data, local paths, provenance and unrelated collections never enter this projection.
    public static func organizationProjection(_ state: JSON) -> JSON {
        taskScopeProjection(state, personal: false)
    }

    static func taskScopeProjection(_ state: JSON, personal: Bool) -> JSON {
        let tasks = state["tasks"].array.filter { ($0["taskSpace"].string == TaskSpace.personal.rawValue) == personal }
        let ids = Set(tasks.map { $0["id"].string })
        let trackIDs = Set(tasks.map { $0["trackId"].string }.filter { !$0.isEmpty })
        let pages = Set(tasks.map { $0["taskSpace"].string }.filter { $0.hasPrefix("page-") })
        let tracks = state["tracks"].array.filter { trackIDs.contains($0["id"].string) }.sorted { $0["id"].string < $1["id"].string }.map { track -> JSON in
            var result = OrganizationStateSchema.scalarProjection(track, strings: OrganizationStateSchema.trackStringFields)
            if case .array(let stages) = track["stages"] {
                result["stages"] = .array(stages.filter { if case .string = $0 { return true }; return false })
            }
            return result
        }
        let projectedTasks = tasks.map { task -> JSON in
            var result = OrganizationStateSchema.scalarProjection(task, strings: OrganizationStateSchema.taskStringFields,
                numbers: OrganizationStateSchema.taskNumberFields, booleans: OrganizationStateSchema.taskBooleanFields)
            result["taskSpace"] = .string(Record(task.object).taskSpace.rawValue)
            if case .array(let details) = task["details"] {
                result["details"] = .array(details.filter { if case .string = $0 { return true }; return false })
            }
            if case .array(let dependencies) = task["dependsOn"] {
                result["dependsOn"] = .array(dependencies.filter { ids.contains($0.string) && !$0.string.isEmpty })
            }
            if !task["parentId"].string.isEmpty && !ids.contains(task["parentId"].string) { result["parentId"] = .null }
            if case .array(let waits) = task["peopleWaits"] {
                result["peopleWaits"] = .array(waits.map {
                    OrganizationStateSchema.scalarProjection($0, strings: ["id", "person", "outcome"], booleans: ["resolved"])
                })
            }
            return result
        }
        return ["tasks": .array(projectedTasks), "tracks": .array(tracks),
                "taskPages": .array(state["taskPages"].array.filter { pages.contains($0["id"].string) }.sorted { $0["id"].string < $1["id"].string }.map {
                    OrganizationStateSchema.scalarProjection($0, strings: OrganizationStateSchema.pageFields)
                })]
    }

    public func organizationState() throws -> JSON { Self.organizationProjection(try readState()) }

    public func validateOrganizationState(_ incoming: JSON) throws {
        try validateTaskScopeState(incoming, personal: false)
    }

    func validateTaskScopeState(_ incoming: JSON, personal: Bool) throws {
        func invalid(_ message: String = "任务同步格式不兼容，本机内容未更改。") -> RuntimeError {
            RuntimeError(personal ? "personal_document_invalid" : "organization_document_invalid", message)
        }
        guard case .object = incoming, Set(incoming.object.keys) == Set(["tasks", "tracks", "taskPages"]),
              try incoming.encoded().count <= 8 * 1024 * 1024 else { throw invalid() }
        func scalarFields(_ entity: JSON, strings: Set<String>, numbers: Set<String> = [], booleans: Set<String> = [], arrays: Set<String> = []) throws {
            guard case .object = entity, Set(entity.object.keys).isSubset(of: strings.union(numbers).union(booleans).union(arrays)) else { throw invalid() }
            for (key, value) in entity.object where !arrays.contains(key) {
                switch value {
                case .null: continue
                case .string(let text) where strings.contains(key) && text.count <= 16_000: continue
                case .number(let number) where numbers.contains(key) && number.isFinite: continue
                case .bool where booleans.contains(key): continue
                default: throw invalid()
                }
            }
        }
        func stringArray(_ value: JSON, nonempty: Bool = false) throws {
            guard case .array(let values) = value, values.count <= 100_000, values.allSatisfy({ item in
                if case .string(let text) = item { return text.count <= 16_000 && (!nonempty || !text.isEmpty) }; return false
            }) else { throw invalid() }
        }
        for collection in ["tasks", "tracks", "taskPages"] {
            guard case .array(let entities) = incoming[collection], entities.count <= 100_000 else { throw invalid() }
            var ids = Set<String>()
            for entity in entities {
                let id = entity["id"].string
                guard !id.isEmpty, id.count <= 160, ids.insert(id).inserted else { throw invalid() }
                switch collection {
                case "tasks":
                    try scalarFields(entity, strings: OrganizationStateSchema.taskStringFields,
                        numbers: OrganizationStateSchema.taskNumberFields, booleans: OrganizationStateSchema.taskBooleanFields,
                        arrays: OrganizationStateSchema.taskArrayFields)
                    guard !entity["title"].trimmed.isEmpty, entity["title"].string.count <= 400,
                          let space = TaskSpace(rawValue: entity["taskSpace"].string), (space == .personal) == personal else { throw invalid() }
                    for key in ["details", "dependsOn"] where entity.object[key] != nil { try stringArray(entity[key], nonempty: key == "dependsOn") }
                    if let waits = entity.object["peopleWaits"] {
                        guard case .array(let entries) = waits, entries.count <= 100_000 else { throw invalid() }
                        for wait in entries {
                            guard Set(wait.object.keys) == OrganizationStateSchema.peopleWaitFields,
                                  wait["id"].string.count <= 160 else { throw invalid() }
                            try scalarFields(wait, strings: ["id", "person", "outcome"], booleans: ["resolved"])
                        }
                    }
                    try validateTaskFields(entity)
                case "tracks":
                    try scalarFields(entity, strings: OrganizationStateSchema.trackStringFields, arrays: ["stages"])
                    guard entity["name"].string.count <= 400 else { throw invalid() }
                    if let stages = entity.object["stages"] { try stringArray(stages) }
                default:
                    try scalarFields(entity, strings: OrganizationStateSchema.pageFields)
                }
            }
        }
        let tracks = Set(incoming["tracks"].array.map { $0["id"].string })
        let referencedTracks = Set(incoming["tasks"].array.map { $0["trackId"].string }.filter { !$0.isEmpty })
        let pages = Set(incoming["taskPages"].array.map { $0["id"].string })
        let referencedPages = Set(incoming["tasks"].array.map { $0["taskSpace"].string }.filter { $0.hasPrefix("page-") })
        guard tracks == referencedTracks, pages == referencedPages else {
            throw invalid("同步文档只能包含任务引用的板块和页面，本机内容未更改。")
        }
        for task in incoming["tasks"].array where !task["trackId"].string.isEmpty {
            guard tracks.contains(task["trackId"].string) else { throw invalid("任务引用的组织板块不存在，本机内容未更改。") }
        }
        try validateGraph(incoming)
    }

    /// One local track can be used by both task spaces. Neither cloud may silently rename or
    /// otherwise rewrite the other scope's definition through that shared ID.
    func validateOppositeScopeTracks(_ incoming: JSON, current: JSON, personal: Bool) throws {
        let opposite = Self.taskScopeProjection(current, personal: !personal)
        let oppositeTracks = Dictionary(uniqueKeysWithValues: opposite["tracks"].array.map { ($0["id"].string, $0) })
        for track in incoming["tracks"].array {
            if let existing = oppositeTracks[track["id"].string], existing != track {
                throw RuntimeError("cloud_shared_track_conflict", "此板块同时被组织任务与私人任务使用，两端板块信息不一致。同步已暂停，未修改另一空间。")
            }
        }
    }

    /// CAS compares only the shared projection. A private/Codex/collage edit is never overwritten
    /// and does not spuriously conflict with an independent organization update.
    @discardableResult public func applyOrganizationState(_ incoming: JSON, expected: JSON) throws -> JSON {
        try validateOrganizationState(incoming)
        return try locked {
            let current = try readJSON(file("state.json"))
            guard Self.organizationProjection(current) == expected else {
                throw RuntimeError("cloud_local_conflict", "同步期间组织任务有新编辑，已保留编辑并等待重新合并。")
            }
            if incoming == expected { return current }
            try validateOppositeScopeTracks(incoming, current: current, personal: false)
            let privateTasks = current["tasks"].array.filter { $0["taskSpace"].string == TaskSpace.personal.rawValue }
            let privateIDs = Set(privateTasks.map { $0["id"].string })
            guard !incoming["tasks"].array.contains(where: { privateIDs.contains($0["id"].string) }) else {
                throw RuntimeError("organization_private_id_conflict", "组织任务标识与本机私人任务冲突，已停止同步，私人内容未更改。")
            }
            let oldTasks = Dictionary(uniqueKeysWithValues: current["tasks"].array.map { ($0["id"].string, $0) })
            func overlay(_ shared: JSON, local: JSON?, fields: Set<String>) -> JSON {
                var result = local?.object ?? [:]
                for key in fields { result.removeValue(forKey: key) }
                for (key, value) in shared.object { result[key] = value }
                return .object(result)
            }
            let tasks = incoming["tasks"].array.map { task -> JSON in
                let old = oldTasks[task["id"].string]
                var result = overlay(task, local: old, fields: OrganizationStateSchema.taskFields)
                // A cross-space private dependency is a device-local relationship, not an org edge.
                let privateDependencies = old?["dependsOn"].array.filter { privateIDs.contains($0.string) } ?? []
                if !privateDependencies.isEmpty {
                    result["dependsOn"] = .array(task["dependsOn"].array + privateDependencies)
                }
                if let old, privateIDs.contains(old["parentId"].string) { result["parentId"] = old["parentId"] }
                // Preserve local-only metadata even inside an existing human-wait entry.
                if let old, case .array(let waits) = task["peopleWaits"] {
                    let oldWaits = old["peopleWaits"].array
                    result["peopleWaits"] = .array(waits.map { wait in
                        overlay(wait, local: oldWaits.first { $0["id"] == wait["id"] }, fields: OrganizationStateSchema.peopleWaitFields)
                    })
                }
                return result
            }
            let remainingIDs = Set(tasks.map { $0["id"].string }).union(privateIDs)
            for task in privateTasks {
                let references = task["dependsOn"].array.map(\.string) + [task["parentId"].string].filter { !$0.isEmpty }
                guard references.allSatisfy({ remainingIDs.contains($0) }) else {
                    throw RuntimeError("organization_private_dependency_conflict", "组织删除的任务仍被本机私人任务引用。同步已暂停，私人任务及其依赖关系未更改。")
                }
            }
            func mergeDefinitions(_ collection: String, fields: Set<String>) -> JSON {
                let remote = incoming[collection].array
                let old = current[collection].array
                let remoteIDs = Set(remote.map { $0["id"].string })
                // Keep locally referenced or empty definitions; they do not enter the projection
                // unless a non-private task uses them. Never discard unrelated local information.
                return .array(remote.map { entity in
                    overlay(entity, local: old.first { $0["id"] == entity["id"] }, fields: fields)
                } + old.filter { !remoteIDs.contains($0["id"].string) })
            }
            var next = current
            next["tasks"] = .array(tasks + privateTasks)
            next["tracks"] = mergeDefinitions("tracks", fields: OrganizationStateSchema.trackFields)
            next["taskPages"] = mergeDefinitions("taskPages", fields: OrganizationStateSchema.pageFields)
            try validateGraph(next)
            guard Self.organizationProjection(next) == incoming else {
                throw RuntimeError("organization_document_invalid", "组织文档包含未使用的板块或页面，已停止同步。")
            }
            let directory = file("cloud-history")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeJSON(current, to: directory.appendingPathComponent("before-organization-\(Int(current["meta"]["version"].number))-\(UUID().uuidString).json"))
            next["meta"]["version"] = .number(current["meta"]["version"].number + 1)
            next["meta"]["updatedAt"] = .string(RuntimeDate.iso())
            next["receipts"] = [] // Older inverse operations must not undo another member's changes.
            let event: JSON = ["version": next["meta"]["version"], "timestamp": next["meta"]["updatedAt"],
                "mutationId": .string("organization-\(UUID().uuidString)"), "affected": [], "source": "organization-cloud"]
            try writeJSON(["previousVersion": current["meta"]["version"], "state": next, "event": event], to: file(".pending-transaction.json"))
            try recoverTransaction()
            return next
        }
    }
}
