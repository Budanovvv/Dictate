import Foundation

/// When the onboarding may start loading the speech model into the Neural
/// Engine — a rule, kept out of the view so it can be tested.
///
/// The first load of the model is the heaviest thing the app ever does: a
/// one-time Core ML compile that takes minutes and, on a small Mac, most of
/// its memory. It used to start the moment the download finished, on step 1,
/// which put it under the microphone permission dialog on step 3 — and on a
/// MacBook M2 with 8 GB the dialog's Allow button could not be clicked at all
/// (2026-09-13). So it starts after the permissions are granted, or on the
/// try-it step, whichever comes first. The try-it step already says it may
/// be preparing.
enum OnboardingPolicy {
    /// Step numbers as the view counts them: 0 welcome, 1 model, 2 keys,
    /// 3 permissions, 4 try it.
    static let permissionsStep = 3
    static let tryItStep = 4

    static func shouldPreload(step: Int, allGranted: Bool) -> Bool {
        if step >= tryItStep { return true }
        return step == permissionsStep && allGranted
    }
}
