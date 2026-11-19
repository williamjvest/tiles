import SwiftUI
import CameraCore

// MARK: - HaLowNodeState color

extension HaLowNodeState {
    /// Consistent status color used in the tile and in Settings rows.
    var statusColor: Color {
        switch self {
        case .polling: Theme.timecode
        case .loginFailed, .accessDenied: Theme.recording
        default: Theme.secondaryText
        }
    }
}

// MARK: - Signal scale

/// Bars and color for a HaLow signal, shared by the tile and the top-bar link meter. HaLow decodes far weaker
/// signals than Wi-Fi (MM6108 sensitivity is around −100 dBm at the lowest rates), so the steps sit lower than a
/// Wi-Fi meter's; control traffic is tiny and still gets through in the yellow band.
enum HaLowSignal {
    static func quality(_ dBm: Int?) -> (bars: Double, color: Color) {
        guard let dBm else { return (0, Theme.recording) }  // no peer: the link is down
        switch dBm {
        case (-75)...: return (1, Theme.timecode)
        case (-85)...: return (0.75, Theme.timecode)
        case (-95)...: return (0.5, Theme.legible(SlotColor.yellow.color))
        default: return (0.25, Theme.recording)
        }
    }

    /// "3.5 Mb/s · 2 MHz · 4% retry": what the node reports beyond the signal.
    /// Priority order (most → least important): phyRate, retry, channelWidth, MCS, battery.
    static func details(_ stats: HaLowNodeStats) -> String? {
        details(stats, maxParts: Int.max)
    }

    /// Abbreviated detail string, dropping least-important parts first when `maxParts` is low.
    /// Importance rank: phyRate > retry > channelWidth > MCS > battery (node-level, not per-link).
    static func details(_ stats: HaLowNodeStats, maxParts: Int) -> String? {
        var parts: [String] = []
        if let kbps = stats.phyRateKbps, kbps > 0 {
            parts.append(kbps >= 1000 ? String(format: "%.1f Mb/s", Double(kbps) / 1000) : "\(kbps) kb/s")
        }
        if let retry = stats.txRetryRatio, retry >= 0.01 { parts.append("\(Int((retry * 100).rounded()))% retry") }
        if let mhz = stats.channelWidthMHz { parts.append("\(mhz) MHz") }
        if let mcs = stats.mcsIndex { parts.append("MCS\(mcs)") }
        if let battery = stats.batteryPercent { parts.append("node \(battery)%") }
        let kept = Array(parts.prefix(maxParts))
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }
}

/// One node as the top bar's link menu lists it.
struct HaLowLink: Hashable {
    var name: String
    var signalDBm: Int?
    var state: HaLowNodeState

    var line: String {
        guard state == .polling else { return "\(name) · \(state.label.lowercased())" }
        return signalDBm.map { "\(name) · \($0) dBm" } ?? "\(name) · no link"
    }

    /// The links worth showing: answering nodes always, the rest only when HaLow is set to always show.
    @MainActor static func links(_ store: DashboardStore) -> [HaLowLink] {
        let mode = store.haLowSettings.displayMode
        guard mode != .off else { return [] }
        return store.haLowNodes.compactMap { node in
            guard node.state == .polling || mode == .on else { return nil }
            return HaLowLink(name: node.name, signalDBm: node.stats?.signalDBm, state: node.state ?? .unreachable)
        }
    }
}

// MARK: - Tile

/// The HaLow link: the strongest peer of the node this device is on (else the first node). Captioned and read-only (style guide §3): the signal is
/// the value, colored like the link meter; rate, width and retries go beside it when the tile is wide enough,
/// under it when it's tall enough, and are dropped otherwise. Never changes anything on a node.
struct HaLowTile: View {
    let stats: HaLowNodeStats?
    let nodeState: HaLowNodeState?
    let tint: Color
    @Environment(\.tileScale) private var s

    var body: some View {
        Tile(tint: tint, isEnabled: nodeState != nil, isReadout: true) {
            TileFrame(caption: "HaLow") { oneLine, size in
                let valueSize = Theme.valueSize(oneLine: oneLine, height: size.height, max: 28, scale: s)
                // Detail candidates in descending verbosity: full, 2 parts, 1 part, none.
                // ViewThatFits picks the widest that fits horizontally (beside the value), then stacks
                // it under the value, then drops to the value alone. This way a narrow tile gracefully
                // loses the least-important detail first rather than clipping or overflowing.
                ViewThatFits(in: .horizontal) {
                    if let d = details(maxParts: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
                            value(valueSize, shrinks: false)
                            detail(d)
                        }
                    }
                    if let d = details(maxParts: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
                            value(valueSize, shrinks: false)
                            detail(d)
                        }
                    }
                    if let d = details(maxParts: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 8 * s) {
                            value(valueSize, shrinks: false)
                            detail(d)
                        }
                    }
                    value(valueSize, shrinks: true)
                }
                .audited(.value)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    private func value(_ size: CGFloat, shrinks: Bool) -> some View {
        Text(verbatim: valueText)
            .font(Theme.value(size))
            .foregroundStyle(valueColor)
            .lineLimit(1)
            .minimumScaleFactor(shrinks ? 0.5 : 1)
    }

