@preconcurrency import AVFoundation
import AppKit
import CoreImage
import Foundation
import Observation

// MARK: - Errors

enum ExportEngineError: LocalizedError {
    case noVideoClips
    case noVideoTrackFound(String)
    case noAudioTrackFound(String)
    case transitionStyleParityRisk
    case unableToCreateExportSession
    case cancelled
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoClips: return "There are no video clips on the timeline to export."
        case let .noVideoTrackFound(n): return "Mac Edits could not find a video track in \(n)."
        case let .noAudioTrackFound(n): return "Mac Edits could not find an audio track in \(n)."
        case .transitionStyleParityRisk:
            return "This export mixes transitions with non-clean look/color settings. Reset look/color or remove transitions to ensure export parity."
        case .unableToCreateExportSession: return "Mac Edits could not create an export session."
        case .cancelled: return "Export cancelled."
        case let .exportFailed(msg): return "Export failed: \(msg)"
        }
    }
}

struct ExportOutputTarget: Equatable {
    let fileType: AVFileType
    let fileExtension: String
}

enum ExportFallbackPolicy {
    static func preferredOutputTargets(from supported: [AVFileType]) -> [ExportOutputTarget] {
        var targets: [ExportOutputTarget] = []
        if supported.contains(.mp4) {
            targets.append(ExportOutputTarget(fileType: .mp4, fileExtension: "mp4"))
        }
        if supported.contains(.mov) {
            targets.append(ExportOutputTarget(fileType: .mov, fileExtension: "mov"))
        }
        if targets.isEmpty, let fallback = supported.first {
            targets.append(ExportOutputTarget(fileType: fallback, fileExtension: fileExtension(for: fallback)))
        }
        return targets
    }

    static func fileExtension(for fileType: AVFileType) -> String {
        switch fileType {
        case .mp4:
            return "mp4"
        case .mov:
            return "mov"
        default:
            let raw = fileType.rawValue.lowercased()
            if raw.contains("mpeg-4") || raw.contains("mp4") {
                return "mp4"
            }
            if raw.contains("quicktime") || raw.contains("mov") {
                return "mov"
            }
            return "mov"
        }
    }

    static func shouldRetryWithAlternateContainer(for message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("operation stopped")
            || lower.contains("cannot encode")
            || lower.contains("cannot decode")
            || lower.contains("unsupported")
            || lower.contains("file type")
            || lower.contains("avfoundationerrordomain")
    }
}

// MARK: - ExportEngine

@MainActor
@Observable
final class ExportEngine {
    private(set) var isExporting = false
    private(set) var progress: Double = 0
    private(set) var phase: String = ""

    private var progressTimer: Timer?
    private var activeSessionHolder: ExportSessionHolder?

    private final class ExportSessionHolder: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    // MARK: - Public

