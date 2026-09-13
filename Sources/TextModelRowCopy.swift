import Foundation

/// The sentences the meeting model's surfaces show — the row in Settings ›
/// Meetings, the line under the reading switch, the three verdicts on This
/// Mac, the removal dialog — as pure functions of state, so every wording
/// exists once and is tested once.
///
/// Whole sentences, never fragments joined at runtime: eleven languages do not
/// share a grammar (MeetingCapability's rule).
enum TextModelRowCopy {

    /// The row's states as the copy needs them — a mirror of
    /// `LocalTextModelDownload.State` without the SwiftUI class behind it.
    enum RowState: Equatable {
        case absent, downloading, verifying, ready, installedNotRunnable, failed
    }

    /// Why the helper is waiting, when it is.
    enum Pause: String, Sendable {
        /// The Mac has no memory to spare right now.
        case memory
        /// A meeting is being recorded.
        case call
    }

    // MARK: - The row under "Meeting titles & summaries"

    static func rowHint(state: RowState, memoryGB: Int, appleIntelligence: AppleIntelligenceState,
                        readMeetings: Bool, sizeText: String, paused: Pause?) -> String {
        switch state {
        case .absent:
            return Lf("One-time %@ download, then everything runs on this Mac.", sizeText)
        case .failed:
            return L("Download failed. Check your connection and retry.")
        case .downloading, .verifying:
            return L("Names, a one-line summary and a table of contents, written on this Mac.")
        case .ready:
            if let paused, readMeetings { return pauseText(paused) }
            return readMeetings ? Lf("Installed · %@", sizeText)
                                : Lf("Installed, not in use · %@", sizeText)
        case .installedNotRunnable:
            guard readMeetings else {
                return Lf("Installed but not running: this Mac has %d GB of memory and it needs 16.", memoryGB)
            }
            return appleIntelligence.isOn
                ? Lf("Installed but not running: this Mac has %d GB of memory and it needs 16. Titles and summaries come from Apple Intelligence instead.", memoryGB)
                : Lf("Installed but not running: this Mac has %d GB of memory and it needs 16. Nothing on this Mac reads meetings.", memoryGB)
        }
    }

    static func pauseText(_ pause: Pause) -> String {
        switch pause {
        case .memory: return L("Paused: not enough free memory right now. It resumes on its own.")
        case .call: return L("Waiting for the call to end.")
        }
    }

    // MARK: - The line under "Let the model read your meetings"

    /// What reads meetings on this Mac right now, or why nothing does.
    /// `canDownload` is whether the row below offers the model — the sentence
    /// points at the download only where there is one to point at.
    static func engineLine(status: MeetingTextEngines.Status, canDownload: Bool) -> String {
        switch status {
        case .downloadedModel:
            return L("Reads with the downloaded model.")
        case .appleIntelligence:
            return L("Reads with Apple Intelligence.")
        case .none(let apple):
            switch (canDownload, apple) {
            case (true, .notEnabled):
                return L("Nothing on this Mac can read yet: download the meeting model below, or turn on Apple Intelligence in System Settings.")
            case (true, _):
                return L("Nothing on this Mac can read yet: download the meeting model below, or add a key for the agent.")
            case (false, .notEnabled):
                return L("Nothing on this Mac can read yet: turn on Apple Intelligence in System Settings, or add a key for the agent.")
            case (false, .notReady):
                return L("Nothing on this Mac can read yet: macOS is still setting up Apple Intelligence. The agent with your own key still works.")
            case (false, _):
                return L("Nothing on this Mac can read yet: Apple Intelligence isn't available here. The agent with your own key still works.")
            }
        }
    }

    // MARK: - This Mac

    static func recognitionLine(appleSilicon: Bool) -> String {
        appleSilicon ? L("Recognition runs on the Neural Engine.")
                     : L("Recognition runs on this Mac's processor — slower than on Apple Silicon.")
    }

    /// The reading verdict: the first line names the engine (or the lack of
    /// one); the rest, when there is any, say why and what still works.
    static func readingLines(status: MeetingTextEngines.Status, verdict: HardwareVerdict,
                             sizeText: String) -> [String] {
        switch status {
        case .downloadedModel:
            var lines = [Lf("Meeting reading: the downloaded model (%@).", sizeText)]
            if case .availableWithCost(let cost) = verdict { lines.append(cost) }
            return lines
        case .appleIntelligence:
            return [L("Meeting reading: Apple Intelligence.")]
        case .none:
            var lines = [L("Meeting reading: nothing on this Mac can do it yet.")]
            if case .unavailable(let reason, let instead) = verdict {
                lines.append(reason)
                lines.append(instead)
            } else {
                lines.append(L("Download the meeting model in Meetings, or add a key for the agent."))
            }
            return lines
        }
    }

    static func agentLine(productName: String?) -> String {
        guard let productName else { return L("Agent: off.") }
        return Lf("Agent: %@, on your key.", productName)
    }

    // MARK: - Removing the model

    static func removalBody(appleIntelligence: AppleIntelligenceState, readMeetings: Bool,
                            sizeText: String) -> String {
        guard readMeetings else {
            return Lf("Frees %@. Nothing else changes — reading your meetings is off.", sizeText)
        }
        return appleIntelligence.isOn
            ? Lf("Frees %@. Titles and summaries will come from Apple Intelligence.", sizeText)
            : Lf("Frees %@. New meetings will keep their date names until you download it again. Summaries already written stay.", sizeText)
    }
}
