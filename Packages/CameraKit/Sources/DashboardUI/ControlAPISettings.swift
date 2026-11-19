import SwiftUI
import CameraCore

/// Settings → Control API section.
///
/// Shown as a NavigationLink destination from SettingsSheet (or a standalone sheet on macOS).
/// The ControlServer and its token store live in the app layer and are passed in.
public struct ControlAPISettingsView: View {
    @Bindable var store: DashboardStore
    let server: ControlServer
    let tokenStore: ControlServerTokenStore

    @State private var enabled: Bool = false
    @State private var tokenVisible = false
    @State private var confirmRegenerate = false
    @State private var copiedToken = false

    private var httpAddress: String {
        server.advertiseAddress
            .replacingOccurrences(of: ":\(ControlServer.defaultWSPort)",
                                  with: ":\(ControlServer.defaultHTTPPort)")
    }

    public init(store: DashboardStore, server: ControlServer, tokenStore: ControlServerTokenStore) {
        self.store = store
        self.server = server
        self.tokenStore = tokenStore
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Control API", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        store.setControlAPIEnabled(on, server: server)
                    }
            } footer: {
                FooterText("Allows Stream Deck, Bitfocus Companion, and other tools to control cameras over your local network. On iPhone and iPad the server only runs while the app is in the foreground.")
            }

            // Port-in-use error — shown whether the server started or not.
            if let err = server.portError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            if enabled && server.isRunning {
                Section {
                    LabeledContent("WebSocket") {
                        Text("ws://\(server.advertiseAddress)/")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.sheet.text)
                            .textSelection(.enabled)
                    }
                    LabeledContent("HTTP") {
                        Text("http://\(httpAddress)/")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.sheet.text)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Endpoints")
                } footer: {
                    FooterText("WebSocket port \(ControlServer.defaultWSPort) · HTTP port \(ControlServer.defaultHTTPPort). Ports are fixed and survive app restarts.")
                }

                Section {
                    HStack {
                        if tokenVisible {
                            Text(tokenStore.token())
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.sheet.text)
                        } else {
                            Text(String(repeating: "•", count: 32))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.sheet.secondaryText)
                        }
                        Spacer()
                        Button(tokenVisible ? "Hide" : "Show") {
                            tokenVisible.toggle()
                        }
                    }
                    Button(copiedToken ? "Copied" : "Copy Token") {
                        #if os(iOS)
                        UIPasteboard.general.string = tokenStore.token()
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tokenStore.token(), forType: .string)
                        #endif
                        copiedToken = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedToken = false
                        }
                    }
                } header: {
                    Text("Pairing Token")
                } footer: {
                    FooterText("Any client that connects must send this token.")
                }
                Section {
                    Button("Regenerate Token…", role: .destructive) {
                        confirmRegenerate = true
                    }
                } footer: {
                    FooterText("Disconnects every client: each needs the new token.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Control API")
        .onAppear { enabled = server.isRunning || store.controlAPIEnabled }
        .confirmationDialog("Regenerate Token?",
                            isPresented: $confirmRegenerate,
                            titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) {
                _ = tokenStore.regenerate()
                // Close all open sockets so clients must re-authenticate with the new token
                server.closeAllWebSockets()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All connected clients will need to re-enter the new token.")
        }
        .preferredColorScheme(.dark)
    }
}
