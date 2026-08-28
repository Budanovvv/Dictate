import Foundation

/// Answers by calling the OpenAI API with the user's own key.
///
/// The same arrangement as ClaudeAPIOracle and for the same reason: a key the
/// person issued, meters and can revoke is the one form of cloud access a
/// third-party app can offer honestly. Which of the two answers is the
/// person's pick in Settings — some already pay OpenAI, some Anthropic, and
/// the app has no business deciding whose meter runs.
struct OpenAIAPIOracle: MeetingOracle {

    /// GPT-5.6 Sol — the deepest tier of the current generation, for the same
    /// reason the other oracle runs Opus: the question is "what did we decide,
    /// and what do I still owe" asked of transcripts a person has forgotten —
    /// the cost of a wrong answer is that they act on it, and the difference
    /// in price between tiers is cents against that. (Sol/Terra/Luna are
    /// OpenAI's durable capability tiers; the bare "gpt-5.6" alias routes to
    /// Sol anyway, but pinning the explicit id keeps the choice visible.)
    private let model = "gpt-5.6-sol"

    /// Room for the answer AND for the reasoning, which counts against the
    /// same ceiling. A few paragraphs of prose is a few hundred tokens; the
    /// rest is headroom so an answer never stops mid-sentence.
    private let maxTokens = 4096

    /// Medium — the model's own default, stated so the choice is visible. The
    /// work is reading five passages and answering from them, not solving
    /// anything, and past ten seconds a person stops waiting.
    private let effort = "medium"

    var isAvailable: Bool { APIKey.current(.openai) != nil }

    var unavailableReason: String {
        L("Add your OpenAI API key in Settings to ask questions")
    }

