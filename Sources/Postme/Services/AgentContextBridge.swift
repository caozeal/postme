import Foundation
import Darwin

/// Session-only, same-user Unix socket. Each connection reads one atomic MainActor snapshot.
/// No command payload is accepted, so this bridge cannot mutate or send a request.
final class AgentContextBridge {
    private var source: DispatchSourceRead?
    private let path: String
    private var lockFD: Int32 = -1
    init(directory: URL) { path = directory.appendingPathComponent("agent-context.sock").path }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw CLIError("Agent context socket path is too long.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: Array(path.utf8))
        }
        return address
    }

    func start(snapshot: @escaping @MainActor () -> Data) throws {
        var address = try Self.address(path)
        let lease = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0 else { throw CLIError("Cannot lock context endpoint.") }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { close(lease); throw CLIError("Another GUI owns the context endpoint.") }
        var started = false
        defer { if !started { flock(lease, LOCK_UN); close(lease) } }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
                throw CLIError("Unsafe existing context endpoint.")
            }
            guard unlink(path) == 0 else { throw CLIError("Cannot clear stale context endpoint.") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("Cannot create context socket.") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // The process lease serializes endpoint ownership and stale-socket recovery.
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let reason = String(cString: strerror(errno)); close(fd); throw CLIError("Context socket unavailable: \(reason)") }
        guard chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd); unlink(path); throw CLIError("Cannot protect context socket.")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let queue = DispatchQueue(label: "dev.postme.agent-context")
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var uid: uid_t = 0; var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            Task { @MainActor in
                let data = snapshot()
                queue.async {
                    defer { close(client) }
                    data.withUnsafeBytes { bytes in
                        var sent = 0
                        while sent < bytes.count {
                            let n = Darwin.write(client, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                            guard n > 0 else { break }
                            sent += n
                        }
                    }
                }
            }
        }
        reader.setCancelHandler { close(fd) }
        source = reader
        lockFD = lease
        started = true
        reader.resume()
    }
    func stop() {
        guard source != nil else { return }
        source?.cancel(); source = nil
        unlink(path)
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
    deinit { stop() }

    static func read(directory: URL) throws -> Data {
        var address = try address(directory.appendingPathComponent("agent-context.sock").path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("Cannot create context connection.") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw CLIError("Open Postme and enable Agent context in Settings for this session.", code: "context_unavailable") }
        var peerUID: uid_t = 0; var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            throw CLIError("Context endpoint belongs to another user.")
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n == 0 { break }
            guard n > 0 else { throw CLIError("Context read timed out.", code: "context_unavailable") }
            data.append(contentsOf: buffer.prefix(n))
            guard data.count <= 256 * 1024 else { throw CLIError("Context response exceeded limit.") }
        }
        _ = try JSONSerialization.jsonObject(with: data)
        return data
    }
}

/// Deliberately conservative export: raw body/SSE text and all header values are withheld.
/// JSON bodies expose structure and primitive values except sensitive keys; opt-in UI explains limits.
enum AgentContextSanitizer {
    static func sensitive(_ key: String) -> Bool {
        let key = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["token", "secret", "password", "passwd", "authorization", "cookie", "apikey", "credential", "session", "email", "phone"].contains { key.contains($0) }
    }
    static func json(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 12 else { return "[depth limit]" }
        if let object = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: object.sorted { $0.key < $1.key }.prefix(100).map {
                ($0.key, sensitive($0.key) ? "[redacted]" : json($0.value, depth: depth + 1))
            })
        }
        if let array = value as? [Any] { return array.prefix(100).map { json($0, depth: depth + 1) } }
        // Free-form strings can contain unlabelled credentials or private data.
        if value is String { return "[string withheld]" }
        return value
    }
    static func body(_ data: Data) -> [String: Any] {
        guard data.count <= 32 * 1024, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return ["omitted": true, "reason": "non_json_or_over_32KiB", "bytes": data.count]
        }
        return ["json": json(object), "bytes": data.count, "redacted": true, "exportMayBeIncomplete": true]
    }
}
