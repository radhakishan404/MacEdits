@preconcurrency import AVFoundation
import Foundation
import Observation

// MARK: - Delegate Bridge
private final class VoiceoverDelegate: NSObject, @unchecked Sendable {
    var onFinished: @Sendable (URL?, Bool) -> Void = { _, _ in }
}

extension VoiceoverDelegate: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = flag ? recorder.url : nil
        onFinished(url, flag)
    }
}

// MARK: - VoiceoverEngine (@Observable — no NSObject)
@MainActor
@Observable
final class VoiceoverEngine {
    private(set) var isRecording = false
    private(set) var recordedFileURL: URL?
    private(set) var elapsed: TimeInterval = 0
    private(set) var audioLevel: Double = 0
    private(set) var statusMessage = "Ready for voiceover."

    private var recorder: AVAudioRecorder?
    private let delegate = VoiceoverDelegate()
    private var startedAt: Date?
    private var meterTask: Task<Void, Never>?

    init() {
        delegate.onFinished = { [weak self] url, success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recorder = nil
                self.stopMeterLoop()
                self.isRecording = false
                self.audioLevel = 0
                self.recordedFileURL = url
                self.statusMessage = success ? "Voiceover captured." : "Voiceover recording failed."
            }
        }
    }

    func start() async {
        let granted = await requestPermission()
        guard granted else {
            statusMessage = "Microphone access denied."
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macedits-voiceover-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = delegate
            rec.isMeteringEnabled = true
            rec.prepareToRecord()
            rec.record()
            recorder = rec
            isRecording = true
            elapsed = 0
            audioLevel = 0
            startedAt = Date()
            statusMessage = "Recording voiceover…"
            recordedFileURL = nil
            startMeterLoop()
        } catch {
            statusMessage = "Could not start voiceover recording."
        }
    }

    func stop() {
        guard isRecording else { return }
        statusMessage = "Finishing voiceover…"
        recorder?.stop()
    }

    func clearRecordedFile() {
        recordedFileURL = nil
    }

    // MARK: - Meter loop (runs on @MainActor so direct property mutation works)
    private func startMeterLoop() {
        stopMeterLoop()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let start = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(start)
                self.recorder?.updateMeters()
                if let power = self.recorder?.averagePower(forChannel: 0) {
                    self.audioLevel = Self.normalized(power)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func stopMeterLoop() {
        meterTask?.cancel()
        meterTask = nil
        startedAt = nil
    }

    private static func normalized(_ dB: Float) -> Double {
        guard dB.isFinite else { return 0 }
        let min: Float = -50
        if dB <= min { return 0 }
        if dB >= 0 { return 1 }
        return Double((dB - min) / abs(min))
    }

    private func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
