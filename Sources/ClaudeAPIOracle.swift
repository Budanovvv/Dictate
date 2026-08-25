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

    /// Medium rather than the default high. The work is reading five passages
    /// and answering from them, not solving anything — and past ten seconds a
    /// person stops waiting, which makes latency part of the answer's quality
    /// here. Worth re-tuning against real questions once there are some.
    private let effort = "medium"

    var isAvailable: Bool { AnthropicKey.current != nil }

    var unavailableReason: String {
        L("Add your Anthropic API key in Settings to ask questions")
    }

    func answer(_ question: String, from sources: [MeetingSource])
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await stream(question, sources, into: continuation)
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

    private func stream(_ question: String, _ sources: [MeetingSource],
                        into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let key = AnthropicKey.current else { throw Failure.noKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": MeetingQuestion.instructions,
            "output_config": ["effort": effort],
            "messages": [["role": "user",
                          "content": MeetingQuestion.user(question: question, sources: sources)]],
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.failed("no response") }
        guard http.statusCode == 200 else {
            // The body carries the reason, and the reasons a person can act on
            // are the common ones: a key that is wrong, an account with no
            // credit, a rate limit. Read it rather than showing a number.
            var body = ""
            for try await line in bytes.lines { body += line }
            throw Failure.http(http.statusCode, body)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Only the text. Thinking blocks arrive on this stream too and are
            // empty by default on this model — and even summarised they are the
            // model's working, not its answer.
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                continuation.yield(text)
            }
            if event["type"] as? String == "error",
               let error = event["error"] as? [String: Any] {
                throw Failure.failed(error["message"] as? String ?? "the model stopped")
            }
        }
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
