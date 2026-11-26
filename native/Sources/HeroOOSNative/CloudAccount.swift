import Foundation
import Combine
import Security

struct CloudUser: Codable, Equatable { let id: String; let username: String }
struct CloudOrganization: Codable, Equatable {
    let id: String
    let name: String
    let role: String
    var canManageMembers: Bool { ["owner", "admin"].contains(role) }
}
struct CloudMembership: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let role: String
    let status: String
}
struct CloudMember: Codable, Equatable, Identifiable {
    let id: String
    let userId: String
    let username: String
    let role: String
    let status: String
}
struct CloudSession: Codable, Equatable {
    let user: CloudUser
    let organization: CloudOrganization
    var memberships: [CloudMembership]
    let expiresAt: String?
}
struct CloudCredential: Codable, Equatable {
    let token: String
    let userID: String
    let organizationID: String
    var cachedSession: CloudSession? = nil
}

struct CloudAccountError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

protocol CloudTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Uses system TLS validation. Never forwards a bearer token to a redirect target.
final class CloudURLSessionTransport: NSObject, CloudTransport, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CloudAccountError(code: "invalid_response", message: "服务器返回了无法识别的响应。")
        }
        return (data, response)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct CloudAPI {
    /// Public builds require an explicitly configured HTTPS server.
    static var configuredURL: URL {
        let value = ProcessInfo.processInfo.environment["HERO_OOS_CLOUD_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "HeroOOSCloudURL") as? String
            ?? "https://cloud.example.invalid"
        return URL(string: value) ?? URL(string: "https://cloud.example.invalid")!
    }
    let baseURL: URL
    let transport: any CloudTransport
    init(baseURL: URL = configuredURL, transport: any CloudTransport = CloudURLSessionTransport()) {
        self.baseURL = baseURL; self.transport = transport
    }
    var serverID: String { "https://\(baseURL.host?.lowercased() ?? "invalid"):\(baseURL.port ?? 443)" }

    func requestURL(_ path: String) throws -> URL {
        let decodedPath = (path.components(separatedBy: "?").first ?? "").removingPercentEncoding ?? path
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              path.hasPrefix("/v1/"), !decodedPath.contains("\\"),
              !decodedPath.components(separatedBy: "/").contains(where: { $0 == "." || $0 == ".." }),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host?.lowercased() == baseURL.host?.lowercased(),
              (url.port ?? 443) == (baseURL.port ?? 443), url.path.hasPrefix("/v1/"), url.user == nil, url.password == nil, url.fragment == nil,
              !url.path.components(separatedBy: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CloudAccountError(code: "unsafe_url", message: "已阻止不安全或跨服务器的云端请求。")
        }
        return url
    }

    func request(_ path: String, method: String = "GET", body: JSON? = nil, token: String? = nil) async throws -> JSON {
        guard !(transport is CloudURLSessionTransport && baseURL.host?.hasSuffix(".invalid") == true) else {
            throw CloudAccountError(code: "not_configured", message: "云端尚未配置；本机工作区可正常使用。请配置自己的 HTTPS 服务。")
        }
        let url = try requestURL(path)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw CloudAccountError(code: "invalid_session", message: "登录凭据无效，请重新登录。")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.send(request)
        // Also guard injected transports and unexpected URLSession behavior.
        guard response.url?.host?.lowercased() == url.host?.lowercased(),
              response.url?.scheme?.lowercased() == "https", (response.url?.port ?? 443) == (url.port ?? 443),
              !(300..<400).contains(response.statusCode) else {
            throw CloudAccountError(code: "redirect_blocked", message: "服务器重定向已被阻止，请检查服务配置。")
        }
        let payload = data.isEmpty ? JSON.object([:]) : (try? JSONDecoder().decode(JSON.self, from: data))
        guard (200..<300).contains(response.statusCode), let payload else {
            throw CloudAccountError(code: payload?["error"].string.isEmpty == false ? payload!["error"].string : "http_\(response.statusCode)",
                                    message: payload?["message"].string.isEmpty == false ? payload!["message"].string : "云端请求失败（\(response.statusCode)），请稍后重试。")
        }
        if payload["ok"] == .bool(false) {
            throw CloudAccountError(code: payload["error"].string, message: payload["message"].string.isEmpty ? "服务器未接受此操作。" : payload["message"].string)
        }
        return payload
    }
}

protocol CloudCredentialStore {
    func read(serverID: String) throws -> CloudCredential?
    func write(_ credential: CloudCredential, serverID: String) throws
    func remove(serverID: String) throws
}

struct CloudKeychainStore: CloudCredentialStore {
    private let service = "com.hero-oos.cloud.session"
    private func query(_ serverID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: serverID, kSecAttrSynchronizable as String: false]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw CloudAccountError(code: "keychain", message: "无法访问系统钥匙串（\(status)）。请允许 Hero OOS 访问自己的登录凭据后重试。")
        }
    }
    func read(serverID: String) throws -> CloudCredential? {
        var q = query(serverID)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw CloudAccountError(code: "keychain", message: "登录凭据无法读取，请重新登录。") }
        return try JSONDecoder().decode(CloudCredential.self, from: data)
    }
    func write(_ credential: CloudCredential, serverID: String) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query(serverID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(serverID); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(q as CFDictionary, nil))
        } else { try check(status) }
    }
    func remove(serverID: String) throws {
        let status = SecItemDelete(query(serverID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

protocol CloudBootstrapSource {
    var isAvailable: Bool { get }
    func read() throws -> String
    func consume(_ token: String) throws
}

struct CloudBootstrapFile: CloudBootstrapSource {
    let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hero OOS", isDirectory: true).appendingPathComponent("cloud-bootstrap-token")) { self.url = url }
    var isAvailable: Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? 0) > 0 && (values.fileSize ?? 0) <= 1024
    }
    func read() throws -> String {
        guard isAvailable else { throw CloudAccountError(code: "bootstrap_missing", message: "本机没有有效的管理员初始化凭据。") }
        let value = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else {
            throw CloudAccountError(code: "bootstrap_invalid", message: "管理员初始化凭据无效。")
        }
        return value
    }
    func consume(_ token: String) throws {
        // Do not delete a newer or replaced setup credential.
        guard try read() == token else { throw CloudAccountError(code: "bootstrap_changed", message: "初始化文件已变化，未删除新文件。") }
        try FileManager.default.removeItem(at: url)
    }
}

@MainActor final class CloudAccount: ObservableObject {
    @Published private(set) var session: CloudSession?
    @Published private(set) var members: [CloudMember] = []
    @Published private(set) var busy = false
    @Published private(set) var bootstrapAvailable = false
    @Published var error: String?
    @Published var message: String?
    let api: CloudAPI
    private let credentials: any CloudCredentialStore
    private let bootstrap: any CloudBootstrapSource
    private var token: String?
    private var restoreValidation: Task<Void, Never>?
    private var credentialGeneration = 0
    var userID: String? { session?.user.id }
    var organizationID: String? { session?.organization.id }
    var identityKey: String? {
        guard let userID, let organizationID else { return nil }
        return "\(api.serverID)|\(organizationID)|\(userID)"
    }
    var canManageMembers: Bool { session?.organization.canManageMembers == true }
    init(api: CloudAPI = CloudAPI(), credentials: any CloudCredentialStore = CloudKeychainStore(), bootstrap: any CloudBootstrapSource = CloudBootstrapFile()) {
        self.api = api; self.credentials = credentials; self.bootstrap = bootstrap
        bootstrapAvailable = bootstrap.isAvailable
    }

    static func validate(organization: String, username: String, password: String) throws {
        guard (1...64).contains(organization.count) else { throw CloudAccountError(code: "invalid_input", message: "组织名需为 1–64 个字符。") }
        guard username.range(of: "^[A-Za-z0-9][A-Za-z0-9_.@-]{2,63}$", options: .regularExpression) != nil else {
            throw CloudAccountError(code: "invalid_input", message: "账号需为 3–64 位字母、数字或 _ . @ -，且以字母或数字开头。")
        }
        guard (12...128).contains(password.count) else { throw CloudAccountError(code: "invalid_input", message: "密码需为 12–128 个字符。") }
    }

    private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do { try await operation(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func decoded<T: Decodable>(_ type: T.Type, from json: JSON) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(json)) }
        catch { throw CloudAccountError(code: "invalid_response", message: "服务器返回的账号信息不完整，请稍后重试。") }
    }
    private func accept(_ payload: JSON) async throws {
        let next = try decoded(CloudSession.self, from: payload)
        let nextToken = payload["token"].string
        guard !nextToken.isEmpty, !next.user.id.isEmpty, !next.organization.id.isEmpty else {
            throw CloudAccountError(code: "invalid_response", message: "服务器没有返回有效登录会话。")
        }
        do {
            try credentials.write(CloudCredential(token: nextToken, userID: next.user.id, organizationID: next.organization.id, cachedSession: next), serverID: api.serverID)
        } catch {
            _ = try? await api.request("/v1/auth/logout", method: "POST", token: nextToken)
            throw error
        }
        credentialGeneration += 1; restoreValidation?.cancel()
        token = nextToken; session = next; members = []
    }
    @discardableResult func login(organization: String, username: String, password: String) async -> Bool {
        await perform {
            let org = organization.trimmingCharacters(in: .whitespacesAndNewlines), user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validate(organization: org, username: user, password: password)
            let result = try await api.request("/v1/auth/login", method: "POST", body: ["organization": .string(org), "username": .string(user), "password": .string(password)])
            try await accept(result)
            message = "已登录。现有本地任务保持原样。"
        }
    }
    @discardableResult func register(organization: String, username: String, password: String) async -> Bool {
        await perform {
            let org = organization.trimmingCharacters(in: .whitespacesAndNewlines), user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validate(organization: org, username: user, password: password)
            _ = try await api.request("/v1/auth/register", method: "POST", body: ["organization": .string(org), "username": .string(user), "password": .string(password)])
            message = "注册申请已提交，等待组织管理员审批；通过后即可登录。"
        }
    }
    @discardableResult func bootstrapAdministrator(organization: String = "Example Org", username: String, password: String, confirmation: String) async -> Bool {
        await perform {
            guard password == confirmation else { throw CloudAccountError(code: "invalid_input", message: "两次输入的密码不一致。") }
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validate(organization: organization, username: user, password: password)
            let setupToken = try bootstrap.read()
            let result = try await api.request("/v1/auth/bootstrap", method: "POST", body: ["bootstrapToken": .string(setupToken), "organization": .string(organization.trimmingCharacters(in: .whitespacesAndNewlines)), "username": .string(user), "password": .string(password)])
            try await accept(result)
            do { try bootstrap.consume(setupToken) }
            catch { self.error = "管理员已创建并登录，但本机初始化凭据清理失败；请联系维护人员清理。" }
            bootstrapAvailable = bootstrap.isAvailable
            message = "组织管理员设置完成。现有本地任务保持原样。"
        }
    }
    func restoreSession(validateInBackground: Bool = false) async {
        _ = await perform {
            bootstrapAvailable = bootstrap.isAvailable
            guard let saved = try credentials.read(serverID: api.serverID) else { return }
            credentialGeneration += 1
            let generation = credentialGeneration
            restoreValidation?.cancel()
            if validateInBackground, !saved.token.isEmpty,
               let cached = saved.cachedSession, !saved.userID.isEmpty, !saved.organizationID.isEmpty,
               cached.user.id == saved.userID, cached.organization.id == saved.organizationID {
                // Open only this previously authenticated local cache immediately. Every cloud
                // request still authenticates server-side; an explicit revocation clears it.
                token = saved.token; session = cached
                message = "已打开本机缓存；正在后台确认服务端连接，不影响本机工作。"
                restoreValidation = Task { [weak self] in
                    guard let self else { return }
                    do { try await self.validateRestoredSession(saved, generation: generation) }
                    catch {
                        guard generation == self.credentialGeneration, !Task.isCancelled else { return }
                        self.error = error.localizedDescription
                    }
                }
                return
            }
            try await validateRestoredSession(saved, generation: generation)
        }
    }
    private func validateRestoredSession(_ saved: CloudCredential, generation: Int) async throws {
            do {
                let value = try await api.request("/v1/me", token: saved.token)
                guard generation == credentialGeneration, !Task.isCancelled else { return }
                let restored = try decoded(CloudSession.self, from: value)
                guard restored.user.id == saved.userID, restored.organization.id == saved.organizationID else {
                    throw CloudAccountError(code: "invalid_session", message: "会话身份不一致，请重新登录。")
                }
                token = saved.token; session = restored
                message = "账号已获服务端确认。"
            } catch {
                guard generation == credentialGeneration, !Task.isCancelled else { return }
                if let cloud = error as? CloudAccountError, ["unauthorized", "http_401", "invalid_session"].contains(cloud.code) {
                    token = nil; session = nil; members = []
                    try credentials.remove(serverID: api.serverID)
                } else if (error is URLError || (error as? CloudAccountError)?.code.hasPrefix("http_5") == true),
                          let cached = saved.cachedSession, cached.user.id == saved.userID, cached.organization.id == saved.organizationID {
                    token = saved.token; session = cached
                    message = "当前离线，已恢复此账号在本机的缓存；联网后继续验证与同步。"
                }
                throw error
            }
    }
    func authorizedAPI(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON {
        guard let token, session != nil else { throw CloudAccountError(code: "unauthorized", message: "请先登录云端账号。") }
        let identity = identityKey
        do {
            let result = try await api.request(path, method: method, body: body, token: token)
            guard self.token == token, identityKey == identity else {
                throw CloudAccountError(code: "session_changed", message: "账号或组织已切换，已丢弃旧会话响应。")
            }
            return result
        }
        catch {
            if self.token == token, let cloud = error as? CloudAccountError, ["unauthorized", "http_401"].contains(cloud.code) {
                credentialGeneration += 1; restoreValidation?.cancel()
                self.token = nil; session = nil; members = []
                try? credentials.remove(serverID: api.serverID)
            }
            throw error
        }
    }
    /// A bound request, rather than an exposed token getter, is shared with the SSE transport.
    func eventRequest(identity: String) throws -> URLRequest {
        guard identityKey == identity, !identity.isEmpty, let token, session != nil,
              !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw CloudAccountError(code: "unauthorized", message: "请先确认当前云端账号。")
        }
        var request = URLRequest(url: try api.requestURL("/v1/events"), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 75)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }
    func eventRequestIsCurrent(_ request: URLRequest, identity: String) -> Bool {
        guard identityKey == identity, let token, session != nil,
              let expected = try? api.requestURL("/v1/events") else { return false }
        return request.url == expected && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
    }
    func rejectEventRequest(_ request: URLRequest, identity: String, error: Error) {
        guard eventRequestIsCurrent(request, identity: identity),
              let code = (error as? CloudAccountError)?.code, ["unauthorized", "forbidden"].contains(code) else { return }
        credentialGeneration += 1; restoreValidation?.cancel()
        token = nil; session = nil; members = []
        try? credentials.remove(serverID: api.serverID)
    }
    func logout() async {
        _ = await perform {
            let oldToken = token
            // If Keychain refuses removal, keep the visible session so the user can retry.
            try credentials.remove(serverID: api.serverID)
            credentialGeneration += 1; restoreValidation?.cancel()
            token = nil; session = nil; members = []
            if let oldToken {
                do { _ = try await api.request("/v1/auth/logout", method: "POST", token: oldToken) }
            catch { message = "已从本机退出。服务器暂不可达，未能确认服务端会话已撤销。"; return }
            }
            message = "已退出云端账号。本地任务未删除。"
        }
    }
    func refreshAccount() async {
        _ = await perform {
            let result = try await authorizedAPI("/v1/me")
            let next = try decoded(CloudSession.self, from: result)
            guard next.user.id == userID, next.organization.id == organizationID else {
                throw CloudAccountError(code: "invalid_session", message: "服务器账号身份已变化，请重新登录。")
            }
            session = next
            if canManageMembers { try await loadMembers() } else { members = [] }
        }
    }
    private func loadMembers() async throws {
        let result = try await authorizedAPI("/v1/members")
        members = try decoded([CloudMember].self, from: result["members"])
    }
    @discardableResult func joinOrganization(_ name: String) async -> Bool {
        await perform {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...64).contains(name.count) else { throw CloudAccountError(code: "invalid_input", message: "请输入 1–64 个字符的组织名。") }
            _ = try await authorizedAPI("/v1/organizations/join", method: "POST", body: ["organization": .string(name)])
            let result = try await authorizedAPI("/v1/organizations")
            session?.memberships = try decoded([CloudMembership].self, from: result["memberships"])
            message = "加入申请已提交，等待该组织管理员审批。"
        }
    }
    func updateMember(_ member: CloudMember, status: String, role: String) async {
        _ = await perform {
            guard canManageMembers, member.userId != userID, member.role != "owner",
                  ["approved", "rejected", "suspended"].contains(status), ["member", "admin"].contains(role),
                  member.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw CloudAccountError(code: "forbidden", message: "无法执行这项成员管理操作。")
            }
            _ = try await authorizedAPI("/v1/members/\(member.id)", method: "PATCH", body: ["status": .string(status), "role": .string(role)])
            try await loadMembers(); message = "成员权限已更新。"
        }
    }
    @discardableResult func renameOrganization(_ name: String) async -> Bool {
        await perform {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard session?.organization.role == "owner", (1...64).contains(name.count) else {
                throw CloudAccountError(code: "forbidden", message: "仅组织所有者可修改名称，名称需为 1–64 个字符。")
            }
            _ = try await authorizedAPI("/v1/organization", method: "PATCH", body: ["name": .string(name)])
            session = try decoded(CloudSession.self, from: await authorizedAPI("/v1/me"))
            message = "组织名称已修改；组织身份和成员关系保持不变。"
        }
    }
}
