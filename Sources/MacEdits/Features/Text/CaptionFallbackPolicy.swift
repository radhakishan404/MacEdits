import Foundation

enum CaptionFallbackPolicy {
    static func shouldFallbackToTimingCaptions(for error: Error) -> Bool {
        if let captionError = error as? CaptionEngineError {
            switch captionError {
            case .speechAuthorizationDenied, .recognizerUnavailable:
                return true
            case let .transcriptionFailed(message):
                return shouldFallbackToTimingCaptions(forMessage: message)
            default:
                return false
            }
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return shouldFallbackToTimingCaptions(forMessage: message)
    }

    static func shouldFallbackToTimingCaptions(forMessage message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("siri")
            || lower.contains("dictation")
            || lower.contains("speech recognition")
            || lower.contains("speech recognizer")
            || lower.contains("not available")
            || lower.contains("disabled")
    }
}
