import SwiftUI
// @preconcurrency: TranslationSession is not Sendable and its async methods
// are called from the actor that owns the session anyway — the SDK's strict
// annotations only add noise here.
@preconcurrency import Translation

/// Why an Apple translation didn't happen. The dictation always falls back to
/// the native text; `dataMissing` is the only case the user can act on, so it
/// is the only one that reaches the HUD.
enum TranslateError: Error, Equatable {
    /// The language pair's data isn't on this Mac. Downloading it is strictly
    /// the Settings window's job — see AppleTranslator.isInstalled.
    case dataMissing
    /// Another dictation's translation is still in flight.
    case busy
    /// The host's translationTask never answered.
    case timedOut
}

/// Bridges Apple's on-device Translation framework into the dictation
/// pipeline. The framework is SwiftUI-only: a TranslationSession can exist
/// solely inside a `.translationTask` view modifier, so a persistent invisible
/// host window (created in AppDelegate) carries the task, and `translate()`
/// hands text over and awaits the session's answer.
///
/// Used for EVERY translate target, English included: Whisper transcribes the
/// speech natively, then this hops it into the target language — all on
/// device, matching the privacy story.
/// Main-actor confined: pending/lastJobID/configuration were always touched
/// on the main queue only (every mutation sat in a DispatchQueue.main hop or
/// the SwiftUI host) — the annotation makes that the rule.
@MainActor
final class AppleTranslator: ObservableObject {
    /// nonisolated: read from SwiftUI property initializers (nonisolated
    /// contexts); safe — the class is Sendable via its MainActor isolation.
    nonisolated static let shared = AppleTranslator()

    /// Touches no main-actor state — lets `shared` above be built nonisolated.
    nonisolated init() {}

    /// Changing (or invalidating) this re-fires the host's translationTask.
    @Published var configuration: TranslationSession.Configuration?
    private var pending: (id: Int, text: String, target: Locale.Language,
                          continuation: CheckedContinuation<String, Error>)?
    private var lastJobID = 0

    /// The English-hub legs whose data a translation into `target` needs.
    /// Apple's model assets are per-language around English: for ru→uk the
    /// packs are ru↔en and en↔uk, and the status of the DIRECT ru→uk pair is
    /// not trustworthy — seen live reporting .installed with nothing on disk
    /// (the session then dies with "Unable to Translate"). Every check and
    /// every download therefore goes leg by leg.
    nonisolated static func legs(target: String, source: String?) -> [(from: String, to: String)] {
        // Auto-detect dictations can reach here without a source language;
        // the system language is the best guess available at that point.
        let src = source ?? Locale.current.language.languageCode?.identifier ?? "en"
        if target == src { return [] }
        if target == "en" { return [(src, "en")] }
        if src == "en" { return [("en", target)] }
        return [(src, "en"), ("en", target)]
    }