    func answer(_ prompt: String, history: [AnswerExchange])
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await stream(prompt, history, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancellation has to reach the request, not just the loop reading
            // it: a stopped answer that keeps being generated is still being
            // paid for, and the person pressing Stop is usually pressing it
            // because they no longer want to pay.
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// How many model→tools→model rounds one question may cost. The last
    /// round goes out without tools, so the loop always ends in an answer
    /// rather than in an appetite.
    private let maxRounds = 6

    /// The Responses API, not Chat Completions — not a preference, a
    /// constraint: gpt-5.6-sol refuses function tools together with
    /// reasoning on /v1/chat/completions and names /v1/responses as the way
    /// (hit live, 2026-08-27). It is also the better fit: `store: false`
    /// keeps the conversation off OpenAI's servers, which is the only
    /// arrangement that matches what the rest of this app promises.
    private func stream(_ prompt: String, _ history: [AnswerExchange],
                        into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let key = APIKey.current(.openai) else { throw Failure.noKey }

        // The whole conversation, every call: the API is stateless (store is
        // off), and the session the asking pane promises lives in this array.
        var input: [[String: Any]] = []
        for turn in history {
            input.append(["role": "user", "content": turn.user])
            input.append(["role": "assistant", "content": turn.assistant])
        }
        input.append(["role": "user", "content": prompt])

        let tools: [[String: Any]] = MeetingAgentTool.allCases.map {
            ["type": "function", "name": $0.rawValue,
             "description": $0.summary, "parameters": $0.schema]
        }

        // The agent loop: the model answers, or asks for a tool and goes
        // again with the result. Everything streamed along the way is already
        // on the reader's screen — a tool round only ever adds to it.
        for round in 0..<maxRounds {
            try Task.checkCancellation()
            var body: [String: Any] = [
                "model": model,
                "instructions": MeetingQuestion.instructions,
                "input": input,
                "max_output_tokens": maxTokens,
                "stream": true,
                "store": false,
                "reasoning": ["effort": effort],
                // Stateless tool use needs the reasoning carried back by us,
                // and encrypted is the only form it travels in.
                "include": ["reasoning.encrypted_content"],
            ]
            if round < maxRounds - 1 { body["tools"] = tools }

            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 120
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            // A stream can also die AFTER the 200 — the flapping access error
            // was seen arriving as `response.created` followed by an error
            // event (2026-08-27). A stream that failed before its first
            // visible word can be retried invisibly; one that already spoke
            // cannot, or the reader would watch the answer start over.
            var output: [[String: Any]] = []
            var attempt = 0
            while true {
                try Task.checkCancellation()
                let bytes = try await Self.send(request)
                var yielded = false
                do {
                    output = try await Self.read(bytes) { piece in
                        yielded = true
                        continuation.yield(piece)
                    }
                    break
                } catch {
                    attempt += 1
                    guard !yielded, attempt < 3, !(error is CancellationError) else { throw error }
                    Log.d("ask: stream failed before output, retrying")
                    try await Task.sleep(for: .seconds(2))
                }
            }

            let callItems = output.filter { $0["type"] as? String == "function_call" }
            guard !callItems.isEmpty else { return }

            // The response's own items go back verbatim — reasoning included,
            // that is what `include` above was for — then each call's output.
            input.append(contentsOf: output)
            for item in callItems {
                let name = item["name"] as? String ?? ""
                let raw = item["arguments"] as? String ?? "{}"
                let arguments = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)))
                    as? [String: Any] ?? [:]
                Log.d("ask: tool \(name)")
                let result = await MeetingAgentTool.run(name: name, arguments: arguments)
                input.append(["type": "function_call_output",
                              "call_id": item["call_id"] as? String ?? "",
                              "output": result])
            }
        }
    }

    /// Reads one response stream: text is handed out as it arrives, and the
    /// finished item list — which the Responses API delivers whole in
    /// `response.completed` — comes back as the return value, which saves
    /// reassembling tool calls from argument fragments.
    private static func read(_ bytes: URLSession.AsyncBytes,
                             onText: (String) -> Void) async throws -> [[String: Any]] {
        var output: [[String: Any]] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            guard let data = String(line.dropFirst(6)).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            switch event["type"] as? String {
            case "response.output_text.delta":
                if let piece = event["delta"] as? String {
                    onText(piece)
                }
            case "response.completed":
                if let response = event["response"] as? [String: Any],
                   let items = response["output"] as? [[String: Any]] {
                    output = items
                }
            case "response.failed", "response.incomplete", "error":
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] ?? event["error"]) as? [String: Any]
                let message = error?["message"] as? String
                    ?? event["message"] as? String ?? "the model stopped"
                throw Failure.failed(message)
            default:
                break
            }
        }
        return output
    }

    /// Sends one request, quietly retrying the refusals that are the server's
    /// weather rather than the user's mistake: rate limits, 5xx — and 404,
    /// which is normally permanent but was observed flapping for minutes
    /// while a project's model allowlist propagated across OpenAI's fleet
    /// (2026-08-27: the same request alternated between "no access to model"
    /// and an answer). A wrong key or empty account still fails on the first
    /// try — those are the person's to fix, and waiting would only insult.
    static func send(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.failed("no response") }
            if http.statusCode == 200 { return bytes }
            // The body carries the reason, and the reasons a person can act
            // on are the common ones: a key that is wrong, an account with no
            // credit, a rate limit. Read it, not the number.
            var body = ""
            for try await line in bytes.lines { body += line }
            let transient = http.statusCode == 429 || http.statusCode == 404
                || http.statusCode >= 500
            guard transient, attempt < 2 else { throw Failure.http(http.statusCode, body) }
            // Honor Retry-After when the server names its own wait (capped);
            // flat pause otherwise. Kept symmetric with the Anthropic oracle.
            let wait = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init).map { min(max($0, 1), 30) } ?? 2
            Log.d("ask: http \(http.statusCode), retrying in \(Int(wait))s")
            try await Task.sleep(for: .seconds(wait))
        }
        throw Failure.failed("no response")
    }

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noKey:
                return L("Add your OpenAI API key in Settings to ask questions")
            case .http(let code, let body):
                // OpenAI returns {"error": {"message": …}}; fall back to the
                // status when it does not.
                if let data = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return message
                }
                return Lf("The model refused the request (%@)", "\(code)")
            case .failed(let why):
                return why
            }
        }
    }
}
