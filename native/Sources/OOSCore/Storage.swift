import Foundation
import CryptoKit
import Darwin

public struct RuntimeError: LocalizedError {
    public let code: String
    public let message: String
    public var extra: [String: JSON] = [:]
    public init(_ code: String, _ message: String, _ extra: [String: JSON] = [:]) { self.code = code; self.message = message; self.extra = extra }
    public var errorDescription: String? { message }
    public var payload: JSON { .object(extra.merging(["ok": false, "error": .string(code), "message": .string(message)]) { _, b in b }) }
}

public enum RuntimeDate {
    public static func iso(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    public static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = f.date(from: text) { return value }
        f.formatOptions = [.withInternetDateTime]
        if let value = f.date(from: text) { return value }
        let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = TimeZone(secondsFromGMT: 0); d.dateFormat = "yyyy-MM-dd"; d.isLenient = false
        return text.count == 10 ? d.date(from: text) : nil
    }
}

public struct StateRuntime: Sendable {
    public static var defaultRoot: String {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hero OOS/local", isDirectory: true).path
    }
    public let root: URL
    public init(root: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HERO_OOS_ROOT"] ?? defaultRoot)) { self.root = root.standardizedFileURL }
    public var dataDirectory: URL { root.appendingPathComponent("data", isDirectory: true) }
    func file(_ name: String) -> URL { dataDirectory.appendingPathComponent(name) }
    func readJSON(_ url: URL, fallback: JSON? = nil) throws -> JSON {
        do { return try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url)) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
            if let fallback { return fallback }; throw e
        }
    }
    func atomic(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let fd = open(destination.deletingLastPathComponent().path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
    func writeJSON(_ value: JSON, to url: URL) throws { var data = try value.encoded(pretty: true); data.append(10); try atomic(data, to: url) }

    // flock is released by the kernel after a crash. The legacy lock also excludes old clients during cutover.
    func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = open(file(".runtime.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var acquired = false
        for _ in 0..<200 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            guard errno == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            usleep(25_000)
        }
        guard acquired else { throw RuntimeError("state_busy", "数据正在被另一端修改，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }
        let legacy = file(".state.lock")
        if let owner = try? String(contentsOf: legacy, encoding: .utf8), owner.hasPrefix("swift:") {
            // No Swift writer can hold this lock while we own the kernel lock.
            try FileManager.default.removeItem(at: legacy)
        }
        let marker = Array("swift:\(getpid())".utf8)
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) >= 0 else { throw POSIXError(.EIO) }
        let written = marker.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard written == marker.count, fsync(fd) == 0 else { throw POSIXError(.EIO) }
        var legacyAcquired = false
        for _ in 0..<120 {
            if link(file(".runtime.lock").path, legacy.path) == 0 { legacyAcquired = true; break }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            usleep(25_000)
        }
        guard legacyAcquired else { throw RuntimeError("state_busy", "旧客户端仍持有写入锁。") }
        defer { unlink(legacy.path) }
        try recoverTransaction()
        return try body()
    }

    // The pending transaction is a short-lived recovery record, not a rollback backup.
    func recoverTransaction() throws {
        let pending = file(".pending-transaction.json")
        guard FileManager.default.fileExists(atPath: pending.path) else { return }
        let transaction = try readJSON(pending)
        let next = transaction["state"]
        let current = try readJSON(file("state.json"))
        let expected = transaction["previousVersion"].number
        guard current["meta"]["version"].number == expected || current == next else {
            throw RuntimeError("recovery_conflict", "检测到未完成事务与当前状态冲突，已停止写入。")
        }
        if current != next { try writeJSON(next, to: file("state.json")) }
        var journal = FileManager.default.fileExists(atPath: file("changes.jsonl").path) ? try Data(contentsOf: file("changes.jsonl")) : Data()
        let id = transaction["event"]["mutationId"].string
        let exists = journal.split(separator: 10).contains { line in
            (try? JSONDecoder().decode(JSON.self, from: Data(line)))?["mutationId"].string == id
        }
        if !exists {
            if !journal.isEmpty && journal.last != 10 { throw RuntimeError("journal_corrupt", "变更日志末行不完整，已保留恢复事务。") }
            journal.append(try transaction["event"].encoded()); journal.append(10)
            try atomic(journal, to: file("changes.jsonl"))
        }
        try atomic(Data(currentTruth(next).utf8), to: root.appendingPathComponent("CURRENT_TRUTH.md"))
        try FileManager.default.removeItem(at: pending)
    }
    public func readState() throws -> JSON { try locked { try readJSON(file("state.json")) } }
    public static func hash(_ value: JSON) throws -> String { SHA256.hash(data: try value.encoded()).map { String(format: "%02x", $0) }.joined() }
    static func id(_ prefix: String) -> JSON { .string("\(prefix)-\(UUID().uuidString.lowercased())") }
}
