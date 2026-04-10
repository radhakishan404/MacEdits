import AVFoundation
import Foundation
import Observation
import Speech

struct GeneratedCaption: Hashable {
    let text: String
    let startTime: Double
    let endTime: Double
}

enum CaptionEngineError: LocalizedError {
    case generationInProgress
    case speechUsageDescriptionMissing
    case speechAuthorizationDenied
    case recognizerUnavailable
    case noAudioTrack
    case noSpeechDetected
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .generationInProgress:
            return "Caption generation is already in progress."
        case .speechUsageDescriptionMissing:
            return "Speech recognition is not configured for this app build. Relaunch from the MacEdits.app test bundle."
        case .speechAuthorizationDenied:
            return "Speech recognition permission was denied."
        case .recognizerUnavailable:
            return "Speech recognition is unavailable on this Mac."
        case .noAudioTrack:
            return "The selected clip does not contain audio for captions."
        case .noSpeechDetected:
            return "No spoken words were detected in the selected clip."
        case let .transcriptionFailed(message):
            return "Caption generation failed: \(message)"
        }
    }
}

@MainActor
@Observable
final class CaptionEngine {
    private(set) var isGenerating = false
    private(set) var statusMessage = "Ready to generate captions."

    private final class AudioExportSessionHolder: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    func generateCaptions(
        for clip: TimelineClip,
        asset: ProjectAsset,
        projectURL: URL
    ) async throws -> [GeneratedCaption] {
        guard !isGenerating else {
            throw CaptionEngineError.generationInProgress
        }

        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw CaptionEngineError.speechUsageDescriptionMissing
        }

        guard await requestAuthorization() else {
            throw CaptionEngineError.speechAuthorizationDenied
        }

        guard let recognizer = resolveSpeechRecognizer() else {
            throw CaptionEngineError.recognizerUnavailable
        }

        let mediaURL = projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(asset.fileName)

        isGenerating = true
        statusMessage = "Preparing audio for captions..."
        defer {
            isGenerating = false
        }

        do {
            let transcriptionURL = try await makeTranscriptionAsset(from: mediaURL)
            statusMessage = "Transcribing voice..."
            let segments = try await transcribeSegments(at: transcriptionURL, recognizer: recognizer)

            let clipStart = clip.sourceStart
            let clipEnd = clip.sourceStart + clip.duration
            let captions = segments.compactMap { segment -> GeneratedCaption? in
                let segmentStart = segment.start
                let segmentEnd = segment.end
                guard segmentEnd > clipStart, segmentStart < clipEnd else {
                    return nil
                }

                let visibleStart = max(segmentStart, clipStart)
                let visibleEnd = min(segmentEnd, clipEnd)
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }

                return GeneratedCaption(
                    text: text,
                    startTime: clip.startTime + (visibleStart - clipStart),
                    endTime: clip.startTime + (visibleEnd - clipStart)
                )
            }

            guard !captions.isEmpty else {
                throw CaptionEngineError.noSpeechDetected
            }

