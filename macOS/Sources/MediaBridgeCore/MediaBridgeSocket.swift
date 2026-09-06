import Darwin
import Foundation

public enum MediaBridgeFraming {
    public static func readFrame(_ fd: Int32, idleTimeout: TimeInterval? = nil) throws -> Data? {
        guard let header = try readExact(fd, count: 4, timeout: idleTimeout) else { return nil }
        let size = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        guard size > 0, size <= MediaBridgeProtocol.maximumBytes else { throw MediaBridgeError.invalidMessage }
        guard let data = try readExact(fd, count: Int(size), timeout: 1) else { throw MediaBridgeError.closed }
        return data
    }

    public static func writeFrame(_ fd: Int32, data: Data) throws {
        guard !data.isEmpty, data.count <= MediaBridgeProtocol.maximumBytes else { throw MediaBridgeError.invalidMessage }
        var size = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(data)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard n > 0 else { throw MediaBridgeError.closed }
                offset += n
            }
        }
    }

    private static func readExact(_ fd: Int32, count: Int, timeout: TimeInterval?) throws -> Data? {
        var deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { bytes in
            while offset < count {
                try wait(fd, events: Int16(POLLIN), deadline: deadline)
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if n == 0 && offset == 0 { return }
                guard n > 0 else { throw MediaBridgeError.closed }
                offset += n
                if deadline == nil { deadline = ProcessInfo.processInfo.systemUptime + 1 }
            }
        }
        return offset == 0 ? nil : result
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval?) throws {
        while true {
            let remaining = deadline.map { $0 - ProcessInfo.processInfo.systemUptime }
            if let remaining, remaining <= 0 { throw MediaBridgeError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = remaining.map { Int32(min(5000, max(1, $0 * 1000))) } ?? -1
            let result = poll(&descriptor, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0, descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                throw MediaBridgeError.closed
            }
            return
        }
    }
}

public enum MediaBridgeSocket {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/opensteamer/media-bridge-v1", isDirectory: true)
    }
    public static var path: String { directory.appendingPathComponent("socket").path }

    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard path.hasPrefix("/"), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw MediaBridgeError.invalidPath
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return address
    }

    public static func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw MediaBridgeError.invalidPath
        }
    }

    public static func connect(path: String = path) throws -> Int32 {
        try validateDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { throw MediaBridgeError.invalidPath }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MediaBridgeError.unavailable }
        do {
            guard configure(fd) else { throw MediaBridgeError.unavailable }
            var address = try address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw MediaBridgeError.unavailable }
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while true {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { throw MediaBridgeError.timedOut }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
                    if ready < 0 && errno == EINTR { continue }
                    guard ready > 0 else { throw MediaBridgeError.timedOut }
                    var error: Int32 = 0
                    var size = socklen_t(MemoryLayout.size(ofValue: error))
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0,
                          error == 0, descriptor.revents & Int16(POLLNVAL | POLLERR | POLLHUP) == 0 else {
                        throw MediaBridgeError.unavailable
                    }
                    break
                }
            }
            guard sameUser(fd) else { throw MediaBridgeError.unavailable }
            return fd
        } catch { close(fd); throw error }
    }

    @discardableResult
    public static func configure(_ fd: Int32) -> Bool {
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                        socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { return false }
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    public static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
}
