import Foundation

/// The four ways an already-connected Ask fails, told apart so the answer
/// area can say the right thing with the right action (design: askFailures).
/// All four sit in the answer area, in place of the answer, never as an
/// alert — Ask stays on; only this question failed.
enum AskFailureKind {
    case offline, rateLimited, outOfCredit, badKey, other

    static func classify(_ error: Error) -> AskFailureKind {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
                 .internationalRoamingOff:
                return .offline
            default:
                return .other
            }
        }
        let (status, body) = httpDetails(of: error)
        if let status {
            switch status {
            case 401, 403: return .badKey
            case 402: return .outOfCredit
            case 429:
                // Anthropic answers 429 for rate limits AND for exhausted
                // credit; the wording is the only thing that tells them apart.
                return isBilling(body) ? .outOfCredit : .rateLimited
            default: break
            }
        }
        let text = (body.isEmpty ? error.localizedDescription : body)
        if isBilling(text) { return .outOfCredit }
        if text.lowercased().contains("rate limit") { return .rateLimited }
        return .other
    }

    private static func isBilling(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("credit") || lower.contains("billing")
            || lower.contains("quota") || lower.contains("insufficient")
    }

    private static func httpDetails(of error: Error) -> (Int?, String) {
        if case let ClaudeAPIOracle.Failure.http(code, body) = error { return (code, body) }
        if case let OpenAIAPIOracle.Failure.http(code, body) = error { return (code, body) }
        return (nil, "")
    }
}
