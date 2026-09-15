import Foundation
import CryptoKit
import Security
import Darwin

struct AccessConfiguration: Codable {
    var agents: [AgentIdentity] = []
    var projects: [ResourceProject] = []
}
/// Credentials are never persisted in plaintext. Authority and pending approvals
/// are intentionally session-scoped; restarting cannot resurrect an old approval.
final class AccessStorage {
    let directory: URL
    private var lockDescriptor: Int32 = -1
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = open(directory.appendingPathComponent("broker.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AccessError.storage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw AccessError.storage }
        lockDescriptor = descriptor
    }
    deinit { if lockDescriptor >= 0 { close(lockDescriptor) } }
    func load() throws -> AccessConfiguration {
        let url = directory.appendingPathComponent("identities.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(AccessConfiguration.self, from: Data(contentsOf: url))
    }
    func save(_ configuration: AccessConfiguration) throws {
        let url = directory.appendingPathComponent("identities.json")
        try JSONEncoder().encode(configuration).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func append(_ event: AccessAudit) throws {
        let url = directory.appendingPathComponent("audit.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AccessError.storage }
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        var data = try JSONEncoder().encode(event)
        data.append(0x0a)
        try file.write(contentsOf: data)
        try file.synchronize()
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccessError.storage }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
