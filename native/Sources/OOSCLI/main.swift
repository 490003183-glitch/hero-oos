import Foundation
import OOSCore

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
func output(_ value: JSON, to handle: FileHandle = .standardOutput) throws { var data = try value.encoded(pretty: true); data.append(10); try handle.write(contentsOf: data) }
let runtime = StateRuntime(root: URL(fileURLWithPath: option("--root") ?? ProcessInfo.processInfo.environment["HERO_OOS_ROOT"] ?? StateRuntime.defaultRoot))
do {
    switch args.first ?? "help" {
    case "init":
        try runtime.initializeIfNeeded(); try output(["ok": true, "version": runtime.readState()["meta"]["version"]])
    case "meta": try output(runtime.readState()["meta"])
    case "state": try output(runtime.readState())
    case "health": try output(runtime.request("/api/health"))
    case "attention":
        let state = try runtime.readState(); try output(["version": state["meta"]["version"], "attention": .array(runtime.attention(state))])
    case "worker-list":
        let state = try runtime.readState(); try output(["version": state["meta"]["version"], "items": .array(state["workerItems"].array.filter { $0["status"] == "pending" })])
    case "changes": try output(runtime.changes(consumer: option("--consumer") ?? ""))
    case "changes-ack":
        let consumer = option("--consumer") ?? ""
        guard let version = Double(option("--version") ?? "") else { throw RuntimeError("invalid_ack_version", "需要 --version。") }
        var value = try runtime.acknowledge(consumer: consumer, version: version); value["consumer"] = .string(consumer); try output(value)
    case "op":
        guard let file = option("--file") else { throw RuntimeError("file_required", "op 需要 --file <UTF-8 JSON>。") }
        guard let version = Double(option("--expected-version") ?? "") else { throw RuntimeError("expected_version_required", "每次写操作都需要 --expected-version。") }
        let ops = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let result = try runtime.mutate(["expectedVersion": .number(version), "clientMutationId": .string(option("--mutation-id") ?? "cli-\(UUID().uuidString.lowercased())"), "operations": ops, "confirmedMajor": .bool(args.contains("--confirmed-major"))])
        try output(["ok": true, "transport": "swift-local", "version": result["version"], "receipt": result["receipt"], "duplicate": result["duplicate"].or(false)])
    case "collages": try output(runtime.readCollages())
    case "sync-check":
        let organization = try runtime.organizationState(), personal = try runtime.personalTaskState()
        try runtime.validateOrganizationState(organization); try runtime.validatePersonalTaskState(personal)
        try output(["ok": true, "organizationTasks": .number(Double(organization["tasks"].array.count)),
                    "personalTasks": .number(Double(personal["tasks"].array.count)), "version": try runtime.readState()["meta"]["version"]])
    case "import-local":
        guard args.contains("--confirmed-major"), let source = option("--source"), option("--root") != nil,
              let version = Double(option("--expected-version") ?? "") else {
            throw RuntimeError("local_import_confirmation_required", "本机迁移需要 --source、--root、--expected-version 与 --confirmed-major。不会上传任何数据。")
        }
        try output(LocalWorkspaceImport.perform(source: StateRuntime(root: URL(fileURLWithPath: source)), destination: runtime, expectedVersion: version))
    case "codex-status": try output(CodexStatus.read((option("--ids") ?? "").split(separator: ",").map(String.init)))
    default:
        print("Hero OOS Swift CLI\n  init | meta | state | health | attention | worker-list | collages\n  changes --consumer <id>\n  changes-ack --consumer <id> --version <n>\n  op --expected-version <n> --file <ops.json> [--mutation-id <id>] [--confirmed-major]\n  import-local --source <original OOS> --root <destination OOS> --expected-version <n> --confirmed-major\n  codex-status --ids <id,id>\n  Optional: --root <OOS directory>")
    }
} catch {
    let payload = (error as? RuntimeError)?.payload ?? RuntimeError("internal_error", error.localizedDescription).payload
    try? output(payload, to: .standardError); exit(1)
}
