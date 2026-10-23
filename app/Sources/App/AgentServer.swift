import Foundation

/// Lets the harness's runner drive the browser: a Unix socket that speaks the kit's protocol,
/// one JSON object per line each way. A socket, not a TCP port, so that only this user's
/// processes can reach it (the file is mode 0600) and no web page can.
/// A result handed from the main actor to the thread waiting for it.
private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}

final class AgentServer: @unchecked Sendable {
    static let shared = AgentServer()

    /// Where the socket lives: `ACORN_AGENT_SOCKET`, or the app's data folder.
    static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["ACORN_AGENT_SOCKET"], !path.isEmpty { return path }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("com.acorn.browser/agent.sock").path
    }

    private var listener: Int32 = -1
    private var driver: AgentDriver?

    /// Starts listening. Call once, on the main thread.
    @MainActor
    func start(driver: AgentDriver) {
        guard listener < 0 else { return }
        self.driver = driver
        let path = Self.socketPath

        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        unlink(path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            NSLog("AgentServer: the socket path is too long: %@", path)
            return
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strncpy($0, path, capacity - 1) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("AgentServer: no socket: %s", strerror(errno)); return }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { NSLog("AgentServer: cannot bind: %s", strerror(errno)); close(fd); return }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else { NSLog("AgentServer: cannot listen: %s", strerror(errno)); close(fd); return }
        listener = fd
        NSLog("AgentServer: listening on %@", path)

        Thread.detachNewThread { [self] in
            while true {
                let connection = accept(fd, nil, nil)
                if connection < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    NSLog("AgentServer: accept failed: %s", strerror(errno))
                    return
                }
                // A thread of its own: the read blocks, which a cooperative thread must not.
                Thread.detachNewThread { [self] in serve(connection) }
            }
        }
    }

    /// Reads request lines from one connection and answers each, one at a time. When the
    /// connection ends (the runner finished, or died), the page is given back to the person.
    private func serve(_ connection: Int32) {
        defer {
            close(connection)
            _ = onMain { driver in await driver.detach() }
        }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(connection, &chunk, chunk.count)
            if count <= 0 { return }
            pending.append(chunk, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
                var out = answer(Data(line))
                out.append(0x0A)
                if !write(all: out, to: connection) { return }
            }
        }
    }

    /// Runs `body` with the driver on the main actor and waits for it, from a plain thread.
    private func onMain<Result>(_ body: @escaping @MainActor (AgentDriver) async -> Result) -> Result? {
        guard let driver else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box<Result>()
        Task { @MainActor in
            box.value = await body(driver)
            done.signal()
        }
        done.wait()
        return box.value
    }

    private func answer(_ line: Data) -> Data {
        var reply: [String: Any]
        if let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
           let answered = onMain({ driver in await driver.handle(request) }) {
            reply = answered
        } else {
            reply = ["id": NSNull(), "ok": false, "error": "bad request: not a JSON object"]
        }
        if let data = try? JSONSerialization.data(withJSONObject: reply) { return data }
        let fallback: [String: Any] = ["id": reply["id"] ?? NSNull(), "ok": false, "error": "the reply could not be written as JSON"]
        return (try? JSONSerialization.data(withJSONObject: fallback)) ?? Data("{}".utf8)
    }

    private func write(all data: Data, to connection: Int32) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { buffer -> Bool in
            while offset < buffer.count {
                let written = Darwin.write(connection, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}
