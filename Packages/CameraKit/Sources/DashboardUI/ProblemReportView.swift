import SwiftUI
import CameraCore
#if os(iOS)
@preconcurrency import MessageUI
#elseif os(macOS)
import AppKit
#endif

/// Settings → Report a Problem (and Help → Report a Problem… on a Mac): what happened, in the sender's words, and what
/// goes with it, sent from their own mail so they see all of it before it goes.
struct ProblemReportView: View {
    let store: DashboardStore
    var controlAPIOn = false
    @State private var whatHappened = ""
    @State private var copied = false
    @State private var composing = false
    @State private var noMail = false
    @Environment(\.openURL) private var openURL

    private var report: ProblemReport {
        ProblemReport(store: store, whatHappened: whatHappened, app: "Tiles \(AboutView.version)",
                      device: DeviceDescription.current, controlAPIOn: controlAPIOn)
    }

    var body: some View {
        let report = self.report
        Form {
            Section {
                TextField("What happened", text: $whatHappened,
                          prompt: Text("What you were doing, what you expected, and what Tiles did instead"),
                          axis: .vertical)
                    .lineLimit(4 ... 12)
                    .labelsHidden()
                    .accessibilityIdentifier("report.whatHappened")
            } header: {
                Text("What Happened")
            }

            Section {
                LabeledContent("Tiles", value: AboutView.version)
                LabeledContent("Device", value: report.device)
                ForEach(report.cameras) { camera in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(camera.label): \(camera.name)")
                            .foregroundStyle(Theme.sheet.text)
                        Text(camera.state)
                            .font(.caption)
                            .foregroundStyle(Theme.sheet.secondaryText)
                    }
                }
                NavigationLink {
                    LogDocument(text: report.log)
                } label: {
                    LabeledContent("Activity Log",
                                   value: report.logLineCount == 1 ? "1 line" : "\(report.logLineCount) lines")
                }
            } header: {
                Text("Sent With It")
            } footer: {
                FooterText("No passwords or user names. The Activity Log is what Tiles has done with its cameras since it opened.")
            }

            Section {
                Button("Email Report") { email(report) }
                    .accessibilityIdentifier("report.email")
                Button(copied ? "Copied" : "Copy Report") {
                    copyToPasteboard(report.text)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
            } footer: {
                FooterText("The email opens in your mail app, addressed to \(Support.email), for you to send.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Report a Problem")
        #if os(iOS)
        .sheet(isPresented: $composing) {
            MailComposer(report: report) { composing = false }
                .ignoresSafeArea()
        }
        #endif
        .alert("No Mail App", isPresented: $noMail) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The report is copied. Paste it into an email to \(Support.email).")
        }
    }

    /// In Mail with the log attached where the system can; else a `mailto:` link to whatever mail app the device has,
    /// with as much of the log as a link carries; else the report is copied, to paste.
    private func email(_ report: ProblemReport) {
        #if os(iOS)
        if MFMailComposeViewController.canSendMail() {
            composing = true
            return
        }
        #elseif os(macOS)
        if Self.composeInMail(report) { return }
        #endif
        guard let link = report.mailto() else { return copyInstead(report) }
        openURL(link) { opened in
            if !opened { copyInstead(report) }
        }
    }

    private func copyInstead(_ report: ProblemReport) {
        copyToPasteboard(report.text)
        noMail = true
    }

    #if os(macOS)
    /// A new message in the Mac's mail app with the report as its body and the log attached. False when it can't.
    private static func composeInMail(_ report: ProblemReport) -> Bool {
        guard let mail = NSSharingService(named: .composeEmail) else { return false }
        mail.recipients = [Support.email]
        mail.subject = report.subject
        var items: [Any] = [report.summary]
        if !report.log.isEmpty {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Tiles Activity Log.txt")
            guard (try? Data(report.log.utf8).write(to: file)) != nil else { return false }
            items.append(file)
        }
        guard mail.canPerform(withItems: items) else { return false }
        mail.perform(withItems: items)
        return true
    }
    #endif
}

/// The Activity Log as it will be sent, in a fixed-width face so its columns hold.
private struct LogDocument: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Nothing yet: Tiles hasn't connected to a camera since it opened." : text)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.sheet.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .navigationTitle("Activity Log")
    }
}

/// The device's model identifier and its system: "iPad16,1, iPadOS 26.1", "Mac15,3, macOS 26.1".
enum DeviceDescription {
    @MainActor static var current: String {
        #if os(macOS)
        let system = "macOS"
        let model = sysctl("hw.model")
        #else
        let system = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        // A simulator reports the Mac's processor; it says which device it's standing in for.
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? sysctl("hw.machine")
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        return "\(model), \(system) \(version)"
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown device" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown device" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

#if os(iOS)
/// Mail's compose sheet, addressed and filled in, with the log attached.
struct MailComposer: UIViewControllerRepresentable {
    let report: ProblemReport
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = context.coordinator
        mail.setToRecipients([Support.email])
        mail.setSubject(report.subject)
        mail.setMessageBody(report.summary, isHTML: false)
        if !report.log.isEmpty {
            mail.addAttachmentData(Data(report.log.utf8), mimeType: "text/plain", fileName: "Tiles Activity Log.txt")
        }
        return mail
    }

    func updateUIViewController(_ mail: MFMailComposeViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
    }
}

extension MailComposer.Coordinator: @preconcurrency MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult,
                               error: Error?) {
        done()
    }
}
#endif
