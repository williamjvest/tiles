import CameraCore
import SwiftUI
#if os(iOS)
import DeclaredAgeRange
#endif

/// Where a US state's App Store law requires it (Texas since 2026-06-04; Utah, Louisiana, Alabama and California in
/// 2027), Tiles asks the App Store for the person's age range, when Apple's Declared Age Range API says it must. Nothing
/// in Tiles depends on age, so the answer decides nothing and is kept nowhere: the system remembers it, Tiles doesn't.
/// It asks once the Terms of Use are agreed, so the system's sheet never lands on top of theirs. A Mac is never asked:
/// Apple's API doesn't require it there.
struct AgeAssurance: ViewModifier {
    let store: DashboardStore

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.2, *) {
            content.modifier(AgeRangeRequest(termsAgreed: !store.holdsRealCameras))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
@available(iOS 26.2, *)
private struct AgeRangeRequest: ViewModifier {
    let termsAgreed: Bool
    @State private var asked = false

    func body(content: Content) -> some View {
        content.task(id: termsAgreed) {
            guard termsAgreed, !asked, let controller = Self.frontController() else { return }
            asked = true
            await askForAgeRange(in: controller)
        }
    }

    /// The view controller the system's sheet goes over: the front window's, or what it's showing.
    static func frontController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var front = (scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first)?.rootViewController
        while let shown = front?.presentedViewController { front = shown }
        return front
    }
}

/// Asks where the law where the person is wants their age range: the region needs it at all and, from iOS 26.4,
/// sharing it is required there. Off the main actor, as the service isn't Sendable; the controller is.
@available(iOS 26.2, *)
private nonisolated func askForAgeRange(in controller: UIViewController) async {
    guard (try? await AgeRangeService.shared.isEligibleForAgeFeatures) == true else { return }
    if #available(iOS 26.4, *), let required = try? await AgeRangeService.shared.requiredRegulatoryFeatures,
       !required.contains(.declaredAgeRangeRequired) {
        return
    }
    _ = try? await AgeRangeService.shared.requestAgeRange(ageGates: 18, in: controller)
}
#endif
