import SwiftUI

/// The offer to connect an agent — shown only where the person's own action
/// created the opening (they typed a question the agent could answer), never
/// as a banner. Same manners as LocalTextModelOffer, the shipped pattern it
/// copies: it appears on two runs of the app, a third would be nagging, and
/// one click dismisses it forever. Settings remains the single durable home
/// of the switch; these are pointers to it, not a second switch.
@MainActor
final class AgentOffer: ObservableObject {
    static let shared = AgentOffer()

    @Published private(set) var dismissed = Settings.shared.agentOfferDismissed
    private var countedThisRun = false

    var allowed: Bool {
        !dismissed && Settings.shared.agentOfferRuns <= 2
    }

    func noteShown() {
        guard !countedThisRun else { return }
        countedThisRun = true
        Settings.shared.agentOfferRuns += 1
    }

    func dismiss() {
        dismissed = true
        Settings.shared.agentOfferDismissed = true
    }
}

/// One real call against the vendor, because "API Key Configured" meaning
/// "a string exists" is the pattern the research filed under worst practice.
/// The mapping is deliberately coarse: 2xx is a key that works, 401/403 is a
/// key that does not, and everything else is weather — a person offline must
/// not be stranded at a Connect button (the first question retries anyway).
enum APIKeyVerifier {
    enum Verdict { case ok, refused, unreachable }

    static func verify(_ key: String, for provider: AIProvider) async -> Verdict {
        var request: URLRequest
        switch provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200..<300: return .ok
        case 401, 403: return .refused
        default: return .unreachable
        }
    }
}

/// Connecting the agent, right where the question is.
///
/// The sheet opens over the meetings window carrying the question the person
/// was already asking — reward first, credential second — and when the key
/// verifies, the answer to that question is the first thing that happens.
/// The celebration is an archive that suddenly answers, not a checkmark.
///
/// The decline path ("Not now") is visible beside Connect, never below a
/// fold — the pattern Apple's own AI consent sheet was criticised for
/// getting wrong.
struct AgentConnectSheet: View {
    @ObservedObject private var loc = Localization.shared

    /// The question that opened the sheet. It stays visible in the pane the
    /// sheet drops over (design 9t-x) — the sheet itself doesn't repeat it.
    let question: String?
    let onConnected: () -> Void
    let onCancel: () -> Void

    @State private var provider: AIProvider = .anthropic
    @State private var keyDraft = ""
    @State private var checking = false
    @State private var refused = false
    /// The key verified as "network weather" (offline, 5xx): saved to the
    /// Keychain but unproven. The sheet says so instead of pretending success —
    /// the first real question is the actual check.
    @State private var savedOffline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Connect an assistant to answer questions"))
                    .font(.system(size: 15, weight: .semibold))
                // The de-escalation up front: what already works without this.
                Text(L("Transcripts, search and quotes work without this. An assistant is only needed to write the answer."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(L("Assistant"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $provider) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.productName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(L("API key"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField("", text: $keyDraft, prompt: Text(provider.keyPlaceholder))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onChange(of: keyDraft) { refused = false; savedOffline = false }
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if savedOffline {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DS.good)
                    }
                }
                if checking {
                    helpLine(Lf("Checking the key with %@. No transcript is sent — only a test request.",
                                provider.vendorName))
                } else if refused {
                    noticeBox(icon: "exclamationmark.circle", tint: Color(nsColor: .systemRed),
                              text: L("The key was refused. It may be revoked, from a different provider, or out of credit — the key itself was not saved."))
                } else if savedOffline {
                    noticeBox(icon: "wifi.slash", tint: nil,
                              text: L("Saved to your Keychain, but not verified — this Mac is offline. It will be checked the first time you ask something."))
                } else {
                    HStack(spacing: 4) {
                        helpLine(L("Paste a key from your own account."))
                        Link(Lf("Get one at %@.", provider.keysURL.host ?? ""),
                             destination: provider.keysURL)
                            .font(DS.helpText)
                    }
                }
            }

            // The two promises that decide the click: where the key lives,
            // and what leaves this Mac (design 9t-x).
            VStack(alignment: .leading, spacing: 6) {
                footnote(icon: "lock",
                         text: L("Stored in the macOS Keychain on this Mac. Never written to a settings file, never synced."))
                footnote(icon: "questionmark.circle",
                         text: L("You pay your provider per question — typically a fraction of a cent. Only your question and the quoted passages are sent; recordings never leave this Mac."))
            }
            .padding(.top, 2)

            // The decline path beside Connect, same weight class, never below
            // a fold — the pattern Apple's own AI consent sheet was criticised
            // for getting wrong.
            HStack(spacing: 9) {
                Button(L("Not now")) { onCancel() }
                    .buttonStyle(.dsWide)
                if savedOffline {
                    Button(L("Done")) { onConnected() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.dsWidePrimary)
                } else {
                    Button(refused ? L("Try Again") : L("Connect")) { connect() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.dsWidePrimary)
                        .disabled(checking || !APIKey.looksValid(keyDraft, for: provider))
                }
            }
            .padding(.top, 4)

            Text(L("Not now keeps the agent off and hidden. Search and transcripts are unaffected."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(width: 436)
        .tint(DS.accent)
    }

    private func helpLine(_ text: String) -> some View {
        Text(text)
            .font(DS.helpText)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A quiet inset box for the two exceptional key states.
    private func noticeBox(icon: String, tint: Color?, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(DS.helpText)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .padding(.top, 1)
            Text(text)
                .font(DS.helpText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(tint.map { AnyShapeStyle($0.opacity(0.08)) }
                  ?? AnyShapeStyle(.quaternary.opacity(0.5))))
    }

    private func footnote(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(DS.helpText)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(text)
                .font(DS.helpText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() {
        let key = keyDraft
        let chosen = provider
        checking = true
        refused = false
        Task { @MainActor in
            let verdict = await APIKeyVerifier.verify(key, for: chosen)
            checking = false
            switch verdict {
            case .refused:
                refused = true
            case .ok:
                guard APIKey.store(key, for: chosen) else {
                    Log.d("connect: keychain refused the key")
                    refused = true
                    return
                }
                Settings.shared.askProvider = chosen
                onConnected()
            case .unreachable:
                // An offline Mac is not a wrong key. Save it, but SAY it is
                // unverified — the first question is the real check.
                Log.d("connect: could not verify, saving anyway")
                guard APIKey.store(key, for: chosen) else {
                    Log.d("connect: keychain refused the key")
                    refused = true
                    return
                }
                Settings.shared.askProvider = chosen
                savedOffline = true
            }
        }
    }
}
