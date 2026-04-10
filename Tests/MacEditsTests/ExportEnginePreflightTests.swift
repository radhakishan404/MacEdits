import Foundation
import XCTest
@testable import MacEdits

@MainActor
final class ExportEnginePreflightTests: XCTestCase {
    func testExportWithoutVideoClipsThrowsNoVideoClips() async {
        let engine = ExportEngine()
        let workspace = makeWorkspaceWithoutVideoClips()

        do {
            _ = try await engine.export(workspace: workspace)
            XCTFail("Expected export to fail when no video clips are present.")
        } catch let error as ExportEngineError {
            guard case .noVideoClips = error else {
                XCTFail("Expected noVideoClips, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected ExportEngineError, got \(error)")
        }
    }

    func testExportWithTransitionsAndNonCleanStyleDoesNotFailPreflight() async {
        let engine = ExportEngine()
        let workspace = makeWorkspaceWithTransitionStyleRisk()

        do {
            _ = try await engine.export(workspace: workspace)
        } catch let error as ExportEngineError {
            if case .transitionStyleParityRisk = error {
                XCTFail("Transition/style parity should not hard-fail preflight anymore.")
            }
        } catch {
            // Any non-parity error is acceptable in this fixture because media is placeholder-only.
        }
    }

    private func makeWorkspaceWithoutVideoClips() -> ProjectWorkspace {
        let now = Date()
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("macedits-export-preflight-\(UUID().uuidString).macedits", isDirectory: true)
        let videoTrack = ProjectTrack(id: UUID(), kind: .video, displayName: "Video")
        let musicTrack = ProjectTrack(id: UUID(), kind: .music, displayName: "Music")

        let file = ReelProjectFile(
            id: UUID(),
            name: "NoVideo",
            createdAt: now,
            updatedAt: now,
            origin: .recording,
            notes: "",
            assets: [],
            timelineTracks: [videoTrack, musicTrack],
            timelineClips: [],
            exportPreset: .reels1080
        )

        let summary = ProjectSummary(
            id: file.id,
            name: file.name,
            projectURL: projectURL,
            createdAt: now,
            updatedAt: now,
            origin: .recording
        )
        return ProjectWorkspace(summary: summary, file: file)
    }

    private func makeWorkspaceWithTransitionStyleRisk() -> ProjectWorkspace {
        let now = Date()
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("macedits-export-risk-\(UUID().uuidString).macedits", isDirectory: true)
        let assetID = UUID()
        let videoTrack = ProjectTrack(id: UUID(), kind: .video, displayName: "Video")

        let firstClip = TimelineClip(
            id: UUID(),
            assetID: assetID,
            trackID: videoTrack.id,
            lane: .video,
            title: "A",
            startTime: 0,
            duration: 3
        )
        let secondClip = TimelineClip(
            id: UUID(),
            assetID: assetID,
            trackID: videoTrack.id,
            lane: .video,
            title: "B",
            startTime: 3,
            duration: 3
        )
        let transition = ClipTransition(
            fromClipID: firstClip.id,
            toClipID: secondClip.id,
            type: .crossDissolve,
            duration: 0.5
        )

        let style = ProjectStyleSettings(
            look: .film,
            lookIntensity: 0.7,
            captionStyle: .clean,
            colorCorrection: .init()
        )

        let file = ReelProjectFile(
            id: UUID(),
            name: "Risk",
            createdAt: now,
            updatedAt: now,
            origin: .recording,
            notes: "",
            assets: [
                ProjectAsset(
                    id: assetID,
                    type: .video,
                    fileName: "placeholder.mov",
                    originalName: "placeholder.mov",
                    importedAt: now
                ),
            ],
            timelineTracks: [videoTrack],
            timelineClips: [firstClip, secondClip],
            transitions: [transition],
            styleSettings: style,
            exportPreset: .reels1080
        )

        let summary = ProjectSummary(
            id: file.id,
            name: file.name,
            projectURL: projectURL,
            createdAt: now,
            updatedAt: now,
            origin: .recording
        )
        return ProjectWorkspace(summary: summary, file: file)
    }
}