    private func detail(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.readout(s))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
    }

    private var valueText: String {
        guard let nodeState else { return "—" }
        guard nodeState == .polling else { return nodeState.label }
        return stats?.signalDBm.map { "\($0) dBm" } ?? "No link"
    }

    private var valueColor: Color {
        nodeState == .polling ? HaLowSignal.quality(stats?.signalDBm).color : (nodeState?.statusColor ?? Theme.secondaryText)
    }

    private var details: String? { details(maxParts: Int.max) }

    private func details(maxParts: Int) -> String? {
        guard nodeState == .polling, stats?.signalDBm != nil else { return nil }
        return stats.flatMap { HaLowSignal.details($0, maxParts: maxParts) }
    }
}

// MARK: - Settings

/// Settings → HaLow Nodes: what to show, the one login every node takes, and the nodes, found or added by hand.
/// Opening it looks for nodes (password-free) so it can list what's there before a password is saved.
struct HaLowSettingsSection: View {
    @Bindable var store: DashboardStore

    @State private var usernameDraft = ""
    @State private var passwordDraft = ""
    @State private var changingPassword = false
    @State private var newAddressDraft = ""
    @State private var addingAddress = false

    var body: some View {
        Group {
            login
            if store.haLowSettings.displayMode != .off { nodes }
        }
        .task { store.findHaLowNodes() }
    }

    private var login: some View {
        Section {
            Picker("Show", selection: $store.haLowSettings.displayMode) {
                Text("When a node answers").tag(HaLowDisplayMode.auto)
                Text("Always").tag(HaLowDisplayMode.on)
                Text("Off").tag(HaLowDisplayMode.off)
            }
            .pickerStyle(.menu)

            if store.haLowSettings.displayMode != .off {
                LabeledContent("Username") {
                    // Applied when done, not per keystroke: a new username drops every node's session.
                    TextField("Username", text: $usernameDraft, prompt: Text("root"))
                        .onSubmit(saveUsername)
                        .onAppear { usernameDraft = store.haLowSettings.username }
                        .onDisappear(perform: saveUsername)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                if changingPassword || !store.hasHaLowPassword {
                    HStack {
                        PasswordField(title: "Password", text: $passwordDraft, prompt: Text("Password"))
                            .font(.body.monospaced())
                        Button("Save") {
                            store.setHaLowPassword(passwordDraft)
                            passwordDraft = ""
                            changingPassword = false
                        }
                        .disabled(passwordDraft.isEmpty)
                    }
                } else {
                    LabeledContent("Password") {
                        Button("Change") { changingPassword = true }
                    }
                }
            }
        } footer: {
            FooterText(store.haLowSettings.displayMode == .off ? "Nothing is looked for or polled."
                : "One login for every node, kept in the Keychain. On OpenMANET it's the admin login (root) set in "
                    + "the node's setup.")
        }
    }

    private var nodes: some View {
        Section {
            ForEach(store.haLowNodes) { node in nodeRow(node) }
            if store.haLowNodes.isEmpty {
                Text("None found on this network.")
                    .foregroundStyle(Theme.sheet.secondaryText)
            }
            if addingAddress {
                HStack {
                    TextField("Node address", text: $newAddressDraft, prompt: Text("IP address"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    Button("Add") {
                        let address = newAddressDraft.trimmingCharacters(in: .whitespaces)
                        if !address.isEmpty, !store.haLowSettings.manualAddresses.contains(address) {
                            store.haLowSettings.manualAddresses.append(address)
                        }
                        newAddressDraft = ""
                        addingAddress = false
                    }
                }
            } else {
                Button {
                    addingAddress = true
                } label: {
                    Label("Add Node Address", systemImage: "plus")
                }
            }
        } header: {
            Text("Nodes")
        } footer: {
            FooterText(nodesFooter)
        }
    }

    @ViewBuilder private func nodeRow(_ node: HaLowNode) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: node.name)
                Text(verbatim: ([node.address, node.isManual ? "added" : "found"] + (node.isLocal ? ["this device's node"] : []))
                        .joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.sheet.secondaryText)
                if let state = node.state {
                    Text(state.label)
                        .font(.caption)
                        .foregroundStyle(state.statusColor)
                }
            }
            Spacer()
            if node.isManual {
                Button {
                    store.haLowSettings.manualAddresses.removeAll { $0 == node.address }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Theme.recording)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(node.address)")
            }
        }
    }

    private func saveUsername() {
        let username = usernameDraft.trimmingCharacters(in: .whitespaces)
        if !username.isEmpty, username != store.haLowSettings.username { store.haLowSettings.username = username }
    }

    private var nodesFooter: String {
        "Nodes are found on this network by themselves: OpenMANET nodes answer a password-free check, and any one "
            + "that's logged into lists the rest of the mesh. Add a node by address if it isn't found. Read-only, and "
            + "only while the app is open: the node this device is on every 10 s, any other every minute across the "
            + "HaLow link." + (store.haLowSettings.displayMode == .on
                ? " Nodes added by hand, or that have answered, show even when they stop." : "")
    }
}
