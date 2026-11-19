import Foundation
import os
import CSSH

// MARK: - Public errors

public enum SSHTunnelError: Error, Sendable {
    case unreachable(underlying: any Error)
    case handshakeFailed(code: Int32)
    case fingerprintMismatch(observed: String)
    case authenticationFailed
    case listenerFailed(message: String)
    /// The camera took the connection but stopped answering: still holding the session from before the iPad slept,
    /// say. Waiting longer doesn't help; a fresh attempt does.
    case timedOut
}

// MARK: - Public API

/// Opens a localhost listener on an ephemeral port and tunnels each accepted
/// TCP connection through a libssh2 direct-tcpip channel to the camera's
/// localhost:15740.  All libssh2 work is pinned to a single dedicated thread.
public final class SSHPortForwarder: Sendable {

    public let host: String
    public let port: Int32
    public let username: String

    private let _core: _SSHCore

    /// SHA256:… fingerprint observed during the last successful handshake,
    /// in the same format OpenSSH prints (e.g. SHA256:kexL4bT…).
    public var observedFingerprint: String { _core.observedFingerprint }

    public init(
        host: String,
        port: Int32 = 22,
        username: String,
        password: String,
        expectedFingerprint: String? = nil,
        connectTimeout: TimeInterval = 15
    ) {
        self.host = host
        self.port = port
        self.username = username
        self._core = _SSHCore(
            host: host, port: port,
            username: username, password: password,
            expectedFingerprint: expectedFingerprint, connectTimeout: connectTimeout
        )
    }

    /// Connects, authenticates and starts the listener.
    /// Throws *before* sending credentials if the fingerprint doesn't match.
    /// - Returns: ephemeral local port to connect PTP-IP to.
    public func start() async throws -> UInt16 {
        try await _core.start()
    }

    public func stop() {
        _core.stop()
    }
}

// MARK: - _SSHCore

/// All libssh2 calls are serialized on a single dedicated Thread.
final class _SSHCore: @unchecked Sendable {

    private var session: OpaquePointer?
    private var sessionFd: Int32 = -1
    private var listenerFd: Int32 = -1
    private var listenerPort: UInt16 = 0
    private var channels: [_Channel] = []
    /// Read by the SSH thread every pass, written by stop() from any thread.
    private let runningFlag = OSAllocatedUnfairLock(initialState: false)
    private var running: Bool { runningFlag.withLock { $0 } }
    private(set) var observedFingerprint: String = ""

    private let host: String
    private let port: Int32
    private let username: String
    private let password: String
    private let expectedFingerprint: String?
    /// Connect, handshake and log in all have to finish within this.
    private let connectTimeout: TimeInterval
    /// libssh2_init is counted; only an attempt that made the call may make the matching libssh2_exit.
    private var libssh2Initialized = false

