import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A title and the line under it, exactly as a model produced them — before
/// any of the cleaning in MeetingTitler. Every filter in this app runs on the
/// far side of this type, so an engine cannot skip one by being new.
struct GeneratedBrief: Sendable {
    let title: String
    let summary: String
}

/// Why an engine had nothing to say. Callers treat all of these the same way —
/// a meeting keeps its date name, a passage gets no line — but they read
/// differently in the log, and the log is how the next refusal gets diagnosed.
enum GenerationFailure: Error {
    /// No engine at all: no local model on disk and no Apple Intelligence.
    case unavailable
    /// The model declined the content ("Detected content likely to be unsafe").
    case refused(String)
    /// Anything else: a context overflow, a dead child process, a parse error.
    case failed(String)
}

/// The one thing this app ever asks a language model to do: read a piece of a
/// transcript and write a short line about it.
///
/// It exists because the model underneath changed and will change again. Apple's
/// on-device model needs macOS 26 — so on macOS 15 the whole feature was simply
/// absent — and it refuses medical content, which is most of one owner's
/// archive: 12 of 14 missing section lines came back "Detected content likely
/// to be unsafe", 112 refusals in one log, and non-deterministically so (the
/// same file gave 4, 3 and 6 refusals on three runs). A local model measured
/// against the same 36 passages with this app's own prompt refused none of
/// them.
///
/// What is deliberately NOT behind this boundary: every filter. The engine
/// returns raw model output and nothing else. Lists, quotations of the
/// passage, over-length lines, summaries that only restate the title, speaker
/// prefixes and reporting openings are all rejected downstream, by the code in
/// MeetingTitler and MeetingSectioner that was tuned on real output — and they
/// apply to whatever engine produced the text, because a different model
/// invents its own ways of being useless but not fewer of them.
protocol MeetingTextEngine: Sendable {
    /// Named in the log, so a line in a transcript can always be traced to the
    /// thing that wrote it.
    var engineName: String { get }

    /// How much of a whole MEETING this engine reads when writing the title
    /// and the one-line summary.
    ///
    /// This is the number that makes the local engine worth its 2.5 GB beyond
    /// the refusals. Apple's model has a 4096-token window for everything, so
    /// a meeting reaches it as 1200 characters sampled evenly across the hour —
    /// and what lands in that sieve is often transcription noise. Two real
    /// summaries built that way: "son Geruslan" and "death recording system".
    /// An engine with room for the whole transcript reads the whole
    /// transcript, and on all four meetings it was measured against it won.
    var briefLimit: Int { get }

    /// How much of one SECTION it reads. The same for both engines on purpose:
    /// 2500 characters is what the section measurements were taken at, and a
    /// section is one subject either way — this is the number that must NOT
    /// drift, or the sections stop being comparable with the ones already
    /// written into people's files.
    var sectionLimit: Int { get }

    /// Whether the engine reads the language the meeting was held in.
    ///
    /// Apple's model handles nine languages and answers confidently with
    /// nonsense on the rest (a Russian work call came back titled "Valentine's
    /// Day Plans", from the name "Валентин"), so everything else goes through
    /// Apple Translation first. The local model reads Russian directly and
    /// answers in English — measured 11 out of 11 — and the translation hop is
    /// not merely unnecessary for it but harmful: translating first LOSES
    /// content, visibly, on the same passages.
    var readsEveryLanguage: Bool { get }

    /// The title and the summary, in one call.
    func brief(about text: String, instructions: String) async throws -> GeneratedBrief

    /// One line about one passage. `temperature` is the caller's, because the
    /// section retry deliberately asks a second time colder.
    func line(about text: String, instructions: String,
              temperature: Double) async throws -> String
}

/// Picks the engine a generation will run on.
///
/// The order is a preference, not a fallback chain by capability: the local
/// model is chosen when it is present because it was measured better on this
/// archive than Apple's — 36 of 36 passages against 25 of 36, no refusals
/// against 11, and better lines even where Apple produced one (asked about a
/// passage where a laptop overheated, Apple wrote "Ruslan and Yura are working
/// out on the sun"). Apple's stays as the fallback because it costs no
/// download and no memory, and on a Mac with Apple Intelligence and no local
/// model it is the difference between a named meeting and a dated one.
///
/// Nothing installed and no Apple Intelligence means no engine, and that is a
/// supported state: meetings keep their date-and-time names, exactly as they
/// did before any of this existed.
enum MeetingTextEngines {

