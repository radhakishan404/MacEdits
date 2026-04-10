import XCTest
@testable import MacEdits

final class CaptionFallbackPolicyTests: XCTestCase {
    func testFallbackEnabledForSpeechPermissionErrors() {
        XCTAssertTrue(CaptionFallbackPolicy.shouldFallbackToTimingCaptions(for: CaptionEngineError.speechAuthorizationDenied))
        XCTAssertTrue(CaptionFallbackPolicy.shouldFallbackToTimingCaptions(for: CaptionEngineError.recognizerUnavailable))
    }

    func testFallbackEnabledForSiriDictationFailureMessage() {
        let error = CaptionEngineError.transcriptionFailed("Siri and Dictation are disabled")
        XCTAssertTrue(CaptionFallbackPolicy.shouldFallbackToTimingCaptions(for: error))
    }

    func testFallbackDisabledForNonSpeechFailures() {
        XCTAssertFalse(CaptionFallbackPolicy.shouldFallbackToTimingCaptions(for: CaptionEngineError.noAudioTrack))
        XCTAssertFalse(CaptionFallbackPolicy.shouldFallbackToTimingCaptions(for: CaptionEngineError.noSpeechDetected))
    }
}
