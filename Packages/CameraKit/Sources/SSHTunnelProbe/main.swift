// sshtunnel-probe <host> <user>
// Password from env SSHTUNNEL_PASSWORD. CAMCTL_SSH_FINGERPRINT, if set, is the host key fingerprint the camera must
// present; unset, the later steps hold it to the one it presented on the first connect. SSHTUNNEL_PORT, if set, is the
// SSH port (a camera's is 22): an sshd of one's own, set to a camera's algorithms, on another.
// Runs five verification steps against the live camera.
import Foundation
import SSHTunnel
import CSSH

func die(_ msg: String) -> Never { fputs("FAIL: \(msg)\n", stderr); exit(1) }

let args = CommandLine.arguments
guard args.count >= 3 else { die("usage: sshtunnel-probe <host> <user>") }
let cameraHost = args[1]
let user       = args[2]
guard let password = ProcessInfo.processInfo.environment["SSHTUNNEL_PASSWORD"],
      !password.isEmpty else { die("SSHTUNNEL_PASSWORD not set") }
let sshPort = Int32(ProcessInfo.processInfo.environment["SSHTUNNEL_PORT"] ?? "") ?? 22

// ---------- Step 1: TCP connect ----------
print("Step 1: TCP connect to \(cameraHost):\(sshPort) … ", terminator: "")
do {
    var hints = addrinfo()
    hints.ai_family   = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(cameraHost, String(sshPort), &hints, &res) == 0, let info = res else { die("getaddrinfo") }
    let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard fd >= 0 else { die("socket") }
    guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
        die("connect errno \(errno)")
    }
    Darwin.close(fd)
    freeaddrinfo(res)
    print("OK")
}

// ---------- Steps 2-5: full SSH session with first-connect (no expected fingerprint) ----------
print("Step 2-3: handshake + fingerprint (first-connect, no expected FP) … ", terminator: "")
let probe1 = SSHPortForwarder(host: cameraHost, port: sshPort, username: user, password: password,
                               expectedFingerprint: nil)
let localPort: UInt16
do {
    localPort = try await probe1.start()
    print("OK  observed=\(probe1.observedFingerprint)")
} catch {
    die("start() threw: \(error)")
}
probe1.stop()
let knownFP = ProcessInfo.processInfo.environment["CAMCTL_SSH_FINGERPRINT"].flatMap { $0.isEmpty ? nil : $0 }
    ?? probe1.observedFingerprint

// ---------- Step 3b: wrong fingerprint rejected BEFORE auth ----------
print("Step 3b: wrong expected fingerprint rejected before auth … ", terminator: "")
let wrongFP  = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
let probeWrong = SSHPortForwarder(host: cameraHost, port: sshPort, username: user, password: password,
                                   expectedFingerprint: wrongFP)
do {
    _ = try await probeWrong.start()
    die("expected fingerprintMismatch, got success")
} catch SSHTunnelError.fingerprintMismatch(let obs) {
    print("OK  (rejected, observed=\(obs))")
} catch {
    die("unexpected error: \(error)")
}

// ---------- Step 4a: auth with known good fingerprint ----------
print("Step 4a: keyboard-interactive auth with correct password … ", terminator: "")
let probeGood = SSHPortForwarder(host: cameraHost, port: sshPort, username: user, password: password,
                                  expectedFingerprint: knownFP)
let goodPort: UInt16
do {
    goodPort = try await probeGood.start()
    print("OK  local port \(goodPort)")
} catch {
    die("auth failed: \(error)")
}

// Exactly one PTP-IP check. The FX3 serves one PTP-IP initiator at a time, and an Init_Command_Request that
// never becomes a session holds that slot for a while: a second check, or a camctl run straight after, can
// see the connection closed with no answer even though the tunnel is fine.
print("Step 4c: PTP-IP Init_Command_Request through the tunnel … ", terminator: "")
guard let answer4c = ptpInitThroughTunnel(port: goodPort) else { die("no PTP-IP answer through the tunnel") }
print("OK  (\(answer4c))")

// ---------- Step 4b: wrong password ----------
print("Step 4b: wrong password fails cleanly … ", terminator: "")
let probeBad = SSHPortForwarder(host: cameraHost, port: sshPort, username: user, password: "definitely_wrong_pw",
                                 expectedFingerprint: knownFP)
do {
    _ = try await probeBad.start()
    die("expected authenticationFailed, got success")
} catch SSHTunnelError.authenticationFailed {
    print("OK  (rejected as expected)")
} catch {
    die("unexpected error: \(error)")
}

probeGood.stop()

print("\nAll steps passed.")


/// Send a PTP-IP Init_Command_Request through the tunnel's local port and read the reply header. Returns the
/// reply kind, or nil if the tunnel closed without answering. An earlier Step 5 only connected and closed, and
/// passed while every real PTP-IP connection through the tunnel was reset (channel target "127.0.0.1").
func ptpInitThroughTunnel(port: UInt16) -> String? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = UInt32(bigEndian: 0x7f000001)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else { return nil }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var request = [UInt8]()
    func le32(_ v: UInt32) { for i in 0..<4 { request.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    let name: [UInt8] = "sshtunnel-probe".utf16.flatMap { unit -> [UInt8] in [UInt8(unit & 0xFF), UInt8(unit >> 8)] } + [0, 0]
    le32(UInt32(8 + 16 + name.count + 4))
    le32(1)                                                      // Init_Command_Request
    request += (0..<16).map { _ in UInt8.random(in: 0...255) }   // GUID
    request += name
    le32(0x0001_0000)                                            // protocol version 1.0
    guard send(fd, request, request.count, 0) == request.count else { return nil }
    var header = [UInt8](repeating: 0, count: 8)
    guard recv(fd, &header, 8, MSG_WAITALL) == 8 else { return nil }
    let type = UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24
    return type == 2 ? "Init_Command_Ack" : type == 5 ? "Init_Fail: the camera answered and refused this GUID" : "packet type \(type)"
}
