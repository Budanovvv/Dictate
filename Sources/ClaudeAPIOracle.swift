import Foundation

/// Answers by calling the Claude API with the user's own key.
///
/// This is the shipped path, and the only one either vendor sanctions for a
/// third-party application. Anthropic's own wording: "Developers building
/// products or services that interact with Claude's capabilities … should use
/// API key authentication through Claude Console." The subscription-backed
/// alternative is forbidden to us in writing and blocked in practice, so this
/// is not a compromise between two options — it is the option.
struct ClaudeAPIOracle: MeetingOracle {

    /// Claude Opus 5. The question is "what did we decide, and what do I still
    /// owe" asked of transcripts a person has forgotten — the cost of a wrong
    /// answer is that they act on it, and the difference in price between
    /// models is cents against that.
    private let model = "claude-opus-5"

    /// Room for the answer AND for the thinking, which on this model is on
    /// unless told otherwise and counts against the same ceiling. A few
    /// paragraphs of prose is a few hundred tokens; the rest of this is
    /// headroom so an answer never stops mid-sentence.
    private let maxTokens = 4096

    /// Medium rather than the default high. The work is an agentic
    /// list/search/read loop over the archive with a grounded answer at the
    /// end, not puzzle-solving — and past ten seconds a person stops
    /// waiting, which makes latency part of the answer's quality here.
    /// Worth re-tuning against real questions once there are some.
    private let effort = "medium"

    var isAvailable: Bool { APIKey.current(.anthropic) != nil }

    var unavailableReason: String {
        L("Add your Anthropic API key in Settings to ask questions")
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

    /// One content block of the assistant turn, accumulated from the stream —
    /// enough to replay the turn verbatim in the next request.
    private struct Block {
        var type = ""
        var id = ""
        var name = ""
        var json = ""
        var text = ""

        var input: [String: Any] {
            let raw = json.isEmpty ? "{}" : json
            return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        }
    }

    private func stream(_ prompt: String, _ history: [AnswerExchange],
                        into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let key = APIKey.current(.anthropic) else { throw Failure.noKey }

        // The whole conversation, every call: the API is stateless, and the
        // session the asking pane promises lives in this array.
        var messages: [[String: Any]] = []
        for turn in history {
            messages.append(["role": "user", "content": turn.user])
            messages.append(["role": "assistant", "content": turn.assistant])
        }
        messages.append(["role": "user", "content": prompt])

        let tools: [[String: Any]] = MeetingAgentTool.allCases.map {
            ["name": $0.rawValue, "description": $0.summary, "input_schema": $0.schema]
        }

        // The agent loop: the model answers, or asks for a tool and goes
        // again with the result. Everything streamed along the way is already
        // on the reader's screen — a tool round only ever adds to it.
        for round in 0..<maxRounds {
            try Task.checkCancellation()
            var body: [String: Any] = [
                "model": model,
                "max_tokens": maxTokens,
                "stream": true,
                "system": MeetingQuestion.instructions,
                "output_config": ["effort": effort],
                "messages": messages,
            ]
            if round < maxRounds - 1 { body["tools"] = tools }

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = 120
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let bytes = try await Self.send(request)

            var blocks: [Int: Block] = [:]
            var stopReason: String?
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data: ") else { continue }
                guard let data = String(line.dropFirst(6)).data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                switch event["type"] as? String {
                case "content_block_start":
                    guard let index = event["index"] as? Int,
                          let start = event["content_block"] as? [String: Any] else { break }
                    var block = Block()
                    block.type = start["type"] as? String ?? ""
                    block.id = start["id"] as? String ?? ""
                    block.name = start["name"] as? String ?? ""
                    blocks[index] = block
                case "content_block_delta":
                    guard let index = event["index"] as? Int,
                          let delta = event["delta"] as? [String: Any] else { break }
                    // Only the text reaches the reader. Thinking blocks arrive
                    // on this stream too and are the model's working, not its
                    // answer; tool arguments are plumbing.
                    if delta["type"] as? String == "text_delta",
                       let text = delta["text"] as? String {
                        blocks[index]?.text += text
                        continuation.yield(text)
                    }
                    if let piece = delta["partial_json"] as? String {
                        blocks[index]?.json += piece
                    }
                case "message_delta":
                    if let delta = event["delta"] as? [String: Any],
                       let reason = delta["stop_reason"] as? String {
                        stopReason = reason
                    }
                case "error":
                    let error = event["error"] as? [String: Any]
                    throw Failure.failed(error?["message"] as? String ?? "the model stopped")
                default:
                    break
                }
            }

            let ordered = blocks.sorted { $0.key < $1.key }.map(\.value)
            let toolUses = ordered.filter { $0.type == "tool_use" }
            guard stopReason == "tool_use", !toolUses.isEmpty else { return }

            // Replay the assistant turn verbatim, then answer each call.
            messages.append(["role": "assistant", "content": ordered.compactMap { block -> [String: Any]? in
                switch block.type {
                case "text" where !block.text.isEmpty:
                    return ["type": "text", "text": block.text]
                case "tool_use":
                    return ["type": "tool_use", "id": block.id,
                            "name": block.name, "input": block.input]
                default:
                    return nil
                }
            }])
            var results: [[String: Any]] = []
            for use in toolUses {
                Log.d("ask: tool \(use.name)")
                let output = await MeetingAgentTool.run(name: use.name, arguments: use.input)
                results.append(["type": "tool_result",
                                "tool_use_id": use.id, "content": output])
            }
            messages.append(["role": "user", "content": results])
        }
    }

    /// Sends one request, quietly retrying the refusals that are the server's
    /// weather rather than the user's mistake: rate limits, overloads, 5xx —
    /// and 404, which is normally permanent but was observed flapping for
    /// minutes while a project's model access propagated across a vendor's
    /// fleet (2026-08-27, the OpenAI oracle; kept symmetric here). A wrong
    /// key or empty account still fails on the first try.
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
            // A rate limit names its own wait: honor Retry-After when the
            // server sends one (capped — an answer pane is not a batch job),
            // fall back to the flat pause otherwise.
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
                return L("Add your Anthropic API key in Settings to ask questions")
            case .http(let code, let body):
                // Anthropic returns {"error": {"message": …}}; fall back to the
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
