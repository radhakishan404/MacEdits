import AVFoundation
import XCTest
@testable import MacEdits

final class ExportFallbackPolicyTests: XCTestCase {
    func testPreferredTargetsPrioritizeMP4ThenMOV() {
        let targets = ExportFallbackPolicy.preferredOutputTargets(from: [.mov, .mp4])
        XCTAssertEqual(targets.map(\.fileType), [.mp4, .mov])
        XCTAssertEqual(targets.map(\.fileExtension), ["mp4", "mov"])
    }

    func testPreferredTargetsFallbackToFirstSupportedType() {
        let fallbackType: AVFileType = .aiff
        let targets = ExportFallbackPolicy.preferredOutputTargets(from: [fallbackType])
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].fileType, fallbackType)
        XCTAssertEqual(targets[0].fileExtension, "mov")
    }

    func testRetryPolicyMatchesKnownExportFailureSignals() {
        XCTAssertTrue(ExportFallbackPolicy.shouldRetryWithAlternateContainer(for: "Operation Stopped"))
        XCTAssertTrue(ExportFallbackPolicy.shouldRetryWithAlternateContainer(for: "unsupported file type"))
        XCTAssertTrue(ExportFallbackPolicy.shouldRetryWithAlternateContainer(for: "AVFoundationErrorDomain code=-11800"))
        XCTAssertFalse(ExportFallbackPolicy.shouldRetryWithAlternateContainer(for: "disk full"))
    }
}