    func export(workspace: ProjectWorkspace) async throws -> URL {
        let videoTrack = workspace.file.timelineTracks.first(where: { $0.kind == .video })
        let videoClips = workspace.file.timelineClips
            .filter { $0.trackID == videoTrack?.id }
            .sorted { $0.startTime < $1.startTime }

        guard !videoClips.isEmpty else { throw ExportEngineError.noVideoClips }
        try runPreflightValidation(workspace: workspace, videoClips: videoClips)

        let renderSize = CGSize(
            width: workspace.file.exportPreset.width,
            height: workspace.file.exportPreset.height
        )

        isExporting = true
        progress = 0
        phase = "Compositing…"

        defer {
            isExporting = false
            stopProgressTimer()
        }

        // ── 1. Build composition ────────────────────────────────────────────
        let composition = AVMutableComposition()
        guard let compVideoTrackA = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ),
        let compVideoTrackB = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportEngineError.unableToCreateExportSession }

        var audioMixParams: [AVMutableAudioMixInputParameters] = []
        var placements: [VideoClipPlacement] = []
        var compositionCursorSeconds = 0.0

        for clip in videoClips {
            guard let asset = workspace.file.asset(for: clip.assetID) else { continue }

            let assetURL = mediaURL(for: asset, projectURL: workspace.summary.projectURL)
            let srcAsset = AVURLAsset(url: assetURL)
            let srcVideoTracks = try await srcAsset.loadTracks(withMediaType: .video)
            guard let srcVideoTrack = srcVideoTracks.first else {
                throw ExportEngineError.noVideoTrackFound(asset.originalName)
            }

            let speed = max(0.1, clip.speedMultiplier)
            let sourceDuration = CMTime(seconds: clip.duration, preferredTimescale: 600)
            let scaledDurationSeconds = clip.duration / speed
            let scaledDuration = CMTime(seconds: scaledDurationSeconds, preferredTimescale: 600)
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: sourceDuration
            )

            var incomingTransition: ClipTransition?
            var incomingTransitionDuration = 0.0
            if let previous = placements.last,
               let transition = workspace.file.transition(between: previous.clip.id, and: clip.id),
               transition.type != .none {
                let requested = max(0.1, min(2.0, transition.duration))
                let maxAllowed = min(requested, previous.duration * 0.45, scaledDurationSeconds * 0.45)
                if maxAllowed > 0.05 {
                    incomingTransition = transition
                    incomingTransitionDuration = maxAllowed
                }
            }

            let clipStartSeconds = max(0, compositionCursorSeconds - incomingTransitionDuration)
            let clipStartTime = CMTime(seconds: clipStartSeconds, preferredTimescale: 600)
            let compositionTrack = placements.count.isMultiple(of: 2) ? compVideoTrackA : compVideoTrackB

            try compositionTrack.insertTimeRange(sourceRange, of: srcVideoTrack, at: clipStartTime)
            if speed != 1.0 {
                let insertedRange = CMTimeRange(start: clipStartTime, duration: sourceDuration)
                compositionTrack.scaleTimeRange(insertedRange, toDuration: scaledDuration)
            }

            let transform = try await makeAspectFillTransform(for: srcVideoTrack, renderSize: renderSize)
            placements.append(
                VideoClipPlacement(
                    clip: clip,
                    asset: asset,
                    compositionTrack: compositionTrack,
                    sourceTrack: srcVideoTrack,
                    start: clipStartSeconds,
                    duration: scaledDurationSeconds,
                    speed: speed,
                    transform: transform,
                    incomingTransition: incomingTransition,
                    incomingTransitionDuration: incomingTransitionDuration
                )
            )
            compositionCursorSeconds = clipStartSeconds + scaledDurationSeconds
        }

        guard !placements.isEmpty else { throw ExportEngineError.noVideoClips }

        // Audio for video clips (with transition-friendly fades)
        for index in placements.indices {
            let placement = placements[index]
            let clip = placement.clip
            guard !clip.isMuted, clip.volume > 0 else { continue }

            let fadeIn = placement.incomingTransitionDuration
            let fadeOut = index + 1 < placements.count ? placements[index + 1].incomingTransitionDuration : 0

            try await appendAudioClip(
                clip,
                asset: placement.asset,
                to: composition,
                at: CMTime(seconds: placement.start, preferredTimescale: 600),
                speed: placement.speed,
                mixParameters: &audioMixParams,
                projectURL: workspace.summary.projectURL,
                fadeInDuration: fadeIn,
                fadeOutDuration: fadeOut
            )
        }

        // Supplemental audio (voiceover, music — no speed scaling)
        try await appendSupplementalAudioClips(
            in: workspace,
            to: composition,
            mixParameters: &audioMixParams
        )

        // ── 2. Build video composition with transitions + geometry ───────────
        phase = "Applying color…"
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(workspace.file.exportPreset.frameRate)
        )
        videoComposition.instructions = makeVideoCompositionInstructions(from: placements, renderSize: renderSize)

        let hasTransitions = placements.contains { placement in
            if let transition = placement.incomingTransition {
                return transition.type != .none && placement.incomingTransitionDuration > 0
            }
            return false
        }

        // CIFilter handler rebuilds instructions and drops transition ramps.
        let cc = workspace.file.styleSettings.colorCorrection
        let look = workspace.file.styleSettings.look
        let lookIntensity = Float(workspace.file.styleSettings.lookIntensity)
        if (cc.isNonDefault || look != .clean) && !hasTransitions {
            let ciComposition = AVVideoComposition(asset: composition) { [cc, look, lookIntensity] request in
                var image = request.sourceImage.clampedToExtent()
                let style = ProjectStyleSettings(
                    look: look, lookIntensity: Double(lookIntensity),
                    captionStyle: .clean, colorCorrection: cc
                )
                image = LookPipeline.applyStyle(to: image, style: style)
                request.finish(with: image.cropped(to: request.sourceImage.extent), context: nil)
            }
            if !workspace.file.textOverlays.isEmpty {
                // Note: animationTool can't be set on a CI-based composition; text overlays
                // are a known limitation when using applyingCIFiltersWithHandler. Skip for now.
            }
            let audioMix = audioMixParams.isEmpty ? nil : AVMutableAudioMix()
            audioMix?.inputParameters = audioMixParams
            phase = "Encoding…"
            return try await runExportSession(
                asset: composition,
                videoComposition: ciComposition,
                audioMix: audioMix,
                workspace: workspace
            )
        }

        // Text overlays
        if !workspace.file.textOverlays.isEmpty {
            videoComposition.animationTool = makeAnimationTool(
                overlays: workspace.file.textOverlays,
                style: workspace.file.styleSettings.captionStyle,
                renderSize: renderSize
            )
        }

        let audioMix = audioMixParams.isEmpty ? nil : AVMutableAudioMix()
        audioMix?.inputParameters = audioMixParams

        phase = "Encoding…"
        do {
            return try await runExportSession(
                asset: composition,
                videoComposition: videoComposition,
                audioMix: audioMix,
                workspace: workspace
            )
        } catch let transitionExportError {
            guard hasTransitions, shouldRetryWithoutTransitions(for: transitionExportError) else {
                throw transitionExportError
            }

            phase = "Retrying without transitions…"
            let fallbackVideoComposition = AVMutableVideoComposition()
            fallbackVideoComposition.renderSize = renderSize
            fallbackVideoComposition.frameDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(workspace.file.exportPreset.frameRate)
            )
            fallbackVideoComposition.instructions = makeBodyOnlyVideoCompositionInstructions(from: placements)

            if !workspace.file.textOverlays.isEmpty {
                fallbackVideoComposition.animationTool = makeAnimationTool(
                    overlays: workspace.file.textOverlays,
                    style: workspace.file.styleSettings.captionStyle,
                    renderSize: renderSize
                )
            }

            do {
                return try await runExportSession(
                    asset: composition,
                    videoComposition: fallbackVideoComposition,
                    audioMix: audioMix,
                    workspace: workspace
                )
            } catch let fallbackError {
                guard shouldRetryWithoutTransitions(for: fallbackError) else {
                    throw fallbackError
                }

                phase = "Retrying baseline export…"
                let baselineVideoComposition = AVMutableVideoComposition(propertiesOf: composition)
                baselineVideoComposition.renderSize = renderSize
                baselineVideoComposition.frameDuration = CMTime(
                    value: 1,
                    timescale: CMTimeScale(workspace.file.exportPreset.frameRate)
                )
                if !workspace.file.textOverlays.isEmpty {
                    baselineVideoComposition.animationTool = makeAnimationTool(
                        overlays: workspace.file.textOverlays,
                        style: workspace.file.styleSettings.captionStyle,
                        renderSize: renderSize
                    )
                }

                return try await runExportSession(
                    asset: composition,
                    videoComposition: baselineVideoComposition,
                    audioMix: audioMix,
                    workspace: workspace
                )
            }
        }
    }

    func cancelExport() {
        guard let holder = activeSessionHolder else { return }
        phase = "Cancelling…"
        holder.session.cancelExport()
    }

    private func runExportSession(
        asset: AVAsset,
        videoComposition: AVVideoComposition,
        audioMix: AVAudioMix?,
        workspace: ProjectWorkspace
    ) async throws -> URL {
        guard let probeSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportEngineError.unableToCreateExportSession
        }
        let targets = ExportFallbackPolicy.preferredOutputTargets(from: probeSession.supportedFileTypes)
        var lastError: Error?

        for (index, target) in targets.enumerated() {
            let exportURL = try makeExportURL(for: workspace.summary.name, fileExtension: target.fileExtension)
            try? FileManager.default.removeItem(at: exportURL)

            guard let session = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                throw ExportEngineError.unableToCreateExportSession
            }
            let sessionHolder = ExportSessionHolder(session)
            activeSessionHolder = sessionHolder

            session.outputURL = exportURL
            session.outputFileType = target.fileType
            session.shouldOptimizeForNetworkUse = false
            session.videoComposition = videoComposition
            session.audioMix = audioMix

            do {
                try await runConfiguredExportSession(sessionHolder)
                return exportURL
            } catch ExportEngineError.cancelled {
                throw ExportEngineError.cancelled
            } catch {
                lastError = error
                let isLast = index == targets.count - 1
                guard !isLast, shouldRetryWithAlternateContainer(for: error) else {
                    throw error
                }
                phase = "Retrying export container…"
            }
        }

        throw lastError ?? ExportEngineError.exportFailed("Export failed before writing output.")
    }

    private func runConfiguredExportSession(_ sessionHolder: ExportSessionHolder) async throws {
        startProgressTimer(for: sessionHolder)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionHolder.session.exportAsynchronously {
                let session = sessionHolder.session
                Task { @MainActor in
                    self.stopProgressTimer()
                    self.activeSessionHolder = nil

                    switch session.status {
                    case .completed:
                        self.isExporting = false
                        self.progress = 1
                        self.phase = "Done"
                        cont.resume(returning: ())
                    case .cancelled:
                        self.isExporting = false
                        self.progress = 0
                        self.phase = "Cancelled"
                        cont.resume(throwing: ExportEngineError.cancelled)
                    case .failed:
                        self.isExporting = false
                        self.phase = "Failed"
                        if let error = session.error {
                            let nsError = error as NSError
                            let reason = nsError.localizedFailureReason ?? ""
                            let suggestion = nsError.localizedRecoverySuggestion ?? ""
                            let details = [
                                nsError.localizedDescription,
                                reason,
                                suggestion,
                                "domain=\(nsError.domain)",
                                "code=\(nsError.code)"
                            ]
                                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                .joined(separator: " | ")
                            cont.resume(throwing: ExportEngineError.exportFailed(details))
                        } else {
                            cont.resume(throwing: ExportEngineError.exportFailed("Export failed with unknown error."))
                        }
                    default:
                        self.isExporting = false
                        self.phase = "Failed"
                        cont.resume(throwing: ExportEngineError.exportFailed("Status: \(session.status.rawValue)"))
                    }
                }
            }
        }
    }

    private func shouldRetryWithAlternateContainer(for error: Error) -> Bool {
        guard case let ExportEngineError.exportFailed(message) = error else {
            return false
        }
        return ExportFallbackPolicy.shouldRetryWithAlternateContainer(for: message)
    }

    private func runPreflightValidation(
        workspace: ProjectWorkspace,
        videoClips: [TimelineClip]
    ) throws {
        _ = workspace
        _ = videoClips
        // Keep preflight hook in place for future validations.
        // Transition + look/style exports now continue instead of hard-failing.
    }

    private func shouldRetryWithoutTransitions(for error: Error) -> Bool {
        guard case let ExportEngineError.exportFailed(message) = error else {
            return false
        }
        let lower = message.lowercased()
        return lower.contains("operation stopped")
            || lower.contains("cannot decode")
            || lower.contains("invalid")
            || lower.contains("video composition")
    }

    // MARK: - Audio helpers

    private func appendSupplementalAudioClips(
        in workspace: ProjectWorkspace,
        to composition: AVMutableComposition,
        mixParameters: inout [AVMutableAudioMixInputParameters]
    ) async throws {
        let kinds: Set<TrackKind> = [.music, .voiceover]
        let clips = workspace.file.timelineClips
            .filter { kinds.contains($0.lane) }
            .sorted { $0.startTime < $1.startTime }

        for clip in clips {
            guard !clip.isMuted, clip.volume > 0 else { continue }
            guard let asset = workspace.file.asset(for: clip.assetID) else { continue }
            let at = CMTime(seconds: clip.startTime, preferredTimescale: 600)
            try await appendAudioClip(
                clip, asset: asset, to: composition,
                at: at, speed: 1.0,
                mixParameters: &mixParameters,
                projectURL: workspace.summary.projectURL
            )
        }
    }

    private func appendAudioClip(
        _ clip: TimelineClip,
        asset: ProjectAsset,
        to composition: AVMutableComposition,
        at insertionTime: CMTime,
        speed: Double,
        mixParameters: inout [AVMutableAudioMixInputParameters],
        projectURL: URL,
        fadeInDuration: Double = 0,
        fadeOutDuration: Double = 0
    ) async throws {
        let srcAsset = AVURLAsset(url: mediaURL(for: asset, projectURL: projectURL))
        let srcAudioTracks = try await srcAsset.loadTracks(withMediaType: .audio)
        guard let srcAudioTrack = srcAudioTracks.first else {
            if asset.type == .audio || clip.lane == .voiceover || clip.lane == .music {
                throw ExportEngineError.noAudioTrackFound(asset.originalName)
            }
            return
        }

        guard let compAudioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw ExportEngineError.unableToCreateExportSession }

        let sourceDuration = CMTime(seconds: clip.duration, preferredTimescale: 600)
        let sourceRange = CMTimeRange(
            start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
            duration: sourceDuration
        )
        try compAudioTrack.insertTimeRange(sourceRange, of: srcAudioTrack, at: insertionTime)

        // Apply speed to audio if needed
        if speed != 1.0 {
            let insertedRange = CMTimeRange(start: insertionTime, duration: sourceDuration)
            let scaledDuration = CMTime(seconds: clip.duration / speed, preferredTimescale: 600)
            compAudioTrack.scaleTimeRange(insertedRange, toDuration: scaledDuration)
        }

        let params = AVMutableAudioMixInputParameters(track: compAudioTrack)
        let outputDuration = clip.duration / max(speed, 0.1)
        let maxFade = outputDuration * 0.45
        let fadeIn = min(max(0, fadeInDuration), maxFade)
        let fadeOut = min(max(0, fadeOutDuration), maxFade)
        let volume = Float(clip.volume)

        if fadeIn > 0 {
            params.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: volume,
                timeRange: CMTimeRange(
                    start: insertionTime,
                    duration: CMTime(seconds: fadeIn, preferredTimescale: 600)
                )
            )
        } else {
            params.setVolume(volume, at: insertionTime)
        }

        if fadeOut > 0 {
            let fadeOutStart = max(fadeIn, outputDuration - fadeOut)
            params.setVolumeRamp(
                fromStartVolume: volume,
                toEndVolume: 0,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: insertionTime.seconds + fadeOutStart, preferredTimescale: 600),
                    duration: CMTime(seconds: fadeOut, preferredTimescale: 600)
                )
            )
        }

        mixParameters.append(params)
    }

    // MARK: - Video instruction

    private struct VideoClipPlacement {
        let clip: TimelineClip
        let asset: ProjectAsset
        let compositionTrack: AVCompositionTrack
        let sourceTrack: AVAssetTrack
        let start: Double
        let duration: Double
        let speed: Double
        let transform: CGAffineTransform
        let incomingTransition: ClipTransition?
        let incomingTransitionDuration: Double
    }

    private func makeVideoCompositionInstructions(
        from placements: [VideoClipPlacement],
        renderSize: CGSize
    ) -> [AVMutableVideoCompositionInstruction] {
        var result: [AVMutableVideoCompositionInstruction] = []

        for index in placements.indices {
            let current = placements[index]
            let outgoingDuration = index + 1 < placements.count ? placements[index + 1].incomingTransitionDuration : 0

            let bodyStart = current.start + current.incomingTransitionDuration
            let bodyEnd = current.start + current.duration - outgoingDuration
            if bodyEnd - bodyStart > 0.02 {
                let bodyInstruction = AVMutableVideoCompositionInstruction()
                bodyInstruction.timeRange = CMTimeRange(
                    start: CMTime(seconds: bodyStart, preferredTimescale: 600),
                    duration: CMTime(seconds: bodyEnd - bodyStart, preferredTimescale: 600)
                )
                let bodyLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: current.compositionTrack)
                bodyLayer.setTransform(current.transform, at: bodyInstruction.timeRange.start)
                bodyInstruction.layerInstructions = [bodyLayer]
                result.append(bodyInstruction)
            }

            guard index + 1 < placements.count else { continue }
            let next = placements[index + 1]
            guard let transition = next.incomingTransition, next.incomingTransitionDuration > 0.02 else { continue }

            let transitionInstruction = AVMutableVideoCompositionInstruction()
            transitionInstruction.timeRange = CMTimeRange(
                start: CMTime(seconds: next.start, preferredTimescale: 600),
                duration: CMTime(seconds: next.incomingTransitionDuration, preferredTimescale: 600)
            )

            let fromLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: current.compositionTrack)
            let toLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: next.compositionTrack)
            fromLayer.setTransform(current.transform, at: transitionInstruction.timeRange.start)
            toLayer.setTransform(next.transform, at: transitionInstruction.timeRange.start)

            applyTransition(
                transition.type,
                from: fromLayer,
                to: toLayer,
                fromTransform: current.transform,
                toTransform: next.transform,
                timeRange: transitionInstruction.timeRange,
                renderSize: renderSize
            )

            transitionInstruction.layerInstructions = [toLayer, fromLayer]
            result.append(transitionInstruction)
        }

        return result.sorted { lhs, rhs in
            lhs.timeRange.start.seconds < rhs.timeRange.start.seconds
        }
    }

    private func makeBodyOnlyVideoCompositionInstructions(
        from placements: [VideoClipPlacement]
    ) -> [AVMutableVideoCompositionInstruction] {
        let instructions = placements.compactMap { placement -> AVMutableVideoCompositionInstruction? in
            let bodyStart = placement.start + placement.incomingTransitionDuration
            let bodyEnd = placement.start + placement.duration
            guard bodyEnd - bodyStart > 0.02 else { return nil }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(
                start: CMTime(seconds: bodyStart, preferredTimescale: 600),
                duration: CMTime(seconds: bodyEnd - bodyStart, preferredTimescale: 600)
            )
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: placement.compositionTrack)
            layer.setTransform(placement.transform, at: instruction.timeRange.start)
            instruction.layerInstructions = [layer]
            return instruction
        }

        return instructions.sorted { lhs, rhs in
            lhs.timeRange.start.seconds < rhs.timeRange.start.seconds
        }
    }

    private func applyTransition(
        _ type: TransitionType,
        from fromLayer: AVMutableVideoCompositionLayerInstruction,
        to toLayer: AVMutableVideoCompositionLayerInstruction,
        fromTransform: CGAffineTransform,
        toTransform: CGAffineTransform,
        timeRange: CMTimeRange,
        renderSize: CGSize
    ) {
        let start = timeRange.start
        let end = CMTimeAdd(timeRange.start, timeRange.duration)

        switch type {
        case .none:
            break

        case .crossDissolve:
            fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: timeRange)
            toLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: timeRange)

        case .fadeToBlack:
            let halfDuration = CMTimeMultiplyByFloat64(timeRange.duration, multiplier: 0.5)
            let midpoint = CMTimeAdd(start, halfDuration)
            let firstHalf = CMTimeRange(start: start, duration: halfDuration)
            let secondHalf = CMTimeRange(start: midpoint, duration: CMTimeSubtract(end, midpoint))
            fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: firstHalf)
            toLayer.setOpacity(0, at: start)
            toLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: secondHalf)

        case .slideLeft:
            fromLayer.setTransformRamp(
                fromStart: fromTransform,
                toEnd: fromTransform.concatenating(CGAffineTransform(translationX: -renderSize.width, y: 0)),
                timeRange: timeRange
            )
            toLayer.setTransformRamp(
                fromStart: toTransform.concatenating(CGAffineTransform(translationX: renderSize.width, y: 0)),
                toEnd: toTransform,
                timeRange: timeRange
            )
            fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0.2, timeRange: timeRange)
            toLayer.setOpacityRamp(fromStartOpacity: 0.8, toEndOpacity: 1, timeRange: timeRange)

        case .slideRight:
            fromLayer.setTransformRamp(
                fromStart: fromTransform,
                toEnd: fromTransform.concatenating(CGAffineTransform(translationX: renderSize.width, y: 0)),
                timeRange: timeRange
            )
            toLayer.setTransformRamp(
                fromStart: toTransform.concatenating(CGAffineTransform(translationX: -renderSize.width, y: 0)),
                toEnd: toTransform,
                timeRange: timeRange
            )
            fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0.2, timeRange: timeRange)
            toLayer.setOpacityRamp(fromStartOpacity: 0.8, toEndOpacity: 1, timeRange: timeRange)

        case .slideUp:
            fromLayer.setTransformRamp(
                fromStart: fromTransform,
                toEnd: fromTransform.concatenating(CGAffineTransform(translationX: 0, y: renderSize.height)),
                timeRange: timeRange
            )
            toLayer.setTransformRamp(
                fromStart: toTransform.concatenating(CGAffineTransform(translationX: 0, y: -renderSize.height)),
                toEnd: toTransform,
                timeRange: timeRange
            )
            fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0.2, timeRange: timeRange)
            toLayer.setOpacityRamp(fromStartOpacity: 0.8, toEndOpacity: 1, timeRange: timeRange)

        case .slideDown:
            fromLayer.setTransformRamp(
                fromStart: fromTransform,
                toEnd: fromTransform.concatenating(CGAffineTransform(translationX: 0, y: -renderSize.height)),
                timeRange: timeRange
            )
            toLayer.setTransformRamp(
                fromStart: toTransform.concatenating(CGAffineTransform(translationX: 0, y: renderSize.height)),
                toEnd: toTransform,
                timeRange: timeRange
            )
            fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0.2, timeRange: timeRange)
            toLayer.setOpacityRamp(fromStartOpacity: 0.8, toEndOpacity: 1, timeRange: timeRange)

        case .wipeLeft:
            toLayer.setTransformRamp(
                fromStart: toTransform.concatenating(CGAffineTransform(translationX: renderSize.width * 0.8, y: 0)),
                toEnd: toTransform,
                timeRange: timeRange
            )
            fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0.35, timeRange: timeRange)
            toLayer.setOpacityRamp(fromStartOpacity: 0.7, toEndOpacity: 1, timeRange: timeRange)

        case .wipeRight:
            toLayer.setTransformRamp(
                fromStart: toTransform.concatenating(CGAffineTransform(translationX: -renderSize.width * 0.8, y: 0)),
                toEnd: toTransform,
                timeRange: timeRange
            )
            fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0.35, timeRange: timeRange)
            toLayer.setOpacityRamp(fromStartOpacity: 0.7, toEndOpacity: 1, timeRange: timeRange)

        case .zoom:
            fromLayer.setTransformRamp(
                fromStart: fromTransform,
                toEnd: fromTransform.scaledBy(x: 1.18, y: 1.18),
                timeRange: timeRange
            )
            toLayer.setTransformRamp(
                fromStart: toTransform.scaledBy(x: 0.84, y: 0.84),
                toEnd: toTransform,
                timeRange: timeRange
            )
            fromLayer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: timeRange)
            toLayer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: timeRange)
        }
    }

    private func makeInstruction(
        for compositionTrack: AVCompositionTrack,
        sourceTrack: AVAssetTrack,
        outputRange: CMTimeRange,
        renderSize: CGSize
    ) async throws -> AVMutableVideoCompositionInstruction {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = outputRange

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        let transform = try await makeAspectFillTransform(for: sourceTrack, renderSize: renderSize)
        layerInstruction.setTransform(transform, at: outputRange.start)
        instruction.layerInstructions = [layerInstruction]
        return instruction
    }

    // MARK: - Transform

    private func makeAspectFillTransform(
        for sourceTrack: AVAssetTrack,
        renderSize: CGSize
    ) async throws -> CGAffineTransform {
        let preferred = try await sourceTrack.load(.preferredTransform)
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let rotated = naturalSize.applying(preferred)
        let absolute = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        let scale = max(
            renderSize.width  / max(absolute.width, 1),
            renderSize.height / max(absolute.height, 1)
        )
        var t = preferred.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let scaled = CGSize(width: absolute.width * scale, height: absolute.height * scale)
        t = t.concatenating(CGAffineTransform(
            translationX: (renderSize.width  - scaled.width)  / 2,
            y:            (renderSize.height - scaled.height) / 2
        ))
        return t
    }

    // MARK: - Media URL

    private func mediaURL(for asset: ProjectAsset, projectURL: URL) -> URL {
        projectURL.appendingPathComponent("media", isDirectory: true)
                  .appendingPathComponent(asset.fileName)
    }

    // MARK: - Text overlays (CALayer)

    private func makeAnimationTool(
        overlays: [ProjectTextOverlay],
        style: CaptionLook,
        renderSize: CGSize
    ) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = false

        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let over = CALayer()
        over.frame = parent.frame
        parent.addSublayer(over)

        for overlay in overlays {
            over.addSublayer(makeTextLayer(for: overlay, captionStyle: style, renderSize: renderSize))
        }

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    private func makeTextLayer(
        for overlay: ProjectTextOverlay,
        captionStyle: CaptionLook,
        renderSize: CGSize
    ) -> CALayer {
        let container = CALayer()
        container.frame = frame(for: overlay, renderSize: renderSize)
        container.opacity = 0

        let textLayer = CATextLayer()
        textLayer.frame = container.bounds
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.string = overlay.text
        textLayer.alignmentMode = overlay.position == .center ? .center : .left
        textLayer.isWrapped = true
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.font = font(for: overlay.style)
        textLayer.fontSize = fontSize(for: overlay.style)

        if overlay.style == .caption || captionStyle != .clean {
            let bg = CALayer()
            bg.frame = container.bounds.insetBy(dx: -14, dy: -10)
            bg.cornerRadius = 18
            bg.backgroundColor = backgroundColor(for: captionStyle).cgColor
            container.addSublayer(bg)
        }
        container.addSublayer(textLayer)

        // Fade animations
        func anim(_ from: Float, _ to: Float, at begin: Double, dur: Double) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from; a.toValue = to
            a.beginTime = AVCoreAnimationBeginTimeAtZero + begin
            a.duration = dur; a.fillMode = .both; a.isRemovedOnCompletion = false
            return a
        }
        let total = overlay.endTime - overlay.startTime
        let fadeDur = min(0.12, total * 0.1)
        let group = CAAnimationGroup()
        group.animations = [
            anim(0, 1, at: overlay.startTime, dur: fadeDur),
            anim(1, 1, at: overlay.startTime + fadeDur, dur: max(0, total - fadeDur * 2)),
            anim(1, 0, at: overlay.endTime - fadeDur, dur: fadeDur),
        ]
        group.beginTime = AVCoreAnimationBeginTimeAtZero
        group.duration = overlay.endTime + 0.2
        group.fillMode = .both; group.isRemovedOnCompletion = false
        container.add(group, forKey: "captionOpacity")
        return container
    }

    private func frame(for overlay: ProjectTextOverlay, renderSize: CGSize) -> CGRect {
        let inset: CGFloat = 72
        let width = renderSize.width - inset * 2
        let height: CGFloat = overlay.style == .title ? 140 : overlay.style == .subtitle ? 96 : 120
        let y: CGFloat
        switch overlay.position {
        case .top: y = renderSize.height - height - 140
        case .center: y = (renderSize.height - height) / 2
        case .bottom: y = 250
        }
        return CGRect(x: inset, y: y, width: width, height: height)
    }

    private func font(for style: TextOverlayStyle) -> NSFont {
        switch style {
        case .title: return NSFont.systemFont(ofSize: 56, weight: .bold)
        case .subtitle: return NSFont.systemFont(ofSize: 38, weight: .semibold)
        case .caption: return NSFont.systemFont(ofSize: 34, weight: .bold)
        }
    }

    private func fontSize(for style: TextOverlayStyle) -> CGFloat {
        switch style { case .title: 56; case .subtitle: 38; case .caption: 34 }
    }

    private func backgroundColor(for style: CaptionLook) -> NSColor {
        switch style {
        case .clean: .black.withAlphaComponent(0.5)
        case .bold: NSColor(calibratedRed: 0.98, green: 0.35, blue: 0.18, alpha: 0.9)
        case .story: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.16, alpha: 0.88)
        }
    }

    // MARK: - Progress timer

    private func startProgressTimer(for sessionHolder: ExportSessionHolder) {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.progress = Double(sessionHolder.session.progress) }
        }
    }

    private func stopProgressTimer() { progressTimer?.invalidate(); progressTimer = nil }

    // MARK: - Export URL

    private func makeExportURL(for name: String, fileExtension: String) throws -> URL {
        let fm = FileManager.default
        guard let movies = fm.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw ExportEngineError.exportFailed("Movies directory unavailable.")
        }
        let dir = movies.appendingPathComponent("Mac Edits Exports", isDirectory: true)
        if !fm.fileExists(atPath: dir.path()) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = name.replacingOccurrences(of: " ", with: "-")
        let safeExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "mov" : fileExtension
        return dir
            .appendingPathComponent("\(safeName)-\(fmt.string(from: Date()))")
            .appendingPathExtension(safeExtension)
    }
}

