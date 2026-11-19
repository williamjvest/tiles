import SwiftUI
import UniformTypeIdentifiers
import CameraCore

// MARK: - UTType for .cube

extension UTType {
    /// `.cube` LUT files. Apple doesn't define a type, so this is the dynamic type for the extension: it needs no
    /// Info.plist declaration (an `exportedAs:` type does, and without one matches nothing).
    static let cube = UTType(filenameExtension: "cube", conformingTo: .data) ?? .data
}

// MARK: - LUT import flow

/// Full-screen sheet: file picker → slot chooser → progress → result.
/// Reachable from CameraEditor (Settings → camera → "Load LUT onto Camera…")
/// and optionally from the LUT tile's picker as a trailing option.
///
/// DashboardUI never imports SonyPTP: it holds only the `LUTImportCapable` protocol from CameraCore.
struct LUTImportView: View {
    let camera: CameraController
    @Environment(\.dismiss) private var dismiss

    // File import
    @State private var showFilePicker = false
    @State private var pickedURL: URL?
    @State private var pickedData: Data?

    // Slot chooser
    @State private var slots: [LUTSlot] = []
    @State private var selectedSlot: Int = 1
    @State private var displayName: String = ""
    @State private var slotsLoaded = false
    /// Why the slots couldn't be read. Import stays off until they are: without them a used slot would look empty
    /// and be overwritten without asking.
    @State private var slotsError: String?

    // Overwrite confirmation
    @State private var showOverwriteAlert = false

    // Import state
    enum ImportState: Equatable {
        case idle
        case uploading
        case success
        case failure(String)
    }
    @State private var importState: ImportState = .idle
    /// The slot the last import went to (the picker moves on to the next empty slot afterwards).
    @State private var loadedInto = ""

    private var importer: (any LUTImportCapable)? { camera.lutImporter }

    // Why import is unavailable, if it is.
    private var disabledReason: String? {
        guard camera.state.connection.isControllable else {
            return "Camera not connected"
        }
        return unsupported
    }
    @State private var unsupported: String?