    nonisolated static func isInstalled(from: String, to: String) async -> Bool {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: from),
            to: Locale.Language(identifier: to)) == .installed
    }

    /// All data needed for `target` is on the Mac (leg-by-leg — see legs()).
    ///
    /// The runtime path must never ask macOS to fetch it. The runtime session
    /// lives in an invisible 1×1 panel of a menu-bar (.accessory) app: the
    /// system's download-consent sheet has no usable window to open in, so
    /// macOS falls back to demanding attention — the Dock icon bounces on and
    /// on, and `session.translate` waits for a decision that can never be made.
    /// Settings downloads the data instead (TranslatePrepareView).
    nonisolated static func isInstalled(target: String, source: String?) async -> Bool {
        for leg in legs(target: target, source: source) {
            if await !isInstalled(from: leg.from, to: leg.to) { return false }
        }
        return true
    }

    /// Non-empty code → Locale.Language; "" and nil both mean "unknown".
    nonisolated static func language(_ code: String?) -> Locale.Language? {
        guard let code, !code.isEmpty else { return nil }
        return Locale.Language(identifier: code)
    }

    /// Translation over the English hub. Direct sessions between two
    /// non-English languages are unreliable — ru→uk failed "Unable to
    /// Translate" even while availability claimed the pair was installed
    /// (seen live) — so any such target ALWAYS goes source→en→target;
    /// only English endpoints translate in one hop.
    nonisolated func translateSmart(_ text: String, to target: String, source: String?) async throws -> String {
        if target == "en" || source == "en" {
            return try await translate(text, to: target, source: source)
        }
        Log.d("apple translate: \(source ?? "auto")→\(target) via en pivot")
        let english = try await translate(text, to: "en", source: source)
        return try await translate(english, to: target, source: "en")
    }

    /// Translates text into `target` (BCP-47-ish code, e.g. "es").
    /// `source` — the spoken language when known; nil lets macOS detect it.
    /// One call at a time — dictations are serialized upstream anyway.
    nonisolated func translate(_ text: String, to target: String, source: String?) async throws -> String {
        if await !Self.isInstalled(target: target, source: source) {
            // A pack that was accepted in Settings can still be finishing its
            // install when the very next dictation arrives (seen live with uk:
            // "no translation… oh, now it translates"). One short re-check
            // absorbs that window instead of failing the dictation.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard await Self.isInstalled(target: target, source: source) else {
                Log.d("apple translate: \(source ?? "auto")→\(target) data not installed — not translating")
                throw TranslateError.dataMissing
            }
        }
        let targetLanguage = Locale.Language(identifier: target)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                // Queued on the main queue — the body runs on the main actor.
                MainActor.assumeIsolated {
                    guard self.pending == nil else {
                        continuation.resume(throwing: TranslateError.busy)
                        return
                    }
                    self.lastJobID &+= 1
                    let id = self.lastJobID
                    self.pending = (id, text, targetLanguage, continuation)
                    let config = TranslationSession.Configuration(
                        source: Self.language(source), target: targetLanguage)
                    if self.configuration == config {
                        // Same language pair — the modifier only re-fires on a
                        // changed value, so bump this one's version in place.
                        self.configuration?.invalidate()
                    } else {
                        self.configuration = config
                    }
                    // Watchdog: if the host task never fires (host window not
                    // realized, framework refuses the pair), fail the dictation
                    // back to native text instead of hanging the pipeline. The id
                    // check keeps a stale watchdog from stealing a LATER
                    // dictation's job — it used to resume whatever continuation
                    // happened to be pending 15 s later.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                        // Queued on the main queue — main actor by construction.
                        MainActor.assumeIsolated {
                            guard let job = self.pending, job.id == id else { return }
                            self.pending = nil
                            Log.d("apple translate: timed out waiting for the session")
                            job.continuation.resume(throwing: TranslateError.timedOut)
                        }
                    }
                }
            }
        }
    }

    /// Called by the host's translationTask whenever the configuration fires.
    @MainActor
    func run(_ session: TranslationSession) async {
        guard let job = pending else { return }
        // A session left over from an abandoned job (one the watchdog already
        // failed) must not translate this text into the wrong language — the
        // session for the current pair fires right behind it.
        if let sessionTarget = session.targetLanguage,
           sessionTarget.languageCode != job.target.languageCode {
            Log.d("apple translate: ignoring stale session for \(sessionTarget.languageCode?.identifier ?? "?")")
            return
        }
        pending = nil
        do {
            let response = try await session.translate(job.text)
            job.continuation.resume(returning: response.targetText)
        } catch {
            Log.d("apple translate: session failed: \(error.localizedDescription)")
            job.continuation.resume(throwing: error)
        }
    }
}

/// Invisible view hosting the translation session for runtime translations.
/// Lives in a 1×1 transparent panel created at startup (AppDelegate).
struct TranslatorHostView: View {
    @ObservedObject private var bridge = AppleTranslator.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in
                await bridge.run(session)
            }
    }
}

/// Invisible companion for the windows that can host system UI (Settings and
/// onboarding): fetches a language pair's translation data while such a window
/// is on screen — the window macOS attaches its consent/download UI to —
/// instead of surprising the user on the first dictation (where nothing can
/// host that UI at all). Every pair needs it, →English included.
///
/// It hangs off the SettingsView root's `.background`, NOT off a Form row.
/// A Form rebuilds its rows on every redraw — including the redraw caused by
/// the very picker change that arms this view — and the rebuild tore the
/// session down: the macOS download dialog appeared and vanished in the same
/// frame. In the root's background its position in the hierarchy is fixed, so
/// the view keeps its identity, its @State and its session across redraws.
/// What the Settings row shows for the current pair's translation data.
enum TranslateDataState {
    case ready
    case missing
    /// The system sheet is up or the download is running — indeterminate
    /// spinner (macOS gives no byte progress for language packs).
    case fetching
}

