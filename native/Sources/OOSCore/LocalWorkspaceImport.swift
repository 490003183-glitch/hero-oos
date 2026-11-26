import Foundation
import CryptoKit
import Darwin

/// An explicit, local-only copy. Authentication and network transports are deliberately absent.
public enum LocalWorkspaceImport {
    public static let markerName = "local-workspace-import.json"

    private struct Asset {
        let name: String
        let source: URL
        let digest: SHA256.Digest
        let bytes: Int
    }

    /// Callers must first flush editing drafts and pause account synchronization. All original files
    /// remain in place. If interrupted, an identical retry merges already-copied entities by ID.
    @discardableResult public static func perform(source: StateRuntime, destination: StateRuntime,
                                                  expectedVersion: Double? = nil) throws -> JSON {
        let sourceRoot = source.root.resolvingSymlinksInPath(), destinationRoot = destination.root.resolvingSymlinksInPath()
        guard sourceRoot.path != destinationRoot.path else { throw failure("source_is_destination", "原工作区和目标工作区不能相同。") }
        guard FileManager.default.fileExists(atPath: source.file("state.json").path) else {
            throw failure("source_missing", "原工作区任务文件不存在，未开始迁移。")
        }
        let original: (JSON, JSON) = try source.locked {
            let state = try source.readJSON(source.file("state.json"))
            let collages = try source.readJSON(source.collageFile("collages.json"), fallback: StateRuntime.defaultCollages)
            try validateCollageDocument(collages)
            return (state, source.normalizeCollages(collages))
        }
        try destination.initializeIfNeeded()
        // Serialize import invocations, without holding the normal runtime lock across CAS calls.
        let importLock = destination.file(".local-import.lock")
        let fd = open(importLock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw failure("busy", "本机迁移正在进行，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }

        let before = try destination.readState(), existing = StateRuntime.cloudProjection(before)
        if let expectedVersion, before["meta"]["version"].number != expectedVersion {
            throw failure("state_conflict", "目标工作区已变化，请读取最新版本后重试。")
        }
        let beforeCollages: JSON = try destination.locked {
            let raw = try destination.readJSON(destination.collageFile("collages.json"), fallback: StateRuntime.defaultCollages)
            try validateCollageDocument(raw)
            return destination.normalizeCollages(raw)
        }
        let merged = try mergeState(existing: existing, source: StateRuntime.cloudProjection(original.0))
        try destination.validateCloudState(merged)
        try validateReferences(merged)
        let mergedCollages = try mergeCollages(existing: beforeCollages, source: original.1)
        let assets = try assetInventory(document: original.1, source: source, destination: destination)
        let markerURL = destination.file(markerName)
        if FileManager.default.fileExists(atPath: markerURL.path) {
            let marker = try destination.readJSON(markerURL)
            guard marker["source"].string == sourceRoot.path else {
                throw failure("source_conflict", "目标已有来自其他工作区的迁移记录，未覆盖。")
            }
            if merged == existing, mergedCollages == beforeCollages,
               assets.allSatisfy({ asset in
                   guard let url = try? destination.assetURL(asset.name) else { return false }
                   return FileManager.default.fileExists(atPath: url.path)
               }) {
                return ["ok": true, "duplicate": true, "counts": marker["counts"], "version": before["meta"]["version"]]
            }
        }

        // Save both destination documents before the first live mutation, including empty targets.
        let backup = destination.file("local-import-history").appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writePrivate(before, to: backup.appendingPathComponent("state.json"), runtime: destination)
        try writePrivate(beforeCollages, to: backup.appendingPathComponent("collages.json"), runtime: destination)
        try FileManager.default.createDirectory(at: destination.collageFile("collage-assets"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for asset in assets { try copy(asset, to: destination) }

        // Collage CAS and task CAS retain concurrent edits. Partial success is never rolled back over
        // someone else's edit; the saved backup plus ID-based retry make interruption recoverable.
        _ = try destination.saveCollages(mergedCollages, expected: beforeCollages)
        // Cloud comparisons ignore edit timestamps, but a local migration need not discard them.
        // Preserve the existing destination timestamp for exact duplicates, otherwise the source's.
        var localCommit = merged
        for (key, values) in merged.object {
            guard case .array(let items) = values else { continue }
            let previous = Dictionary(before[key].array.map { ($0["id"].string, $0) }, uniquingKeysWith: { first, _ in first })
            let originalItems = Dictionary(original.0[key].array.map { ($0["id"].string, $0) }, uniquingKeysWith: { first, _ in first })
            localCommit[key] = .array(items.map { item in
                var value = item
                let raw = previous[item["id"].string] ?? originalItems[item["id"].string]
                if let timestamp = raw?.object["updatedAt"] { value["updatedAt"] = timestamp }
                return value
            })
        }
        let written = try destination.applyCloudState(merged == existing ? existing : localCommit, expected: existing)
        let items = original.1["canvases"].array.flatMap { $0["items"].array }
        let tasks = original.0["tasks"].array
        let counts: JSON = ["tasks": .number(Double(tasks.count)),
            "privateTasks": .number(Double(tasks.filter { Record($0.object).taskSpace == .personal }.count)),
            "taskPages": .number(Double(original.0["taskPages"].array.count)),
            "scheduleBlocks": .number(Double(original.0["scheduleBlocks"].array.count)),
            "canvases": .number(Double(original.1["canvases"].array.count)),
            "images": .number(Double(items.filter { $0["kind"] != "text" }.count)),
            "texts": .number(Double(items.filter { $0["kind"] == "text" }.count)),
            "assets": .number(Double(assets.count)), "assetBytes": .number(Double(assets.reduce(0) { $0 + $1.bytes }))]
        // This marker contains no task text or credentials and is written only after both CAS commits.
        try writePrivate(["source": .string(sourceRoot.path), "counts": counts], to: markerURL, runtime: destination)
        return ["ok": true, "duplicate": false, "counts": counts, "version": written["meta"]["version"], "backup": .string(backup.path)]
    }

    public static func mergeState(existing: JSON, source: JSON) throws -> JSON {
        var result = existing
        for (key, incoming) in source.object {
            if case .array(let values) = incoming {
                if values.isEmpty { continue }
                if existing[key] != .null, case .array = existing[key] {} else if existing[key] != .null {
                    throw failure("state_collision", "目标的 \(key) 不是兼容集合，未覆盖。")
                }
                guard values.allSatisfy({ !$0["id"].string.isEmpty }) else {
                    if existing[key] == incoming { continue }
                    if existing[key] == .null || existing[key] == .array([]) { result[key] = incoming; continue }
                    throw failure("state_collision", "原工作区和目标的 \(key) 内容不同，迁移已停止。")
                }
                let current = existing[key].array
                guard Set(values.map { $0["id"].string }).count == values.count,
                      Set(current.map { $0["id"].string }).count == current.count else {
                    throw failure("duplicate_id", "迁移数据包含重复标识，未覆盖目标。")
                }
                var merged = current
                for value in values {
                    if let old = current.first(where: { $0["id"] == value["id"] }) {
                        guard old == value else { throw failure("state_collision", "相同 ID 的任务或板块内容不同，迁移已停止，未覆盖。") }
                    } else { merged.append(value) }
                }
                result[key] = .array(merged)
            } else if existing[key] == .null { result[key] = incoming }
            else if existing[key] != incoming {
                // Only untouched bootstrap defaults can be replaced. Real destination settings
                // must not silently override or be overwritten by a different source value.
                let seeds: [String: JSON] = ["onboarding": ["completedSteps": [], "firstFlight": "active"],
                                             "currentTruth": ["horizonHours": 72]]
                if seeds[key] == existing[key] { result[key] = incoming; continue }
                throw failure("state_collision", "原工作区和目标的 \(key) 内容不同，迁移已停止。")
            }
        }
        return result
    }

    private static func validateReferences(_ state: JSON) throws {
        let taskIDs = Set(state["tasks"].array.map { $0["id"].string })
        let trackIDs = Set(state["tracks"].array.map { $0["id"].string })
        for entity in state["tasks"].array + state["scheduleBlocks"].array where !entity["trackId"].string.isEmpty {
            guard trackIDs.contains(entity["trackId"].string) else { throw failure("missing_reference", "任务或日程引用的分类不存在，迁移已停止。") }
        }
        for block in state["scheduleBlocks"].array where !block["taskId"].string.isEmpty {
            guard taskIDs.contains(block["taskId"].string) else { throw failure("missing_reference", "日程引用的任务不存在，迁移已停止。") }
        }
    }

    private static func validateCollageDocument(_ document: JSON) throws {
        guard case .object = document, case .array(let canvases) = document["canvases"], !canvases.isEmpty else {
            throw failure("invalid_collages", "原拼图文档格式无效，未开始迁移。")
        }
        var canvasIDs = Set<String>()
        for canvas in canvases {
            guard StateRuntime.matches(canvas["id"].string, "^[a-zA-Z0-9-]+$"), canvasIDs.insert(canvas["id"].string).inserted,
                  case .array(let items) = canvas["items"] else { throw failure("invalid_collages", "拼图画布标识或项目无效。") }
            var itemIDs = Set<String>()
            for item in items {
                guard StateRuntime.matches(item["id"].string, "^[a-zA-Z0-9-]+$"), itemIDs.insert(item["id"].string).inserted else {
                    throw failure("invalid_collages", "拼图项目标识无效或重复。")
                }
                guard item["kind"] == "text" || StateRuntime.validAsset(item["assetFile"].string) else {
                    throw failure("invalid_asset", "拼图图片引用无效，未开始迁移。")
                }
            }
        }
        guard canvasIDs.contains(document["activeCanvasId"].string) else { throw failure("invalid_collages", "拼图当前画布引用不存在。") }
    }

    private static func mergeCollages(existing: JSON, source: JSON) throws -> JSON {
        try validateCollageDocument(existing)
        if existing == StateRuntime.defaultCollages { return source }
        var result = existing, canvases = existing["canvases"].array
        for canvas in source["canvases"].array {
            if let old = canvases.first(where: { $0["id"] == canvas["id"] }) {
                guard old == canvas else { throw failure("collage_collision", "相同 ID 的拼图画布内容不同，迁移已停止，未覆盖。") }
            } else { canvases.append(canvas) }
        }
        result["canvases"] = .array(canvases)
        return result
    }

    private static func assetInventory(document: JSON, source: StateRuntime, destination: StateRuntime) throws -> [Asset] {
        let names = Set(document["canvases"].array.flatMap { $0["items"].array }.filter { $0["kind"] != "text" }.map { $0["assetFile"].string })
        return try names.sorted().map { name in
            let url = try source.assetURL(name)
            // The runtime's URL containment check expects the asset directory to exist. During
            // preflight an empty account may have no directory yet; do not create it just to read.
            let target = FileManager.default.fileExists(atPath: try destination.collageFile("collage-assets").path) ? try destination.assetURL(name) : nil
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw failure("missing_asset", "原拼图引用的图片文件不存在或无效。") }
            let data = try Data(contentsOf: url), digest = SHA256.hash(data: data)
            guard !data.isEmpty else { throw failure("invalid_asset", "原拼图图片为空。") }
            if let target, FileManager.default.fileExists(atPath: target.path) {
                guard SHA256.hash(data: try Data(contentsOf: target)) == digest else {
                    throw failure("asset_collision", "目标存在同名但不同内容的图片，迁移已停止，未覆盖。")
                }
            }
            return Asset(name: name, source: url, digest: digest, bytes: data.count)
        }
    }

    private static func copy(_ asset: Asset, to destination: StateRuntime) throws {
        let target = try destination.assetURL(asset.name)
        if FileManager.default.fileExists(atPath: target.path) {
            guard SHA256.hash(data: try Data(contentsOf: target)) == asset.digest else { throw failure("asset_collision", "目标图片在迁移期间发生变化，已停止。") }
            return
        }
        let data = try Data(contentsOf: asset.source)
        guard SHA256.hash(data: data) == asset.digest else { throw failure("asset_changed", "原图片在迁移期间发生变化，请重试。") }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // link is atomic and fails if the destination appeared concurrently; it never replaces a file.
        guard link(temporary.path, target.path) == 0 else {
            if errno == EEXIST, SHA256.hash(data: try Data(contentsOf: target)) == asset.digest { return }
            throw failure("asset_collision", "目标图片在迁移期间出现，未覆盖。")
        }
    }

    private static func writePrivate(_ value: JSON, to url: URL, runtime: StateRuntime) throws {
        try runtime.writeJSON(value, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func failure(_ code: String, _ message: String) -> RuntimeError { RuntimeError("local_import_" + code, message) }
}
