import Foundation

@MainActor protocol UpdateReleaseStreaming: AnyObject {
    func start(onBuild: @escaping (Int) -> Void)
    func stop()
}

/// Public release notifications contain only a build number. They are a hint;
/// the manager still verifies the signed catalog before showing any update.
@MainActor final class UpdateReleaseStream: UpdateReleaseStreaming {
    static var endpoint: URL { CloudAPI.configuredURL.appendingPathComponent("v1/update-events") }
    private let transport: ServerEventTransport
    private let sleep: (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(transport: ServerEventTransport? = nil,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.transport = transport ?? URLSessionServerEventTransport(); self.sleep = sleep
    }
    deinit { task?.cancel() }

    static func permits(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == endpoint.host && (url.port ?? 443) == (endpoint.port ?? 443) &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == endpoint.path
    }

    static func releaseBuild(from event: ServerSentEvent) -> Int? {
        guard event.event == "release", event.data.utf8.count <= 1_024,
              let data = event.data.data(using: .utf8),
              let hint = try? JSONDecoder().decode(ReleaseHint.self, from: data), hint.releaseBuild > 0 else { return nil }
        return hint.releaseBuild
    }
    private struct ReleaseHint: Decodable { let releaseBuild: Int }

    static func request() -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }

    func start(onBuild: @escaping (Int) -> Void) {
        guard task == nil, Self.permits(Self.endpoint) else { return }
        guard !(transport is URLSessionServerEventTransport && Self.endpoint.host?.hasSuffix(".invalid") == true) else { return }
        let token = UUID(); generation = token
        let transport = transport, sleep = sleep
        task = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let request = Self.request()
                    // No Authorization, account token, task or private data.
                    try await transport.receive(request: request) { [weak self] event in
                        guard self?.generation == token else { return }
                        failures = 0
                        if let build = Self.releaseBuild(from: event) { onBuild(build) }
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                guard !Task.isCancelled, self?.generation == token else { return }
                let delay = Self.reconnectDelay(failures: failures)
                failures = min(failures + 1, 6)
                do { try await sleep(delay) }
                catch { return }
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
    }

    static func reconnectDelay(failures: Int) -> TimeInterval {
        min(60, pow(2, Double(max(0, min(failures, 6)))))
    }
}