// MARK: - ColorCompositorParameters

struct ColorCompositorParameters {
    let colorCorrection: ColorCorrection
    let look: LookPreset
    let lookIntensity: Double
}

// MARK: - ColorCompositor (AVVideoCompositing)

final class ColorCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Shared parameters set before export starts. nonisolated(unsafe) suppresses
    /// the Swift 6 concurrency warning — access is always serialized by the export flow.
    nonisolated(unsafe) static var parameters = ColorCompositorParameters(
        colorCorrection: ColorCorrection(),
        look: .clean,
        lookIntensity: 0.0
    )

    var sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    private let renderQueue = DispatchQueue(label: "com.macedits.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func renderContextChanged(_ newContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            guard let trackID = request.sourceTrackIDs.first.map({ CMPersistentTrackID($0.int32Value) }),
                  let src = request.sourceFrame(byTrackID: trackID),
                  let dest = request.renderContext.newPixelBuffer() else {
                request.finishCancelledRequest()
                return
            }

            var image = CIImage(cvPixelBuffer: src)
            image = self.applyFilters(to: image)

            self.context.render(image, to: dest)
            request.finish(withComposedVideoFrame: dest)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    // MARK: CIFilter chains

    private func applyFilters(to image: CIImage) -> CIImage {
        // Reuse the same LookPipeline logic that powers the live preview —
        // single source of truth, guaranteed parity between preview and export.
        let params = ColorCompositor.parameters
        let style = ProjectStyleSettings(
            look: params.look,
            lookIntensity: params.lookIntensity,
            captionStyle: .clean,          // captions handled separately via CALayer
            colorCorrection: params.colorCorrection
        )
        return LookPipeline.applyStyle(to: image, style: style)
    }
}

// MARK: - ColorCorrection: default check

extension ColorCorrection {
    var isNonDefault: Bool {
        brightness != 0 || contrast != 1 || saturation != 1 ||
        temperature != 6500 || highlights != 0 || shadows != 0 || vibrance != 0
    }
}