            statusMessage = "Captions ready."
            return captions
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "Caption generation failed."
            throw error
        }
    }

    func generateTimingOnlyCaptions(
        for clip: TimelineClip,
        asset: ProjectAsset,
        projectURL: URL
    ) async throws -> [GeneratedCaption] {
        guard !isGenerating else {
            throw CaptionEngineError.generationInProgress
        }

        let mediaURL = projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(asset.fileName)

        isGenerating = true
        statusMessage = "Generating timing-only captions..."
        defer {
            isGenerating = false
        }

        do {
            let transcriptionURL = try await makeTranscriptionAsset(from: mediaURL)
            let segments = try Self.detectTimingSegments(
                audioURL: transcriptionURL,
                sourceStart: clip.sourceStart,
                duration: clip.duration
            )

            let captions: [GeneratedCaption]
            if segments.isEmpty {
                captions = [
                    GeneratedCaption(
                        text: "Edit caption",
                        startTime: clip.startTime,
                        endTime: clip.startTime + max(0.7, min(clip.duration, 1.8))
                    )
                ]
            } else {
                captions = segments.map { segment in
                    GeneratedCaption(
                        text: "Edit caption",
                        startTime: clip.startTime + (segment.lowerBound - clip.sourceStart),
                        endTime: clip.startTime + (segment.upperBound - clip.sourceStart)
                    )
                }
            }

            statusMessage = "Timing captions generated. Edit text manually."
            return captions
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "Timing caption generation failed."
            throw error
        }
    }

    private nonisolated func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let authStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { resolvedStatus in
                    continuation.resume(returning: resolvedStatus)
                }
            }
            return authStatus == .authorized
        default:
            return false
        }
    }

    private nonisolated func resolveSpeechRecognizer() -> SFSpeechRecognizer? {
        var localeIdentifiers: [String] = []

        localeIdentifiers.append(Locale.current.identifier)
        localeIdentifiers.append(contentsOf: Locale.preferredLanguages)
        localeIdentifiers.append("en-US")

        var seen = Set<String>()
        var firstUsable: SFSpeechRecognizer?

        for id in localeIdentifiers where !id.isEmpty {
            guard seen.insert(id).inserted else { continue }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)) else { continue }
            if recognizer.isAvailable {
                return recognizer
            }
            if firstUsable == nil {
                firstUsable = recognizer
            }
        }

        return firstUsable
    }

    private func makeTranscriptionAsset(from mediaURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: mediaURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw CaptionEngineError.noAudioTrack
        }

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macedits-caption-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: exportURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptionEngineError.transcriptionFailed("Could not create audio export session.")
        }
        let exportSessionHolder = AudioExportSessionHolder(exportSession)

        exportSession.outputURL = exportURL
        exportSession.outputFileType = .m4a

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                let exportSession = exportSessionHolder.session
                if let error = exportSession.error {
                    continuation.resume(throwing: CaptionEngineError.transcriptionFailed(error.localizedDescription))
                    return
                }

                guard exportSession.status == .completed else {
                    continuation.resume(
                        throwing: CaptionEngineError.transcriptionFailed("Audio export ended with status \(exportSession.status.rawValue).")
                    )
                    return
                }

                continuation.resume(returning: ())
            }
        }

        return exportURL
    }

    private func transcribeSegments(
        at url: URL,
        recognizer: SFSpeechRecognizer
    ) async throws -> [TranscriptionSegmentValue] {
        try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

            let lock = NSLock()
            var hasCompleted = false
            var recognitionTask: SFSpeechRecognitionTask?

            func complete(_ result: Result<[TranscriptionSegmentValue], Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasCompleted else { return }
                hasCompleted = true
                continuation.resume(with: result)
                recognitionTask?.cancel()
            }

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    complete(.failure(CaptionEngineError.transcriptionFailed(error.localizedDescription)))
                    return
                }

                guard let result, result.isFinal else { return }
                let segments = result.bestTranscription.segments.map {
                    TranscriptionSegmentValue(
                        text: $0.substring,
                        start: $0.timestamp,
                        end: $0.timestamp + $0.duration
                    )
                }
                complete(.success(segments))
            }
        }
    }

    private nonisolated static func detectTimingSegments(
        audioURL: URL,
        sourceStart: Double,
        duration: Double
    ) throws -> [ClosedRange<Double>] {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return [] }

        let clipStart = max(0, sourceStart)
        let clipDuration = max(0.05, duration)
        let clipStartFrame = AVAudioFramePosition(clipStart * sampleRate)
        let clipFrameCount = AVAudioFramePosition(clipDuration * sampleRate)
        let availableFrames = max(0, audioFile.length - clipStartFrame)
        let framesToRead = min(clipFrameCount, availableFrames)
        guard framesToRead > 0 else { return [] }

        audioFile.framePosition = clipStartFrame
        let safeFrameCount = min(framesToRead, AVAudioFramePosition(Int(UInt32.max)))
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(safeFrameCount)
            )
        else {
            return []
        }
        try audioFile.read(into: buffer, frameCount: AVAudioFrameCount(safeFrameCount))

        guard let channels = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }

        let threshold: Float = powf(10, -36.0 / 20.0)
        let windowFrames = max(256, Int(sampleRate * 0.06))
        let maxGap = 0.12
        let minSegment = 0.25

        var localSegments: [ClosedRange<Double>] = []
        var currentStart: Double?
        var currentEnd: Double = 0
        var index = 0

        while index < frameLength {
            let end = min(frameLength, index + windowFrames)
            var energySum: Float = 0
            var sampleCount = 0

            for frame in index..<end {
                var mixed: Float = 0
                for channel in 0..<channelCount {
                    mixed += channels[channel][frame]
                }
                let value = mixed / Float(channelCount)
                energySum += value * value
                sampleCount += 1
            }

            let rms = sampleCount > 0 ? sqrtf(energySum / Float(sampleCount)) : 0
            let windowStart = Double(index) / sampleRate
            let windowEnd = Double(end) / sampleRate

            if rms >= threshold {
                if let start = currentStart {
                    if windowStart - currentEnd <= maxGap {
                        currentEnd = windowEnd
                    } else {
                        localSegments.append(start...currentEnd)
                        currentStart = windowStart
                        currentEnd = windowEnd
                    }
                } else {
                    currentStart = windowStart
                    currentEnd = windowEnd
                }
            }

            index = end
        }

        if let currentStart {
            localSegments.append(currentStart...currentEnd)
        }

        return localSegments
            .compactMap { segment -> ClosedRange<Double>? in
                let lower = clipStart + max(0, segment.lowerBound)
                let upper = min(clipStart + clipDuration, clipStart + segment.upperBound)
                guard upper - lower >= minSegment else { return nil }
                return lower...upper
            }
            .sorted { $0.lowerBound < $1.lowerBound }
    }
}

private struct TranscriptionSegmentValue: Sendable {
    let text: String
    let start: Double
    let end: Double
}
