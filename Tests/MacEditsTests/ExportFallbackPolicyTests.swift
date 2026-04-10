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

    func testFileExtensionMappingHandlesRawContainerHints() {
        let quicktimeType = AVFileType("com.apple.quicktime-movie")
        let mpeg4Type = AVFileType("public.mpeg-4")

        XCTAssertEqual(ExportFallbackPolicy.fileExtension(for: quicktimeType), "mov")
        XCTAssertEqual(ExportFallbackPolicy.fileExtension(for: mpeg4Type), "mp4")
    }

    func testRetryPolicyDoesNotRetryOnUserCancellationSignal() {
        XCTAssertFalse(ExportFallbackPolicy.shouldRetryWithAlternateContainer(for: "cancelled by user"))
    }
}
