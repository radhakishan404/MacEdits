import Foundation
import XCTest
@testable import MacEdits

final class ProjectStoreIngestTests: XCTestCase {
    func testIngestAssetWithoutTimelineInsertionKeepsTimelineUnchanged() throws {
        let store = ProjectStore()
        var workspace = try store.createProject(named: "Ingest Fixture", origin: .recording)
        defer { try? FileManager.default.removeItem(at: workspace.summary.projectURL) }

        let sourceURL = try makeTemporaryMediaFile(extension: "mov")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let clipCountBefore = workspace.file.timelineClips.count
        workspace = try store.ingestAsset(
            from: sourceURL,
            into: workspace,
            preferredType: .video,
            preferredTrackKind: .video,
            insertIntoTimeline: false
        )

        XCTAssertEqual(workspace.file.timelineClips.count, clipCountBefore)
        XCTAssertEqual(workspace.file.assets.count, 1)
    }

    func testIngestAssetDefaultStillAppendsTimelineClip() throws {
        let store = ProjectStore()
        var workspace = try store.createProject(named: "Ingest Fixture Default", origin: .recording)
        defer { try? FileManager.default.removeItem(at: workspace.summary.projectURL) }

        let sourceURL = try makeTemporaryMediaFile(extension: "mov")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        workspace = try store.ingestAsset(
            from: sourceURL,
            into: workspace,
            preferredType: .video,
            preferredTrackKind: .video
        )

        XCTAssertEqual(workspace.file.assets.count, 1)
        XCTAssertEqual(workspace.file.timelineClips.count, 1)
    }

    private func makeTemporaryMediaFile(`extension`: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macedits-ingest-\(UUID().uuidString)")
            .appendingPathExtension(`extension`)
        try Data("fixture".utf8).write(to: url, options: .atomic)
        return url
    }
}
