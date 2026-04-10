import XCTest
@testable import MacEdits

final class TimelineEditingTests: XCTestCase {
    func testSplitClipAtPlayheadCreatesTwoSegments() {
        var file = makeFile(duration: 4.0)
        guard let originalClip = file.timelineClips.first else {
            XCTFail("Missing initial clip")
            return
        }

        let insertedID = file.splitClip(originalClip.id, at: 1.5)
        XCTAssertNotNil(insertedID)

        let clips = file.clips(for: originalClip.trackID)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].duration, 1.5, accuracy: 0.0001)
        XCTAssertEqual(clips[1].startTime, 1.5, accuracy: 0.0001)
        XCTAssertEqual(clips[1].duration, 2.5, accuracy: 0.0001)
        XCTAssertEqual(clips[1].sourceStart, 1.5, accuracy: 0.0001)
    }

    func testSplitClipClampsNearStartToMinimumSegment() {
        var file = makeFile(duration: 1.0)
        guard let originalClip = file.timelineClips.first else {
            XCTFail("Missing initial clip")
            return
        }

        let insertedID = file.splitClip(originalClip.id, at: originalClip.startTime)
        XCTAssertNotNil(insertedID)

        let clips = file.clips(for: originalClip.trackID)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].duration, 0.25, accuracy: 0.0001)
        XCTAssertEqual(clips[1].duration, 0.75, accuracy: 0.0001)
        XCTAssertEqual(clips[1].startTime, 0.25, accuracy: 0.0001)
    }

    func testSplitClipTooShortReturnsNil() {
        var file = makeFile(duration: 0.4)
        guard let originalClip = file.timelineClips.first else {
            XCTFail("Missing initial clip")
            return
        }

        let insertedID = file.splitClip(originalClip.id, at: 0.2)
        XCTAssertNil(insertedID)
        XCTAssertEqual(file.timelineClips.count, 1)
        XCTAssertEqual(file.timelineClips[0].duration, 0.4, accuracy: 0.0001)
    }

    func testSlipClipContentClampsToSourceRange() {
        var file = makeFile(duration: 4.0)
        guard var clip = file.timelineClips.first else {
            XCTFail("Missing clip")
            return
        }

        clip.sourceDuration = 8.0
        file.timelineClips[0] = clip

        file.slipClipContent(clip.id, by: 3.2)

        guard let moved = file.timelineClips.first(where: { $0.id == clip.id }) else {
            XCTFail("Missing adjusted clip")
            return
        }
        XCTAssertEqual(moved.sourceStart, 3.2, accuracy: 0.0001)

        file.slipClipContent(clip.id, by: 10)
        guard let clampedHigh = file.timelineClips.first(where: { $0.id == clip.id }) else {
            XCTFail("Missing adjusted clip after high clamp")
            return
        }
        XCTAssertEqual(clampedHigh.sourceStart, 4.0, accuracy: 0.0001)

        file.slipClipContent(clip.id, by: -20)
        guard let clampedLow = file.timelineClips.first(where: { $0.id == clip.id }) else {
            XCTFail("Missing adjusted clip after low clamp")
            return
        }
        XCTAssertEqual(clampedLow.sourceStart, 0.0, accuracy: 0.0001)
    }

    func testExtractAudioFromClipCreatesVoiceoverClip() {
        var file = makeFile(duration: 5.0)
        guard let source = file.timelineClips.first else {
            XCTFail("Missing source clip")
            return
        }

        let extractedID = file.extractAudioFromClip(source.id, into: .voiceover)
        XCTAssertNotNil(extractedID)
        guard let extractedID,
              let extracted = file.timelineClips.first(where: { $0.id == extractedID })
        else {
            XCTFail("Missing extracted clip")
            return
        }

        XCTAssertEqual(extracted.lane, .voiceover)
        XCTAssertEqual(extracted.startTime, source.startTime, accuracy: 0.0001)
        XCTAssertEqual(extracted.duration, source.duration, accuracy: 0.0001)
        XCTAssertEqual(extracted.assetID, source.assetID)
    }

    func testReplaceClipWithSourceSegmentsReplacesWithMultipleClips() {
        var file = makeFile(duration: 6.0)
        guard let original = file.timelineClips.first else {
            XCTFail("Missing source clip")
            return
        }

        let insertedIDs = file.replaceClipWithSourceSegments(
            original.id,
            sourceSegments: [0.0...1.0, 2.0...3.5, 4.2...5.0]
        )

        XCTAssertEqual(insertedIDs.count, 3)
        let clips = file.clips(for: original.trackID)
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips[0].sourceStart, 0.0, accuracy: 0.0001)
        XCTAssertEqual(clips[0].duration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(clips[1].sourceStart, 2.0, accuracy: 0.0001)
        XCTAssertEqual(clips[1].duration, 1.5, accuracy: 0.0001)
        XCTAssertEqual(clips[2].sourceStart, 4.2, accuracy: 0.0001)
        XCTAssertEqual(clips[2].duration, 0.8, accuracy: 0.0001)
        XCTAssertEqual(clips[0].startTime, 0.0, accuracy: 0.0001)
        XCTAssertEqual(clips[1].startTime, 1.0, accuracy: 0.0001)
        XCTAssertEqual(clips[2].startTime, 2.5, accuracy: 0.0001)
    }

    func testTransitionSetUpdateAndRemoveClampsDuration() {
        var file = makeFile(duration: 4.0)
        guard let first = file.timelineClips.first else {
            XCTFail("Missing initial clip")
            return
        }
        guard let secondID = file.splitClip(first.id, at: 2.0) else {
            XCTFail("Failed to split clip")
            return
        }

        file.setTransition(from: first.id, to: secondID, type: .slideLeft, duration: 5.0)
        guard let created = file.transition(between: first.id, and: secondID) else {
            XCTFail("Transition should be created")
            return
        }
        XCTAssertEqual(created.type, .slideLeft)
        XCTAssertEqual(created.duration, 2.0, accuracy: 0.0001)

        file.setTransition(from: first.id, to: secondID, type: .crossDissolve, duration: 0.05)
        guard let updated = file.transition(between: first.id, and: secondID) else {
            XCTFail("Transition should be updated")
            return
        }
        XCTAssertEqual(updated.type, .crossDissolve)
        XCTAssertEqual(updated.duration, 0.1, accuracy: 0.0001)

        file.setTransition(from: first.id, to: secondID, type: .none)
        XCTAssertNil(file.transition(between: first.id, and: secondID))
    }

    func testMarkersAreSortedAndNoteOperationsWork() {
        var file = makeFile(duration: 3.0)
        let idA = file.addMarker(at: 5.0, label: "A", color: .blue)
        let idB = file.addMarker(at: 1.0, label: "B", color: .red)
        let idC = file.addMarker(at: 3.0, label: "C", color: .green, note: "start")
        _ = idA

        XCTAssertEqual(file.markers.map(\.time), [1.0, 3.0, 5.0], "Markers should stay time-sorted")

        file.updateMarker(idC, label: "Updated", color: .yellow, note: "note")
        guard let updated = file.markers.first(where: { $0.id == idC }) else {
            XCTFail("Updated marker missing")
            return
        }
        XCTAssertEqual(updated.label, "Updated")
        XCTAssertEqual(updated.color, .yellow)
        XCTAssertEqual(updated.note, "note")

        file.clearMarkerNote(idC)
        XCTAssertNil(file.markers.first(where: { $0.id == idC })?.note)

        file.removeMarker(idB)
        XCTAssertNil(file.markers.first(where: { $0.id == idB }))
    }

    func testMoveClipToIndexAndDeleteNormalizesTrackTimings() {
        var file = makeFile(duration: 6.0)
        guard let first = file.timelineClips.first else {
            XCTFail("Missing initial clip")
            return
        }
        guard let secondID = file.splitClip(first.id, at: 2.0) else {
            XCTFail("Failed first split")
            return
        }
        guard let thirdID = file.splitClip(secondID, at: 4.0) else {
            XCTFail("Failed second split")
            return
        }

        let trackID = first.trackID
        var clips = file.clips(for: trackID)
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips.map(\.startTime), [0.0, 2.0, 4.0])

        file.moveClip(thirdID, toIndex: 0)
        clips = file.clips(for: trackID)
        XCTAssertEqual(clips.count, 3)
        XCTAssertEqual(clips[0].id, thirdID)
        XCTAssertEqual(clips.map(\.startTime), [0.0, 2.0, 4.0], "Track should be normalized after reorder")

        file.deleteClip(secondID)
        clips = file.clips(for: trackID)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips.map(\.startTime), [0.0, 2.0], "Track should remain gapless after delete")
    }

    func testNonRippleDeletePreservesTrackGaps() {
        var file = makeFile(duration: 6.0)
        guard let first = file.timelineClips.first else {
            XCTFail("Missing initial clip")
            return
        }
        guard let secondID = file.splitClip(first.id, at: 2.0),
              let _ = file.splitClip(secondID, at: 4.0)
        else {
            XCTFail("Failed to create three clips")
            return
        }

        file.deleteClip(secondID, ripple: false)

        let clips = file.clips(for: first.trackID)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].startTime, 0.0, accuracy: 0.0001)
        XCTAssertEqual(clips[0].duration, 2.0, accuracy: 0.0001)
        XCTAssertEqual(clips[1].startTime, 4.0, accuracy: 0.0001, "Second clip should keep its timeline position when ripple is disabled")
        XCTAssertEqual(file.totalDuration, 6.0, accuracy: 0.0001)
    }

    func testNonRippleTrimEndStopsAtNextClipBoundary() {
        var file = makeFile(duration: 6.0)
        guard let first = file.timelineClips.first else {
            XCTFail("Missing initial clip")
            return
        }
        guard let secondID = file.splitClip(first.id, at: 2.0),
              let _ = file.splitClip(secondID, at: 4.0)
        else {
            XCTFail("Failed to create three clips")
            return
        }

        file.deleteClip(secondID, ripple: false)
        guard let firstClip = file.clips(for: first.trackID).first else {
            XCTFail("Missing first clip")
            return
        }

        file.trimClipEnd(firstClip.id, delta: 5.0, ripple: false)

        let clips = file.clips(for: first.trackID)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].duration, 4.0, accuracy: 0.0001, "Trim should clamp at the next clip start when ripple is disabled")
        XCTAssertEqual(clips[1].startTime, 4.0, accuracy: 0.0001)
    }

    func testNonRippleTrimStartMovesClipWithinAvailableGap() {
        var file = makeFile(duration: 6.0)
        guard let first = file.timelineClips.first else {
            XCTFail("Missing initial clip")
            return
        }
        guard let secondID = file.splitClip(first.id, at: 2.0),
              let _ = file.splitClip(secondID, at: 4.0)
        else {
            XCTFail("Failed to create three clips")
            return
        }

        file.deleteClip(secondID, ripple: false)
        guard let trailingClip = file.clips(for: first.trackID).last else {
            XCTFail("Missing trailing clip")
            return
        }

        file.trimClipStart(trailingClip.id, delta: -1.5, ripple: false)

        let clips = file.clips(for: first.trackID)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].startTime, 0.0, accuracy: 0.0001)
        XCTAssertEqual(clips[0].duration, 2.0, accuracy: 0.0001)
        XCTAssertEqual(clips[1].startTime, 2.5, accuracy: 0.0001, "Clip should move left into available gap")
        XCTAssertEqual(clips[1].duration, 3.5, accuracy: 0.0001)
    }

    func testDeleteClipRemovesTransitionsReferencingDeletedClip() {
        var file = makeFile(duration: 4.0)
        guard let first = file.timelineClips.first,
              let secondID = file.splitClip(first.id, at: 2.0)
        else {
            XCTFail("Failed to build transition fixture")
            return
        }

        file.setTransition(from: first.id, to: secondID, type: .crossDissolve, duration: 0.5)
        XCTAssertEqual(file.transitions.count, 1)

        file.deleteClip(secondID, ripple: false)
        XCTAssertTrue(file.transitions.isEmpty, "Deleting a clip should clean up dangling transitions")
    }

    private func makeFile(duration: Double) -> ReelProjectFile {
        let now = Date()
        let assetID = UUID()
        let trackID = UUID()
        let musicTrackID = UUID()
        let voiceTrackID = UUID()
        let captionsTrackID = UUID()

        return ReelProjectFile(
            id: UUID(),
            name: "Test",
            createdAt: now,
            updatedAt: now,
            origin: .recording,
            notes: "",
            assets: [
                ProjectAsset(
                    id: assetID,
                    type: .video,
                    fileName: "test.mov",
                    originalName: "test.mov",
                    importedAt: now
                ),
            ],
            timelineTracks: [
                ProjectTrack(id: trackID, kind: .video, displayName: "Video"),
                ProjectTrack(id: musicTrackID, kind: .music, displayName: "Music"),
                ProjectTrack(id: voiceTrackID, kind: .voiceover, displayName: "Voiceover"),
                ProjectTrack(id: captionsTrackID, kind: .captions, displayName: "Captions"),
            ],
            timelineClips: [
                TimelineClip(
                    id: UUID(),
                    assetID: assetID,
                    trackID: trackID,
                    lane: .video,
                    title: "Clip",
                    startTime: 0,
                    duration: duration,
                    sourceStart: 0,
                    sourceDuration: duration
                ),
            ],
            exportPreset: .reels1080
        )
    }
}