    var body: some View {
        NavigationStack {
            Form {
                // ── File section ──────────────────────────────────────────────
                Section {
                    if let url = pickedURL {
                        LabeledContent("File") {
                            Text(url.lastPathComponent)
                                .font(.body.monospaced())
                                .foregroundStyle(Theme.sheet.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        LabeledContent("Display Name") {
                            TextField("Name shown on camera", text: $displayName)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(Theme.sheet.text)
                                .autocorrectionDisabled()
                        }
                        if camera.state.offersFalseColorLUTSwap {
                            Text("A name with \"False Color\" or \"FC\" in it gets the LUT tile's False Color switch.")
                                .font(.caption)
                                .foregroundStyle(Theme.sheet.secondaryText)
                        }
                        // Another LUT without closing the sheet: preparing several slots on set took reopening it.
                        Button("Choose Another File…") { showFilePicker = true }
                            .disabled(importState == .uploading)
                    } else {
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Choose .cube File…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(disabledReason != nil)
                    }
                    if let reason = disabledReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Theme.sheet.secondaryText)
                    }
                } header: {
                    Text("LUT File")
                }

                // ── Slot chooser ──────────────────────────────────────────────
                if pickedURL != nil {
                    Section {
                        if slotsLoaded {
                            Picker("Slot", selection: $selectedSlot) {
                                ForEach(slots) { slot in
                                    HStack {
                                        Text(slot.label)
                                            .font(.body.monospaced())
                                        if let name = slot.name {
                                            Text("· \(name)")
                                                .foregroundStyle(Theme.sheet.secondaryText)
                                                .lineLimit(1)
                                        } else {
                                            Text("· empty")
                                                .foregroundStyle(Theme.sheet.secondaryText)
                                        }
                                    }
                                    .tag(slot.index)
                                }
                            }
                            .pickerStyle(.menu)
                            if let current = slots.first(where: { $0.index == selectedSlot }), let name = current.name {
                                Text("Overwrites \"\(name)\"")
                                    .font(.caption)
                                    .foregroundStyle(Theme.recording)
                            }
                        } else if let slotsError {
                            Label(slotsError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.recording)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try Again") { Task { await loadSlots() } }
                        } else {
                            ProgressView("Loading slots…")
                                .foregroundStyle(Theme.sheet.secondaryText)
                        }
                    } header: {
                        Text("Destination Slot")
                    }
                }

                // ── Progress / result ─────────────────────────────────────────
                switch importState {
                case .uploading:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Uploading to camera…")
                                .foregroundStyle(Theme.sheet.secondaryText)
                        }
                    }
                case .success:
                    Section {
                        Label("Loaded into \(loadedInto).", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.sheet.timecode)
                    }
                case .failure(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.recording)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .idle:
                    EmptyView()
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Load LUT onto Camera")
            .toolbar {
                if importState == .success {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            startImport()
                        }
                        .disabled(!canImport)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.cube, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFilePicked(result)
            }
            .alert(overwriteSlotName.map { "Overwrite \"\($0)\"?" } ?? "Overwrite slot?",
                   isPresented: $showOverwriteAlert) {
                Button("Overwrite", role: .destructive) { performImport() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let name = overwriteSlotName {
                    Text("\"\(displayName)\" will replace \"\(name)\" in \(slotLabel). This cannot be undone from the app.")
                } else {
                    Text("\"\(displayName)\" will be loaded into \(slotLabel).")
                }
            }
            .task {
                await loadSlots()
            }
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 440, idealHeight: 520)
        #endif
    }

    // MARK: - Computed helpers

    private var canImport: Bool {
        pickedData != nil
            && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
            && slotsLoaded && !slots.isEmpty
            && importState != .uploading
            && importState != .success
            && disabledReason == nil
    }

    private var slotLabel: String {
        slots.first(where: { $0.index == selectedSlot })?.label ?? "User\(selectedSlot)"
    }

    private var overwriteSlotName: String? {
        slots.first(where: { $0.index == selectedSlot })?.name
    }

    // MARK: - Actions

    private func handleFilePicked(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Validate extension.
            guard url.pathExtension.lowercased() == "cube" else {
                importState = .failure("Only .cube files are supported.")
                return
            }
            // Picked files are security-scoped; a file the app can already read returns false here and is still fine.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pickedData = data
                pickedURL = url
                displayName = sanitizeName(url.deletingPathExtension().lastPathComponent)
                importState = .idle
            } catch {
                importState = .failure("Couldn't read file: \(error.localizedDescription)")
            }
        case .failure(let error):
            importState = .failure(error.localizedDescription)
        }
    }

    private func startImport() {
        if overwriteSlotName != nil {
            showOverwriteAlert = true
        } else {
            performImport()
        }
    }

    private func performImport() {
        guard let data = pickedData, let imp = importer else { return }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        let slot = selectedSlot
        let label = slotLabel
        importState = .uploading
        Task {
            do {
                try await imp.importLUT(data: data, name: name, slot: slot)
                loadedInto = label
                importState = .success
                // Refresh slot list so the new name shows on a second import this session.
                await loadSlots()
            } catch let err as LUTImportError {
                importState = .failure(err.errorDescription ?? "Unknown error.")
            } catch {
                importState = .failure(error.localizedDescription)
            }
        }
    }

    private func loadSlots() async {
        guard let imp = importer else { return }
        slotsError = nil
        do {
            let fetched = try await imp.lutSlots()
            slots = fetched
            slotsLoaded = true
            // Default to the first empty slot if possible.
            if let first = fetched.first(where: { $0.name == nil }) {
                selectedSlot = first.index
            }
        } catch LUTImportError.notSupported {
            unsupported = "This camera can't load LUTs over the network."
        } catch {
            // Never offer slots we couldn't read: a used one would look empty and be overwritten without asking.
            slotsLoaded = false
            slotsError = (error as? LUTImportError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Name sanitisation

    /// Strips leading/trailing whitespace and path-separator characters; trims to a reasonable length.
    /// Note: a name containing "False" or an FC token makes the FALSE COLOR switch appear on the LUT tile.
    private func sanitizeName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        return String(
            raw.unicodeScalars
                .filter { !forbidden.contains($0) }
                .prefix(60)
                .map(Character.init)
        ).trimmingCharacters(in: .whitespaces)
    }
}
