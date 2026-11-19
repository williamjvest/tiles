import Foundation
import Network

// MARK: - WebSocket client

@MainActor
final class ControlClient {
    let id: UUID
    private let connection: NWConnection
    private let tokenStore: ControlServerTokenStore
    private weak var server: ControlServer?

    private var authenticated = false
    private(set) var isSubscribed = false
    private let nwQueue: DispatchQueue

    init(id: UUID, connection: NWConnection, tokenStore: ControlServerTokenStore,
         server: ControlServer) {
        self.id = id
        self.connection = connection
        self.tokenStore = tokenStore
        self.server = server
        self.nwQueue = server.nwQueue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready: self.receive()
                case .failed, .cancelled: self.server?.removeWS(self.id)
                default: break
                }
            }
        }
        connection.start(queue: nwQueue)
    }

    func disconnect() { connection.cancel() }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil { self.server?.removeWS(self.id); return }
                if let context, context.protocolMetadata(definition: NWProtocolWebSocket.definition) != nil {
                    if let data { self.handleFrame(data) }
                }
                self.receive()
            }
        }
    }

    private func handleFrame(_ data: Data) {
        guard let env = try? JSONDecoder().decode(WireClientEnvelope.self, from: data) else {
            sendError(requestID: nil, code: "badRequest", message: "invalid JSON")
            return
        }
        switch env.type {
        case "auth":    handleAuth(env)
        case "subscribe":
            guard authenticated else {
                sendError(requestID: env.id, code: "auth", message: "not authenticated")
                return
            }
            guard let server, let store = server.store else { return }
            // Built before this client counts as subscribed: what's flushed to the others first isn't its business.
            let snap = server.currentSnapshot(store: store)
            isSubscribed = true
            if let d = try? JSONEncoder().encode(snap) { send(data: d) }
        case "command": handleCommand(env)
        case "app":     handleApp(env)
        case "ping":
            let pong = WireMessage.pong(requestID: env.id)
            if let d = try? JSONEncoder().encode(pong) { send(data: d) }
        default:
            sendError(requestID: env.id, code: "badRequest", message: "unknown type: \(env.type)")
        }
    }

    private func handleAuth(_ env: WireClientEnvelope) {
        guard tokenStore.matches(env.token) else {
            sendErrorThenClose(requestID: env.id, code: "auth", message: "bad token")
            return
        }
        authenticated = true
        guard let server, let store = server.store else {
            sendError(requestID: env.id, code: "badRequest", message: "no store")
            return
        }
        let hello = server.helloMessage(requestID: env.id, store: store)
        if let d = try? JSONEncoder().encode(hello) { send(data: d) }
    }

    private func handleCommand(_ env: WireClientEnvelope) {
        if !authenticated {
            guard tokenStore.matches(env.token) else {
                sendError(requestID: env.id, code: "auth", message: "bad token")
                return
            }
        }
        guard let command = env.command else {
            sendError(requestID: env.id, code: "badRequest", message: "invalid command")
            return
        }
        let req = WireCommandRequest(id: env.id, token: env.token, target: env.target,
                                     link: env.link, command: command, wait: env.wait)
        server?.dispatchCommand(req, replyTo: id)
    }

    private func handleApp(_ env: WireClientEnvelope) {
        let authed = authenticated || tokenStore.matches(env.token)
        guard authed else {
            sendError(requestID: env.id, code: "auth", message: "not authenticated")
            return
        }
        guard let action = env.action else {
            sendError(requestID: env.id, code: "badRequest", message: "invalid app request")
            return
        }
        let req = WireAppRequest(id: env.id, action: action, pageID: env.pageID,
                                 enabled: env.enabled, group: env.group, token: env.token)
        server?.dispatchAppAction(req, replyToWS: id)
    }

    private func sendError(requestID: String?, code: String, message: String) {
        let msg = WireMessage.error(requestID: requestID, code: code, message: message)
        if let d = try? JSONEncoder().encode(msg) { send(data: d) }
    }

    /// Sends an error frame and then closes the connection after the data is delivered.
    private func sendErrorThenClose(requestID: String?, code: String, message: String) {
        let msg = WireMessage.error(requestID: requestID, code: code, message: message)
        guard let d = try? JSONEncoder().encode(msg) else { connection.cancel(); return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: d, contentContext: ctx, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    func send(data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .idempotent)
    }
}
