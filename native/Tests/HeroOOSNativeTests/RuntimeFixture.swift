import XCTest
@testable import OOSCore
@testable import HeroOOSNative

class SwiftIntegrationCase: XCTestCase {
    var root: URL!
    var runtime: StateRuntime!
    var fault: FaultTransport!
    var api: OOSAPI { OOSAPI(base: root) }
    var direct: OOSAPI { api }
    var proxy: OOSAPI { OOSAPI(base: root, transport: { [fault = fault!] path, method, body, data in try await fault.request(path, method, body, data) }) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hero-oos-swift-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        runtime = StateRuntime(root: root); fault = FaultTransport(runtime: runtime)
        let fixture: JSON = ["meta": ["version": 1, "instanceId": "hero-oos-test", "unknownMeta": ["keep": true]], "tasks": [], "tracks": [["id": "track-personal", "name": "测试", "archetype": "habit"]], "scheduleBlocks": [], "metrics": [], "checkins": [], "captures": [], "workerItems": [], "memories": [], "decisions": [], "receipts": [], "migrations": [], "currentTruth": ["horizonHours": 72], "onboarding": ["completedSteps": [], "firstFlight": "active"], "futureRoot": ["preserve": [1, true, nil]]]
        try fixture.encoded(pretty: true).write(to: root.appendingPathComponent("data/state.json"))
    }
    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }
    func mutate(_ operations: [JSON], confirmed: Bool = false, id: String = UUID().uuidString) throws -> JSON {
        try runtime.mutate(["expectedVersion": runtime.readState()["meta"]["version"], "clientMutationId": .string(id), "operations": .array(operations), "confirmedMajor": .bool(confirmed)])
    }
}

actor FaultTransport {
    let runtime: StateRuntime
    var offline = false, loseResponse = false
    init(runtime: StateRuntime) { self.runtime = runtime }
    func request(_ path: String, _ method: String, _ body: JSON?, _ data: Data?) throws -> JSON {
        if path == "/__qa/control" {
            if let value = body?.object["offline"] { offline = value.bool }
            if let value = body?.object["loseResponse"] { loseResponse = value.bool }
            return ["ok": true]
        }
        guard !offline else { throw URLError(.cannotConnectToHost) }
        let result: JSON
        do { result = try runtime.request(path, method: method, body: body, raw: data) }
        catch let e as RuntimeError { throw APIError(code: e.code, payload: e.payload) }
        if path == "/api/state-ops", loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
        return result
    }
}