    /// The engine to use right now, or nil when there is none.
    ///
    /// Asked per generation rather than cached: the local model can finish
    /// downloading, or be removed in Settings, between two meetings in the
    /// same backfill.
    static func best() async -> (any MeetingTextEngine)? {
        if let local = await LocalTextEngine.availableEngine() { return local }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), let apple = AppleTextEngine.availableEngine() {
            return apple
        }
        #endif
        Log.d("engine: none available — no local model and no Apple Intelligence")
        return nil
    }
}

// MARK: - Apple's on-device model

#if canImport(FoundationModels)
/// The engine this app shipped with: Apple Intelligence's system model.
/// Behaviour here is deliberately unchanged from before there was a boundary —
/// same instructions, same guided generation, same 80-token response cap, same
/// fresh session per call.
@available(macOS 26, *)
struct AppleTextEngine: MeetingTextEngine {
    let engineName = "apple"
    /// Meetings state their subject early, and a short excerpt keeps the call
    /// fast and well inside a 4096-token window shared with the answer. Both
    /// numbers stay where they were written down and reasoned about, so the
    /// engine cannot quietly disagree with the comments explaining them.
    let briefLimit = MeetingTitler.excerptLimit
    let sectionLimit = MeetingSectioner.excerptLimit
    let readsEveryLanguage = false

    /// nil unless the model is actually usable right now — the hardware
    /// supports it and the user has it switched on.
    static func availableEngine() -> AppleTextEngine? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return AppleTextEngine()
        case .unavailable(let reason):
            Log.d("engine: system model unavailable (\(reason))")
            return nil
        }
    }

    func brief(about text: String, instructions: String) async throws -> GeneratedBrief {
        let session = LanguageModelSession(instructions: instructions)
        do {
            // ONE call for both fields. Guided generation rather than two
            // free-text lines to parse: the model fills named fields, so a
            // chatty answer cannot put the summary in the title.
            //
            // The response cap is load-bearing, not tuning. Without it the
            // framework reserves the rest of the 4096-token window for an
            // answer it will never need, and an ordinary meeting comes back as
            // "Content contains 4091 tokens, which exceeds the maximum allowed
            // context size of 4096" — two of eighteen transcripts failed
            // exactly that way until this was put back.
            let answer = try await session.respond(
                to: text, generating: ModelBrief.self,
                options: GenerationOptions(temperature: 0.3,
                                           maximumResponseTokens: 80)).content
            return GeneratedBrief(title: answer.title, summary: answer.summary)
        } catch {
            throw GenerationFailure.failed(error.localizedDescription)
        }
    }

    func line(about text: String, instructions: String,
              temperature: Double) async throws -> String {
        // A FRESH session every time, deliberately. A LanguageModelSession
        // keeps its transcript, so reusing one across a dozen sections would
        // grow the context by a passage each time and walk straight into the
        // window this is here to avoid.
        let session = LanguageModelSession(instructions: instructions)
        do {
            // 80 rather than the 40 a 130-character line needs, and that gap is
            // a real bug this had: guided generation spends tokens on the JSON
            // around the value, so a cap sized to the SENTENCE truncates the
            // structure and every call comes back "Failed to deserialize a
            // Generable type from model output" (four passages in a row).
            return try await session.respond(
                to: text, generating: ModelSection.self,
                options: GenerationOptions(temperature: temperature,
                                           maximumResponseTokens: 80)).content.line
        } catch {
            throw GenerationFailure.failed(error.localizedDescription)
        }
    }
}
#endif

#if canImport(FoundationModels)
/// The shape a section line arrives in — one named field, so a chatty answer
/// cannot smuggle a second sentence past the cleaner.
@available(macOS 26, *)
@Generable
struct ModelSection {
    @Guide(description: """
        A table-of-contents label for this passage: the problem raised, what \
        was decided, or what somebody has to do next, in the concrete nouns \
        the conversation used. Never a quotation from the transcript and never \
        prefixed with a speaker's name. Two subjects are named briefly and \
        separated by a semicolon, never blurred into one vague phrase. ONE \
        clause with a verb, never a list of nouns, with no full stop at the \
        end and under 100 characters.
        """)
    var line: String
}

/// The shape the model must answer in. Guided generation means the two fields
/// arrive separately instead of as a paragraph we would have to cut in half.
@available(macOS 26, *)
@Generable
struct ModelBrief {
    @Guide(description: "A title of at most 6 words naming what the meeting is about.")
    var title: String
    @Guide(description: """
        The line that adds what the title does not say: what was wrong, what \
        was decided, or what happens next. Never restates the title. Uses the \
        concrete nouns the conversation used — names, artifacts, numbers — \
        never abstractions like "system functionality" or "objectives". ONE \
        fragment, not a sentence, with no full stop at the end. At most 90 \
        characters, and the meaning is in the first 60.
        """)
    var summary: String
}
#endif