    init(host: String, port: Int32, username: String, password: String, expectedFingerprint: String?,
         connectTimeout: TimeInterval) {
        self.connectTimeout = connectTimeout
        self.host = host; self.port = port
        self.username = username; self.password = password
        self.expectedFingerprint = expectedFingerprint
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            let t = Thread { self._sshThread(cont) }
            t.name = "com.vv.sshtunnel.ssh"
            t.qualityOfService = .userInitiated
            t.start()
        }
    }

    func stop() {
        // Only signal: the SSH thread notices within one pass and does all the closing, so no fd is closed twice
        // or closed while that thread is still using it.
        runningFlag.withLock { $0 = false }
    }

    // MARK: - SSH thread

    private func _sshThread(_ cont: CheckedContinuation<UInt16, any Error>) {
        do {
            let p = try _connectAuth()
            runningFlag.withLock { $0 = true }
            cont.resume(returning: p)
            _runLoop()
        } catch {
            _teardown()   // a half-open attempt would keep the camera's SSH session busy for the next one
            cont.resume(throwing: error)
        }
    }

    private func _connectAuth() throws -> UInt16 {
        let deadline = Date().addingTimeInterval(connectTimeout)
        sessionFd = try _tcpConnect(host: host, port: port, timeout: min(5, connectTimeout))

        guard libssh2_init(0) == 0 else { throw SSHTunnelError.handshakeFailed(code: -1) }
        libssh2Initialized = true
        guard let sess = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHTunnelError.handshakeFailed(code: -2)
        }
        session = sess
        libssh2_session_set_blocking(sess, 0)
        libssh2_keepalive_config(sess, 0, 60)

        // Handshake
        var rc: Int32
        repeat {
            rc = libssh2_session_handshake(sess, sessionFd)
            if rc == LIBSSH2_ERROR_EAGAIN { try _waitSocket(until: deadline) }
        } while rc == LIBSSH2_ERROR_EAGAIN
        guard rc == 0 else { throw SSHTunnelError.handshakeFailed(code: rc) }

        // Fingerprint — checked BEFORE sending credentials
        guard let fpBytes = libssh2_hostkey_hash(sess, LIBSSH2_HOSTKEY_HASH_SHA256) else {
            throw SSHTunnelError.handshakeFailed(code: -3)
        }
        let fpData = Data(bytes: fpBytes, count: 32)
        // OpenSSH's form, unpadded base64 ("SHA256:kexL…oqM"), so it reads the same as `ssh-keygen -l` and the
        // fingerprint stored in a keychain or credential store. Padding is ignored when comparing, so a pin
        // saved in either form matches.
        let observed = canonicalFingerprint("SHA256:" + fpData.base64EncodedString())
        observedFingerprint = observed
        if let expected = expectedFingerprint, canonicalFingerprint(expected) != observed {
            libssh2_session_disconnect_ex(sess, SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE, "fingerprint mismatch", "")
            libssh2_session_free(sess); session = nil
            Darwin.close(sessionFd); sessionFd = -1
            throw SSHTunnelError.fingerprintMismatch(observed: observed)
        }

        // keyboard-interactive auth
        try _authKbd(sess: sess, deadline: deadline)

        // Local listener
        listenerFd = try _bindLoopback()
        return listenerPort
    }

    // MARK: - Keyboard-interactive auth

    private func _authKbd(sess: OpaquePointer, deadline: Date) throws {
        // Store the password string in the session's abstract slot so the C callback can reach it.
        // abstract is a void** inside the session; we point it at a heap-allocated CString.
        let cpass = strdup(password)
        defer { free(cpass) }
        libssh2_session_abstract(sess).pointee = UnsafeMutableRawPointer(cpass)
        defer { libssh2_session_abstract(sess).pointee = nil }   // before the free above, on every way out

        var rc: Int32
        repeat {
            rc = libssh2_userauth_keyboard_interactive_ex(
                sess,
                username,
                UInt32(username.utf8.count),
                _kbdCallback
            )
            if rc == LIBSSH2_ERROR_EAGAIN { try _waitSocket(until: deadline) }
        } while rc == LIBSSH2_ERROR_EAGAIN

        guard rc == 0 else { throw SSHTunnelError.authenticationFailed }
    }

    // MARK: - Run loop

    private func _runLoop() {
        while running {
            var maxfd = max(sessionFd, listenerFd)
            for ch in channels { maxfd = max(maxfd, ch.clientFd) }

            var rfds = fd_set(); _fdZero(&rfds)
            _fdSet(sessionFd, set: &rfds)
            _fdSet(listenerFd, set: &rfds)
            for ch in channels { _fdSet(ch.clientFd, set: &rfds) }

            var tv = timeval(tv_sec: 0, tv_usec: 50_000)
            _ = select(maxfd + 1, &rfds, nil, nil, &tv)

            // Accept new connections
            _acceptPending()

            // Pump channels
            channels = channels.filter { _pump(ch: $0) }

            // Keepalive
            if let s = session { var next: Int32 = 0; libssh2_keepalive_send(s, &next) }
        }
        _teardown()
    }

    private func _acceptPending() {
        var rfds = fd_set(); _fdZero(&rfds); _fdSet(listenerFd, set: &rfds)
        var tv0 = timeval(tv_sec: 0, tv_usec: 0)
        while select(listenerFd + 1, &rfds, nil, nil, &tv0) > 0 {
            var addr = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenerFd, $0, &len)
                }
            }
            guard fd >= 0 else { break }
            _openChannel(clientFd: fd)
            _fdZero(&rfds); _fdSet(listenerFd, set: &rfds)
        }
    }

    private func _openChannel(clientFd: Int32) {
        guard let sess = session else { Darwin.close(clientFd); return }
        var ch: OpaquePointer?
        let deadline = Date().addingTimeInterval(10)
        repeat {
            // "localhost", exactly as Sony documents it (`-L 15740:localhost:15740`). The FX3
            // refuses a channel to "127.0.0.1": the PTP-IP connection was reset after Init_Command_Request.
            ch = libssh2_channel_direct_tcpip_ex(
                sess, "localhost", 15740, "127.0.0.1", Int32(listenerPort)
            )
            if ch == nil && libssh2_session_last_errno(sess) == LIBSSH2_ERROR_EAGAIN {
                guard running, (try? _waitSocket(until: deadline)) != nil else { Darwin.close(clientFd); return }
            }
        } while ch == nil && libssh2_session_last_errno(sess) == LIBSSH2_ERROR_EAGAIN
        guard let channel = ch else { Darwin.close(clientFd); return }
        channels.append(_Channel(clientFd: clientFd, channel: channel))
    }

    /// Returns true if the channel should remain alive.
    private func _pump(ch: _Channel) -> Bool {
        var buf = [UInt8](repeating: 0, count: 32_768)

        // SSH → client
        let nr = libssh2_channel_read_ex(ch.channel, 0, &buf, buf.count)
        if nr > 0 {
            _ = buf.withUnsafeBytes { ptr in
                Darwin.send(ch.clientFd, ptr.baseAddress, nr, 0)
            }
        } else if nr < 0 && nr != Int(LIBSSH2_ERROR_EAGAIN) {
            _closeChannel(ch); return false
        }

        // client → SSH (non-blocking peek)
        var rfds = fd_set(); _fdZero(&rfds); _fdSet(ch.clientFd, set: &rfds)
        var tv0 = timeval(tv_sec: 0, tv_usec: 0)
        if select(ch.clientFd + 1, &rfds, nil, nil, &tv0) > 0 {
            let nc = recv(ch.clientFd, &buf, buf.count, 0)
            if nc > 0 {
                var sent = 0
                while sent < nc {
                    let w = buf.withUnsafeBytes { ptr in
                        libssh2_channel_write_ex(
                            ch.channel, 0,
                            ptr.baseAddress!.advanced(by: sent).assumingMemoryBound(to: CChar.self),
                            nc - sent
                        )
                    }
                    if w > 0 { sent += w }
                    else if w < 0 && w != Int(LIBSSH2_ERROR_EAGAIN) { _closeChannel(ch); return false }
                }
            } else if nc == 0 {
                _closeChannel(ch); return false
            }
        }

        if libssh2_channel_eof(ch.channel) != 0 { _closeChannel(ch); return false }
        return true
    }

    private func _closeChannel(_ ch: _Channel) {
        libssh2_channel_close(ch.channel)
        libssh2_channel_free(ch.channel)
        Darwin.close(ch.clientFd)
    }

    private func _teardown() {
        for ch in channels { _closeChannel(ch) }
        channels.removeAll()
        if listenerFd >= 0 { Darwin.close(listenerFd); listenerFd = -1 }
        if let s = session {
            libssh2_session_disconnect_ex(s, SSH_DISCONNECT_BY_APPLICATION, "closed", "")
            libssh2_session_free(s); session = nil
        }
        if sessionFd >= 0 { Darwin.close(sessionFd); sessionFd = -1 }
        if libssh2Initialized { libssh2_exit(); libssh2Initialized = false }
    }

    // MARK: - Socket helpers

    /// Waits for the session socket, but not past `deadline`: a camera that has stopped answering would otherwise be
    /// waited on for good.
    private func _waitSocket(until deadline: Date) throws {
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { throw SSHTunnelError.timedOut }
        guard sessionFd >= 0, let sess = session else { return }
        let dir = libssh2_session_block_directions(sess)
        var rfds = fd_set(), wfds = fd_set(); _fdZero(&rfds); _fdZero(&wfds)
        if dir & LIBSSH2_SESSION_BLOCK_INBOUND  != 0 { _fdSet(sessionFd, set: &rfds) }
        if dir & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { _fdSet(sessionFd, set: &wfds) }
        var tv = timeval(tv_sec: Int(left), tv_usec: Int32(left.truncatingRemainder(dividingBy: 1) * 1_000_000))
        select(sessionFd + 1, &rfds, &wfds, nil, &tv)
    }

    /// Connects within `timeout` seconds (a blocking connect to an address that doesn't answer takes ~75), then hands
    /// back a blocking socket as before.
    private func _tcpConnect(host: String, port: Int32, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family   = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &res) == 0, let info = res else {
            throw SSHTunnelError.unreachable(underlying: NSError(domain: "getaddrinfo", code: Int(errno)))
        }
        defer { freeaddrinfo(res) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else {
            throw SSHTunnelError.unreachable(underlying: POSIXError(.ENOTSOCK))
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var err: Int32 = 0
        if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 {
            err = errno
            if err == EINPROGRESS {
                var wfds = fd_set(); _fdZero(&wfds); _fdSet(fd, set: &wfds)
                var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32(timeout.truncatingRemainder(dividingBy: 1) * 1_000_000))
                if select(fd + 1, nil, &wfds, nil, &tv) == 1 {
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                } else {
                    err = ETIMEDOUT
                }
            }
        }
        guard err == 0 else {
            Darwin.close(fd)
            throw SSHTunnelError.unreachable(underlying: POSIXError(POSIXErrorCode(rawValue: err) ?? .ECONNREFUSED))
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    private func _bindLoopback() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHTunnelError.listenerFailed(message: "socket errno \(errno)") }
        // No SO_REUSEADDR: the port is the kernel's pick (0), so there's nothing to rebind at once, and reuse let the
        // kernel hand this port to an outgoing connection too, which then failed with EADDRINUSE.
        var addr = sockaddr_in()
        addr.sin_family      = sa_family_t(AF_INET)
        addr.sin_port        = 0
        addr.sin_addr.s_addr = UInt32(bigEndian: INADDR_LOOPBACK)
        guard withUnsafePointer(to: &addr, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0 else {
            Darwin.close(fd)
            throw SSHTunnelError.listenerFailed(message: "bind errno \(errno)")
        }
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw SSHTunnelError.listenerFailed(message: "listen errno \(errno)")
        }
        var bound = sockaddr_in(); var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &blen) }
        }
        listenerPort = UInt16(bigEndian: bound.sin_port)
        return fd
    }

    // MARK: - fd_set helpers (Darwin 1024-fd bitmask via raw pointer)

    private func _fdZero(_ s: inout fd_set) { s = fd_set() }

    private func _fdSet(_ fd: Int32, set s: inout fd_set) {
        let word = Int(fd) / 32, bit = Int(fd) % 32
        withUnsafeMutableBytes(of: &s.fds_bits) { ptr in
            let words = ptr.bindMemory(to: Int32.self)
            // Bit 31 is the sign bit: Int32(1 << 31) traps ("Not enough bits"), which crashed whenever a socket's
            // descriptor was 31, 63, 95… (fd_set bit 31 is the sign bit of Int32). Set it as a bit pattern.
            if word < words.count { words[word] |= Int32(bitPattern: UInt32(1) << UInt32(bit)) }
        }
    }

    /// The bit `_fdSet` sets, for its test.
    static func fdBit(_ fd: Int32) -> (word: Int, mask: Int32) {
        (Int(fd) / 32, Int32(bitPattern: UInt32(1) << UInt32(Int(fd) % 32)))
    }
}

// MARK: - _Channel

private struct _Channel {
    let clientFd: Int32
    let channel: OpaquePointer   // LIBSSH2_CHANNEL*
}

// MARK: - C keyboard-interactive callback

/// Passed to libssh2 as the response callback.  The session's `abstract` field
/// must point to a CString containing the password (set up in `_authKbd`).
private let _kbdCallback: @convention(c) (
    UnsafePointer<CChar>?,   // name
    Int32,                   // name_len
    UnsafePointer<CChar>?,   // instruction
    Int32,                   // instruction_len
    Int32,                   // num_prompts
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = {
    _, _, _, _, numPrompts, _, responses, abstract in
    guard numPrompts > 0, let responses, let abstract, let pw = abstract.pointee else { return }
    let pwStr = String(cString: pw.assumingMemoryBound(to: CChar.self))
    for i in 0..<Int(numPrompts) {
        responses[i].text   = strdup(pwStr)
        responses[i].length = UInt32(pwStr.utf8.count)
    }
}

/// "SHA256:<base64>" with surrounding whitespace and base64 padding removed, the way OpenSSH prints it.
public func canonicalFingerprint(_ fingerprint: String) -> String {
    var value = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasSuffix("=") { value.removeLast() }
    return value
}

