import Foundation

extension StateRuntime {
    /// Owner-only cloud backup of private task-management data. The organization never receives
    /// this projection. Collage canvases/assets, Codex references and local provenance stay local.
    public static func personalTaskProjection(_ state: JSON) -> JSON {
        taskScopeProjection(state, personal: true)
    }

    public func personalTaskState() throws -> JSON { Self.personalTaskProjection(try readState()) }

    public func validatePersonalTaskState(_ incoming: JSON) throws {
        try validateTaskScopeState(incoming, personal: true)
    }

    /// Independent CAS for the owner-only scope; organization edits and local-only fields survive.
    @discardableResult public func applyPersonalTaskState(_ incoming: JSON, expected: JSON) throws -> JSON {
        try validatePersonalTaskState(incoming)
        return try locked {
            let current = try readJSON(file("state.json"))
            guard Self.personalTaskProjection(current) == expected else {
                throw RuntimeError("cloud_local_conflict", "同步期间私人任务有新编辑，已保留编辑并等待重新合并。")
            }
            if incoming == expected { return current }
            try validateOppositeScopeTracks(incoming, current: current, personal: true)
            let organizationTasks = current["tasks"].array.filter { $0["taskSpace"].string != TaskSpace.personal.rawValue }
            let organizationIDs = Set(organizationTasks.map { $0["id"].string })
            guard !incoming["tasks"].array.contains(where: { organizationIDs.contains($0["id"].string) }) else {
                throw RuntimeError("personal_organization_id_conflict", "私人任务标识与本机组织任务冲突，已停止同步，组织内容未更改。")
            }
            let oldTasks = Dictionary(uniqueKeysWithValues: current["tasks"].array.map { ($0["id"].string, $0) })
            func overlay(_ shared: JSON, local: JSON?, fields: Set<String>) -> JSON {
                var result = local?.object ?? [:]
                for key in fields { result.removeValue(forKey: key) }
                for (key, value) in shared.object { result[key] = value }
                return .object(result)
            }
            let personalTasks = incoming["tasks"].array.map { task -> JSON in
                let old = oldTasks[task["id"].string]
                var result = overlay(task, local: old, fields: OrganizationStateSchema.taskFields)
                // Cross-scope links remain local and are not transported to either cloud document.
                let organizationDependencies = old?["dependsOn"].array.filter { organizationIDs.contains($0.string) } ?? []
                if !organizationDependencies.isEmpty {
                    result["dependsOn"] = .array(task["dependsOn"].array + organizationDependencies)
                }
                if let old, organizationIDs.contains(old["parentId"].string) { result["parentId"] = old["parentId"] }
                if let old, case .array(let waits) = task["peopleWaits"] {
                    result["peopleWaits"] = .array(waits.map { wait in
                        overlay(wait, local: old["peopleWaits"].array.first { $0["id"] == wait["id"] }, fields: OrganizationStateSchema.peopleWaitFields)
                    })
                }
                return result
            }
            let remainingIDs = Set(personalTasks.map { $0["id"].string }).union(organizationIDs)
            for task in organizationTasks {
                let references = task["dependsOn"].array.map(\.string) + [task["parentId"].string].filter { !$0.isEmpty }
                guard references.allSatisfy({ remainingIDs.contains($0) }) else {
                    throw RuntimeError("personal_organization_dependency_conflict", "云端删除的私人任务仍被本机组织任务引用。同步已暂停，组织任务及其依赖关系未更改。")
                }
            }
            let tracks = incoming["tracks"].array
            let oldTracks = current["tracks"].array
            let incomingTrackIDs = Set(tracks.map { $0["id"].string })
            let nextTracks = tracks.map { track in
                overlay(track, local: oldTracks.first { $0["id"] == track["id"] }, fields: OrganizationStateSchema.trackFields)
            }
            var next = current
            next["tasks"] = .array(organizationTasks + personalTasks)
            // Organization definitions stay ahead of private-only definitions, matching the
            // organization applier's order and keeping independent scope edits commutative.
            next["tracks"] = .array(oldTracks.filter { !incomingTrackIDs.contains($0["id"].string) } + nextTracks)
            // Personal tasks use the built-in personal page; custom taskPages remain untouched.
            try validateGraph(next)
            guard Self.personalTaskProjection(next) == incoming else {
                throw RuntimeError("personal_document_invalid", "私人任务同步文档无法无损应用，已停止同步。")
            }
            let directory = file("cloud-history")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeJSON(current, to: directory.appendingPathComponent("before-personal-\(Int(current["meta"]["version"].number))-\(UUID().uuidString).json"))
            next["meta"]["version"] = .number(current["meta"]["version"].number + 1)
            next["meta"]["updatedAt"] = .string(RuntimeDate.iso())
            next["receipts"] = []
            let event: JSON = ["version": next["meta"]["version"], "timestamp": next["meta"]["updatedAt"],
                "mutationId": .string("personal-\(UUID().uuidString)"), "affected": [], "source": "personal-tasks-cloud"]
            try writeJSON(["previousVersion": current["meta"]["version"], "state": next, "event": event], to: file(".pending-transaction.json"))
            try recoverTransaction()
            return next
        }
    }
}
