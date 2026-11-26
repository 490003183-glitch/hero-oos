import Foundation

struct ServerSentEvent: Equatable {
    let event: String
    let data: String
}

/// Parse bytes, not AsyncBytes.lines, so an unterminated line cannot grow without bound.
struct ServerSentEventDecoder {
    static let maximumLineBytes = 8 * 1024
    static let maximumFrameBytes = 32 * 1024
    private var line: [UInt8] = []
    private var frameBytes = 0
    private var event = ""
    private var values: [String] = []

    mutating func consume(_ byte: UInt8) throws -> ServerSentEvent? {
        frameBytes += 1
        guard frameBytes <= Self.maximumFrameBytes else { throw Self.invalidFrame() }
        guard byte == 10 else {
            guard line.count < Self.maximumLineBytes else { throw Self.invalidFrame() }
            line.append(byte); return nil
        }
        if line.last == 13 { line.removeLast() }
        guard let text = String(bytes: line, encoding: .utf8) else { throw Self.invalidFrame() }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            defer { event = ""; values.removeAll(keepingCapacity: true); frameBytes = 0 }
            return values.isEmpty ? nil : ServerSentEvent(event: event.isEmpty ? "message" : event,
                                                         data: values.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(pieces[0])
        var value = pieces.count == 2 ? String(pieces[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "event" { event = value }
        else if field == "data" { values.append(value) }
        return nil
    }
    private static func invalidFrame() -> CloudAccountError {
        CloudAccountError(code: "invalid_event_stream", message: "服务端通知格式无效，正在重新连接。")
    }
}

@MainActor protocol ServerEventTransport {
    func receive(request: URLRequest, handler: @escaping (ServerSentEvent) throws -> Void) async throws
}

private final class ServerEventRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class URLSessionServerEventTransport: ServerEventTransport {
    func receive(request: URLRequest, handler: @escaping (ServerSentEvent) throws -> Void) async throws {
        guard let url = request.url, url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["/v1/events", "/v1/update-events"].contains(url.path) else {
            throw CloudAccountError(code: "unsafe_url", message: "已阻止不安全的服务端通知连接。")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 75
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let delegate = ServerEventRedirectGuard()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url else {
            throw CloudAccountError(code: "redirect_blocked", message: "服务端通知连接被重定向，已停止使用。")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CloudAccountError(code: http.statusCode == 401 ? "unauthorized" : "forbidden",
                                    message: "服务端通知授权已失效，请重新确认账号。")
        }
        guard http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first == "text/event-stream" else {
            throw CloudAccountError(code: "event_connection_failed", message: "服务端通知暂不可用，正在重连。")
        }
        var decoder = ServerSentEventDecoder()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let event = try decoder.consume(byte) { try handler(event) }
        }
        throw URLError(.networkConnectionLost)
    }
}

struct CloudServerStateEvent: Decodable, Equatable {
    let organizationRevision: Int
    let personalRevision: Int
    let releaseBuild: Int
    static func decode(_ event: ServerSentEvent) throws -> Self? {
        guard event.event == "state" else { return nil }
        let state = try JSONDecoder().decode(Self.self, from: Data(event.data.utf8))
        guard state.organizationRevision >= 0, state.personalRevision >= 0, state.releaseBuild >= 0 else {
            throw CloudAccountError(code: "invalid_event_stream", message: "服务端通知版本无效。")
        }
        return state
    }
}

/// One authenticated connection shared by the organization's and owner's engines.
@MainActor final class CloudTaskEventStream {
    private weak var account: CloudAccount?
    private let identity: String
    private let transport: any ServerEventTransport
    private let onState: (CloudServerStateEvent, Bool) -> Void
    private let onConnection: (Bool, Error?) -> Void
    private let sleep: (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = 0

    init(account: CloudAccount, transport: (any ServerEventTransport)? = nil,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         onState: @escaping (CloudServerStateEvent, Bool) -> Void,
         onConnection: @escaping (Bool, Error?) -> Void) {
        self.account = account; identity = account.identityKey ?? ""; self.transport = transport ?? URLSessionServerEventTransport()
        self.sleep = sleep; self.onState = onState; self.onConnection = onConnection
    }
    deinit { task?.cancel() }
    func stop() { generation += 1; task?.cancel(); task = nil }
    static func retryDelay(_ failures: Int) -> TimeInterval { min(60, pow(2, Double(min(6, max(0, failures - 1))))) }

    private func request(_ generation: Int) -> URLRequest? {
        guard self.generation == generation, let account else { return nil }
        return try? account.eventRequest(identity: identity)
    }
    private func current(_ request: URLRequest, generation: Int) -> Bool {
        self.generation == generation && account?.eventRequestIsCurrent(request, identity: identity) == true
    }
    func start() {
        stop(); let generation = self.generation
        let transport = transport, sleep = sleep
        let request = { [weak self] in self?.request(generation) }
        let current = { [weak self] (request: URLRequest) in self?.current(request, generation: generation) == true }
        let state = { [weak self] (event: CloudServerStateEvent, first: Bool) in self?.onState(event, first) }
        let connection = { [weak self] (connected: Bool, error: Error?) in self?.onConnection(connected, error) }
        let rejected = { [weak self] (request: URLRequest, error: Error) in
            self?.account?.rejectEventRequest(request, identity: self?.identity ?? "", error: error)
        }
        task = Task {
            var failures = 0
            while !Task.isCancelled {
                guard let outgoing = request() else { return }
                var first = true
                do {
                    try await transport.receive(request: outgoing) { event in
                        guard current(outgoing) else { return }
                        if let update = try CloudServerStateEvent.decode(event) {
                            if first { connection(true, nil) }
                            state(update, first); first = false; failures = 0
                        }
                    }
                    throw URLError(.networkConnectionLost)
                } catch {
                    guard !Task.isCancelled, current(outgoing) else { return }
                    connection(false, error)
                    if let code = (error as? CloudAccountError)?.code, ["unauthorized", "forbidden"].contains(code) {
                        rejected(outgoing, error); return
                    }
                    failures += 1
                    do { try await sleep(Self.retryDelay(failures)) } catch { return }
                }
            }
        }
    }
}