struct TranslatePrepareView: View {
    let targetCode: String
    let sourceCode: String?
    /// Bumped by onboarding on entering the keys step, to fetch proactively
    /// (the first pass after appearing is otherwise status-only — see arm()).
    let reload: Int
    /// Reports the pair's data state (drives the Settings row).
    let onState: (TranslateDataState) -> Void

    @State private var config: TranslationSession.Configuration?
    /// The first pass only reports status — see arm().
    @State private var checked = false

    var body: some View {
        // NOT zero-sized: the framework attaches its consent/download sheet to
        // the hosting view's window, and a 0×0 view proved flaky — the sheet
        // appeared and dismissed itself. A real (if imperceptible) 1×1 view
        // behaves like a normal citizen of the window.
        Color.black.opacity(0.02)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .translationTask(config) { session in
                await MainActor.run { onState(.fetching) }
                // This session covers ONE English-hub leg (see arm()); poll
                // that leg's own status, not the composite.
                let from = session.sourceLanguage ?? Locale.current.language
                let to = session.targetLanguage
                do {
                    Log.d("translate prepare: presenting download for leg \(from.minimalIdentifier)→\(to?.minimalIdentifier ?? "?")")
                    try await session.prepareTranslation()
                } catch {
                    Log.d("translate prepare failed (\(type(of: error))): \(error.localizedDescription)")
                }
                // prepareTranslation PRESENTS the consent sheet and returns in
                // ~0.5 s without waiting for the user's answer — and the sheet
                // lives only as long as this session (= this closure) does.
                // Returning here is what made the dialog flash and vanish. So
                // stay: poll until the leg is installed (user accepted and the
                // download completed), the deadline passes (user dismissed), or
                // the task is cancelled (target changed / window closed).
                func legInstalled() async -> Bool {
                    guard let to else { return false }
                    return await LanguageAvailability().status(from: from, to: to) == .installed
                }
                var installed = await legInstalled()
                let deadline = Date().addingTimeInterval(300)
                while !installed, !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    installed = await legInstalled()
                }
                Log.d("translate prepare: leg \(from.minimalIdentifier)→\(to?.minimalIdentifier ?? "?") closing, installed=\(installed)")
                if installed {
                    // On to the next missing leg (or to the ready report).
                    await arm(continueChain: true)
                } else {
                    // User dismissed the sheet / timeout: stop the chain, don't
                    // re-offer the dialog until they act again.
                    await MainActor.run { onState(.missing); config = nil }
                }
            }
            .task(id: "\(targetCode)|\(sourceCode ?? "")|\(reload)") { await arm() }
    }

    /// `continueChain` — a leg just finished downloading; keep going to the
    /// next missing leg without treating it as a fresh user request.
    @MainActor
    private func arm(continueChain: Bool = false) async {
        // Merely opening Settings must not throw a download dialog at the user:
        // the first pass only reads the status. Every later pass is deliberate
        // — a new pick in the picker, or onboarding reaching the keys step.
        let userAsked = checked || continueChain
        checked = true
        // Nothing to fetch when the target IS the spoken language (an English
        // speaker translating to English): macOS has no such pair, and asking
        // would throw a pointless download dialog at onboarding.
        guard !targetCode.isEmpty, targetCode != sourceCode else {
            config = nil
            onState(.ready)
            return
        }
        // Walk the English-hub legs (the only trustworthy unit of download and
        // status — direct non-English pairs report .installed while having
        // nothing on disk, seen live with ru→uk).
        let availability = LanguageAvailability()
        for leg in AppleTranslator.legs(target: targetCode, source: sourceCode) {
            let status = await availability.status(
                from: Locale.Language(identifier: leg.from),
                to: Locale.Language(identifier: leg.to))
            switch status {
            case .installed:
                continue
            case .unsupported:
                // Asking macOS to fetch an impossible pair (be→en was seen
                // live) flashes a doomed dialog — don't even start.
                Log.d("translate prepare: leg \(leg.from)→\(leg.to) unsupported by macOS")
                onState(.missing)
                config = nil
                return
            default:
                // First missing leg: fetch it. When it lands, the session
                // closure calls arm(continueChain: true) for the next one.
                onState(.missing)
                guard userAsked else { config = nil; return }
                Log.d("translate prepare: requesting data for leg \(leg.from)→\(leg.to)")
                let next = TranslationSession.Configuration(
                    source: Locale.Language(identifier: leg.from),
                    target: Locale.Language(identifier: leg.to))
                if config == next { config?.invalidate() } else { config = next }
                return
            }
        }
        config = nil
        onState(.ready)
    }
}
