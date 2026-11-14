import Foundation
import Darwin

/// Same-UID Unix socket; no TCP listener, shell evaluation or new gateway
/// connection. Four bounded readers leave capacity for Stop during a snapshot.
final class ROBLocalControlSocket {
    typealias Handler = (Data, @escaping (Data) -> Void) -> Void
    private let queue = DispatchQueue(label: "rob.local-control.accept")
    private var source: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var clients = Set<Int32>()
    private var path: String?
    private var socketInode: UInt64?

    func start(directory: URL, handler: @escaping Handler) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw ROBLocalControlError("Local control directory must be owned by the current user and not be a symlink")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("control.sock").path
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ROBLocalControlError("Local socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyBytes(from: $0) } }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ROBLocalControlError("Cannot create local socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var keep = false
        defer { if !keep { Darwin.close(fd) } }
        if let prior = try? fm.attributesOfItem(atPath: path) {
            guard prior[.type] as? FileAttributeType == .typeSocket,
                  (prior[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw ROBLocalControlError("Refusing to replace a non-socket local path")
            }
            let connected = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
            }
            guard connected != 0, errno == ECONNREFUSED else { throw ROBLocalControlError("Another Cerebro instance owns local control") }
            try fm.removeItem(atPath: path)
        }
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard bound == 0 else { throw ROBLocalControlError("Local socket bind failed: \(errno)") }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        guard listen(fd, 8) == 0 else { unlink(path); throw ROBLocalControlError("Local socket listen failed") }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        socketInode = (try fm.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.uint64Value
        self.path = path; socketFD = fd; keep = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(handler: handler) }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source; source.resume()
    }

    func stop() {
        queue.sync {
            source?.cancel(); source = nil; socketFD = -1
            for client in clients { shutdown(client, SHUT_RDWR) }
            if let path, let inode = socketInode,
               (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.uint64Value == inode { unlink(path) }
            path = nil; socketInode = nil
        }
    }
    private func acceptClients(handler: @escaping Handler) {
        while socketFD >= 0 {
            let fd = accept(socketFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard clients.count < 4, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); continue }
            clients.insert(fd)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, 0)
            var timeout = timeval(tv_sec: 3, tv_usec: 0), yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var data = Data(), storage = [UInt8](repeating: 0, count: 4096)
                while data.count <= 32_768 {
                    let n = Darwin.read(fd, &storage, min(storage.count, 32_769-data.count))
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { self?.finish(fd); return }
                    data.append(contentsOf: storage.prefix(n))
                    if let end = data.firstIndex(of: 10) {
                        guard end == data.count-1, end <= 32_768 else { self?.finish(fd); return }
                        handler(Data(data.prefix(end))) { reply in
                            DispatchQueue.global(qos: .userInitiated).async {
                                let payload = reply + Data([10])
                                payload.withUnsafeBytes { raw in
                                    var sent = 0
                                    while sent < raw.count {
                                        let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count-sent)
                                        if n < 0 && errno == EINTR { continue }
                                        if n <= 0 { break }; sent += n
                                    }
                                }
                                self?.finish(fd)
                            }
                        }
                        return
                    }
                }
                self?.finish(fd)
            }
        }
    }
    private func finish(_ fd: Int32) { queue.async { if self.clients.remove(fd) != nil { Darwin.close(fd) } } }
}
