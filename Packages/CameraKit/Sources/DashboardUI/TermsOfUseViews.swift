import CameraCore
import SwiftUI

/// The Terms of Use, agreed to once, before any camera connects (`TermsOfUse`, `DashboardStore.holdsRealCameras`).
/// Sony's license asks for its warranty and prohibited-use terms to be explained and agreed to before anyone uses Tiles,
/// so those come first, in full, above the whole text; one Agree covers it all. It can't be swiped away.
struct TermsSheet: View {
    var onAgree: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Before Tiles connects to a camera, read and agree to its Terms of Use.")
                        .font(.body)
                        .foregroundStyle(Theme.sheet.text)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 16) {
                        KeyPoint(symbol: "exclamationmark.shield", title: "Sony cameras and their warranty",
                                 text: TermsOfUse.sonyWarranty)
                        KeyPoint(symbol: "nosign", title: "No weapons or military use",
                                 text: TermsOfUse.sonyProhibitedUses)
                        KeyPoint(symbol: "checkmark.circle", title: "Check the camera",
                                 text: TermsOfUse.checkTheCamera)
                    }
                    .padding(16)
                    .background(Theme.sheet.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    TermsText()
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(action: onAgree) {
                        Text("Agree").font(.headline).frame(maxWidth: 420)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("terms.agree")
                    Text("Version \(TermsOfUse.version), \(TermsOfUse.dated) · Toldwell LLC")
                        .font(.caption)
                        .foregroundStyle(Theme.sheet.secondaryText)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .navigationTitle("Terms of Use")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 600, idealHeight: 760)
        #endif
    }
}

/// One of the terms the sheet puts first.
private struct KeyPoint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.sheet.text)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(Theme.sheet.text)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Theme.sheet.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The whole text, a paragraph per section, its numbers and titles in bold.
struct TermsText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(TermsOfUse.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text((try? AttributedString(markdown: paragraph)) ?? AttributedString(paragraph))
                    .font(.callout)
                    .foregroundStyle(Theme.sheet.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("terms.text")
    }
}

/// Settings → About Tiles: who makes it, the Terms of Use (and when they were agreed to), Tiles' license, and the
/// third-party notices its libraries' licenses ask to go with the app.
struct AboutView: View {
    let store: DashboardStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Made by", value: "Toldwell LLC")
                Link("Support: \(Support.site.host() ?? "")", destination: Support.site)
                if let mail = URL(string: "mailto:\(Support.email)") {
                    Link(Support.email, destination: mail)
                }
            } footer: {
                FooterText("Tiles isn't made, owned, licensed or supported by Sony, Blackmagic Design or ARRI. Support comes from Toldwell.")
            }
            Section {
                NavigationLink("Terms of Use") {
                    ScrollView { TermsText().padding(20) }
                        .navigationTitle("Terms of Use")
                }
                NavigationLink("License") { Document(title: "License", text: TermsOfUse.license) }
                NavigationLink("Acknowledgments") { Document(title: "Acknowledgments", text: TermsOfUse.acknowledgements) }
            } footer: {
                FooterText(agreed)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About Tiles")
    }

    private var agreed: String {
        var text = "Version \(TermsOfUse.version) of the Terms of Use, \(TermsOfUse.dated)."
        if let acceptance = store.termsAcceptance {
            text += " Agreed to on \(acceptance.acceptedAt.formatted(date: .long, time: .omitted))."
        }
        return text + " Tiles' own code is open source, under the MIT license."
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// A license's text as it's written, in a fixed-width face so its layout holds.
    private struct Document: View {
        let title: String
        let text: String

        var body: some View {
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.sheet.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle(title)
        }
    }
}
