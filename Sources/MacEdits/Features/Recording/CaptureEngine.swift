@preconcurrency import AVFoundation
import AppKit
@preconcurrency import ScreenCaptureKit
import Foundation
import Observation

// MARK: - Delegate Bridge (NSObject required for AVFoundation callbacks)
private final class CaptureFileDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    var onStarted: () -> Void = {}
    var onFinished: (URL?, Error?) -> Void = { _, _ in }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        onStarted()
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        onFinished(error == nil ? outputFileURL : nil, error)
    }
}

private final class CaptureAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onSampleBuffer: (Double) -> Void = { _ in }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let level = Self.rmsLevel(from: sampleBuffer)
        onSampleBuffer(level)
    }

    private static func rmsLevel(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return 0 }
        var data = Data(count: length)
        let ok = data.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard ok == kCMBlockBufferNoErr else { return 0 }
        let samples = data.withUnsafeBytes { $0.bindMemory(to: Int16.self) }
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        return min(sqrt(sum / Double(samples.count)) / Double(Int16.max) * 6, 1)
    }
}

struct CaptureDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum CaptureSource: String, CaseIterable, Hashable {
    case camera
    case screen
    case screenWithCamera

    var label: String {
        switch self {
        case .camera:
            return "Camera"
        case .screen:
            return "Screen"
        case .screenWithCamera:
            return "Screen + Cam"
        }
    }
}

private final class ScreenStreamOutputDelegate: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onSampleBuffer: (CMSampleBuffer) -> Void = { _ in }
    var onStopWithError: (Error) -> Void = { _ in }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        onSampleBuffer(sampleBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopWithError(error)
    }
}

private final class ScreenRecordingState: @unchecked Sendable {
    let outputURL: URL
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    var sessionStarted = false

    init(outputURL: URL, writer: AVAssetWriter, videoInput: AVAssetWriterInput) {
        self.outputURL = outputURL
        self.writer = writer
        self.videoInput = videoInput
    }
}

// MARK: - CaptureEngine (@Observable — no NSObject inheritance)
@MainActor
@Observable
final class CaptureEngine {
    // Exposed state
    private(set) var videoDevices: [CaptureDeviceOption] = []
    private(set) var audioDevices: [CaptureDeviceOption] = []
    var selectedVideoDeviceID: String = ""
    var selectedAudioDeviceID: String = ""
    var captureSource: CaptureSource = .camera
    private(set) var isConfigured = false
    private(set) var canRecord = false
    private(set) var isRecording = false
    private(set) var statusMessage = "Grant camera and microphone access to start."
    private(set) var recordedTakeURL: URL?
    private(set) var recordedCompanionTakeURL: URL?
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var audioLevel: Double = 0
    private(set) var hasMicrophonePermission = false

    // AVFoundation session (non-isolated access via sessionQueue)
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()

    // Delegate bridges (NSObject, live outside @Observable class)
    private let fileDelegate = CaptureFileDelegate()
    private let audioDelegate = CaptureAudioDelegate()

    private let sessionQueue = DispatchQueue(label: "com.macedits.capture.session", qos: .userInitiated)
    @ObservationIgnored nonisolated(unsafe) private var videoDeviceInput: AVCaptureDeviceInput?
    @ObservationIgnored nonisolated(unsafe) private var audioDeviceInput: AVCaptureDeviceInput?
    private var allVideoDevices: [AVCaptureDevice] = []
    private var allAudioDevices: [AVCaptureDevice] = []
    @ObservationIgnored private let screenWriteQueue = DispatchQueue(label: "com.macedits.capture.screenwrite", qos: .userInitiated)
    @ObservationIgnored nonisolated(unsafe) private var screenStream: SCStream?
    @ObservationIgnored nonisolated(unsafe) private var screenOutputDelegate: ScreenStreamOutputDelegate?
    @ObservationIgnored nonisolated(unsafe) private var screenRecordingState: ScreenRecordingState?

    private var recordingStartedAt: Date?
    private var durationTimer: Timer?
    private var recordingAttemptID: UUID?
    @ObservationIgnored private var isCompositeCaptureInFlight = false
    private(set) var hasScreenRecordingPermission = false
    private var hasReadyVideoInput = false
    @ObservationIgnored private var screenPermissionProbeTask: Task<Void, Never>?
    @ObservationIgnored private var screenProbeDowngradeOnFailure = false

    init() {
        wireUpDelegates()
    }

    // MARK: - Public API

    func prepare() {
        guard captureSource != .camera else {
            Task { [weak self] in
                guard let self else { return }
                self.isConfigured = false
                self.canRecord = false
                self.hasReadyVideoInput = false

                guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
                    self.statusMessage = "Camera permission key is missing in this build. Launch the app bundle via scripts/run-dev-app.sh."
                    return
                }

                let permission = await self.requestPermissions()
                self.hasMicrophonePermission = permission.audio
                guard permission.video else {
                    let status = AVCaptureDevice.authorizationStatus(for: .video)
                    if status == .notDetermined {
                        self.statusMessage = "Camera permission was not granted. Retry and allow camera access."
                    } else {
                        self.statusMessage = "Camera access is denied. Enable it in System Settings."
                    }
                    return
                }
                self.discoverDevices()
                self.configureSession()
            }
            return
        }

        guard captureSource != .screenWithCamera else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConfigured = false
                self.canRecord = false
                self.hasReadyVideoInput = false
                self.refreshScreenRecordingAvailability()
                guard self.hasScreenRecordingPermission else { return }

                guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
                    self.statusMessage = "Camera permission key is missing in this build."
                    self.canRecord = false
                    self.isConfigured = false
                    return
                }

                let permission = await self.requestPermissions()
                self.hasMicrophonePermission = permission.audio
                guard permission.video else {
                    self.statusMessage = "Camera access is required for Screen + Cam mode."
                    self.canRecord = false
                    self.isConfigured = false
                    return
                }

                self.discoverDevices()
                self.configureSession()
            }
            return
        }

        // Screen-only
        guard captureSource == .screen else {
            refreshScreenRecordingAvailability()
            return
        }
        refreshScreenRecordingAvailability()
    }

    func retryConfiguration() {
        refreshPermissionDiagnostics()

        guard captureSource != .camera else {
            prepare()
            return
        }

        if captureSource == .screenWithCamera {
            refreshScreenRecordingAvailability()
            if hasScreenRecordingPermission {
                statusMessage = "Refreshing screen + camera setup…"
                prepare()
                return
            }
        }

        let requested = CGRequestScreenCaptureAccess()
        refreshPermissionDiagnostics()
        if !hasScreenRecordingPermission {
            statusMessage = requested
                ? "Screen access was requested. If the prompt was accepted, relaunch Mac Edits and retry."
                : "Screen recording access is denied. Enable it in System Settings."
        }
    }

    func refreshPermissionDiagnostics() {
        let preflightGranted = CGPreflightScreenCaptureAccess()
        if preflightGranted {
            hasScreenRecordingPermission = true
            if captureSource == .screen || captureSource == .screenWithCamera {
                updateScreenCaptureReadiness()
            }
            screenPermissionProbeTask?.cancel()
            screenPermissionProbeTask = nil
            screenProbeDowngradeOnFailure = false
            return
        }

        if hasScreenRecordingPermission {
            // Keep last known-good state while we verify asynchronously.
            if captureSource == .screen || captureSource == .screenWithCamera {
                updateScreenCaptureReadiness()
            }
            startScreenPermissionProbe(force: true, downgradeOnFailure: true)
            return
        }

        hasScreenRecordingPermission = false
        if captureSource == .screen || captureSource == .screenWithCamera {
            updateScreenCaptureReadiness()
        }
        startScreenPermissionProbe(force: true)
    }

    func setCaptureSource(_ source: CaptureSource) {
        guard !isRecording else { return }
        guard captureSource != source else { return }
        if source == .camera {
            screenPermissionProbeTask?.cancel()
            screenPermissionProbeTask = nil
        }
        captureSource = source
        recordingAttemptID = nil
        if source == .screen || source == .screenWithCamera {
            stopSession()
        }
        prepare()
    }

    func selectVideoDevice(_ id: String) {
        guard captureSource != .screen else { return }
        selectedVideoDeviceID = id
        reconfigureInput(type: .video, deviceID: id)
    }

    func selectAudioDevice(_ id: String) {
        guard captureSource != .screen else { return }
        selectedAudioDeviceID = id
        reconfigureInput(type: .audio, deviceID: id)
    }

    func startRecording() {
        if captureSource == .screen {
            startScreenRecording()
            return
        }
        if captureSource == .screenWithCamera {
            startScreenWithCameraRecording()
            return
        }
        guard !isRecording else { return }
        guard canRecord else {
            statusMessage = "Cannot start recording. Check camera permission/device."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macedits-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        // NOTE: isRecording and timer are set in fileDelegate.onStarted 
        // so the counter only begins when AVFoundation confirms recording has actually started
        recordingDuration = 0
        statusMessage = "Starting recording…"
        let attemptID = UUID()
        recordingAttemptID = attemptID
        let out = movieOutput
        let del = fileDelegate
        sessionQueue.async {
            out.startRecording(to: url, recordingDelegate: del)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self else { return }
            guard self.recordingAttemptID == attemptID, !self.isRecording else { return }
            self.statusMessage = "Recording did not start. Check camera permission or device."
        }
    }

    func stopRecording() {
        if captureSource == .screen {
            Task { @MainActor [weak self] in
                await self?.stopScreenRecording(finalize: true)
            }
            return
        }
        if captureSource == .screenWithCamera {
            statusMessage = "Finishing take…"
            recordingAttemptID = nil
            let out = movieOutput
            sessionQueue.async {
                if out.isRecording { out.stopRecording() }
            }
            Task { @MainActor [weak self] in
                await self?.stopScreenRecording(finalize: true)
            }
            return
        }
        guard isRecording else { return }
        statusMessage = "Finishing take…"
        recordingAttemptID = nil
        stopDurationTimer()
        let out = movieOutput
        sessionQueue.async { out.stopRecording() }
    }

    func stopSession() {
        stopDurationTimer()
        recordingAttemptID = nil
        isConfigured = false
        canRecord = false
        hasReadyVideoInput = false
        screenPermissionProbeTask?.cancel()
        screenPermissionProbeTask = nil
        if captureSource == .screen || captureSource == .screenWithCamera {
            Task { @MainActor [weak self] in
                await self?.stopScreenRecording(finalize: false)
            }
        }
        let session = self.session
        let out = movieOutput
        let audio = audioDataOutput
        sessionQueue.async {
            if out.isRecording { out.stopRecording() }
            audio.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
        }
    }

    func clearRecordedTake() {
        recordedTakeURL = nil
    }

    func clearRecordedCompanionTake() {
        recordedCompanionTakeURL = nil
    }

    // MARK: - Internals

    private func wireUpDelegates() {
        fileDelegate.onStarted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isCompositeCaptureInFlight else { return }
                self.recordingAttemptID = nil
                self.isRecording = true
                self.statusMessage = "Recording…"
                self.startDurationTimer()
            }
        }

        fileDelegate.onFinished = { [weak self] url, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isCompositeCaptureInFlight {
                    if let url {
                        self.recordedCompanionTakeURL = url
                    }
                    if error != nil {
                        self.statusMessage = "Camera companion recording failed."
                    }
                    self.isCompositeCaptureInFlight = false
                    return
                }
                self.stopDurationTimer()
                self.recordingAttemptID = nil
                self.isRecording = false
                self.audioLevel = 0
                if error == nil, let url {
                    self.recordedTakeURL = url
                    self.statusMessage = "Take captured."
                } else {
                    self.statusMessage = "Recording failed."
                }
            }
        }

        audioDelegate.onSampleBuffer = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }
    }

    private func startDurationTimer() {
        stopDurationTimer()
        recordingStartedAt = Date()
        // Use a plain main-thread Timer — most reliable way to drive a UI counter
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartedAt else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
        durationTimer?.tolerance = 0.02
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func refreshScreenRecordingAvailability() {
        let hasUsage = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") != nil
        guard hasUsage else {
            hasScreenRecordingPermission = false
            screenPermissionProbeTask?.cancel()
            screenPermissionProbeTask = nil
            screenProbeDowngradeOnFailure = false
            if captureSource == .screen || captureSource == .screenWithCamera {
                statusMessage = "Screen capture permission key is missing in this build."
                canRecord = false
                isConfigured = false
            }
            return
        }

        let preflightGranted = CGPreflightScreenCaptureAccess()
        if preflightGranted {
            hasScreenRecordingPermission = true
            updateScreenCaptureReadiness()
            screenPermissionProbeTask?.cancel()
            screenPermissionProbeTask = nil
            screenProbeDowngradeOnFailure = false
            return
        }

        if hasScreenRecordingPermission {
            // Keep mode responsive if preflight is stale; verify in background.
            updateScreenCaptureReadiness()
            startScreenPermissionProbe(force: true, downgradeOnFailure: true)
            return
        }

        hasScreenRecordingPermission = false
        updateScreenCaptureReadiness()
        startScreenPermissionProbe()
    }

    private func updateScreenCaptureReadiness() {
        switch captureSource {
        case .screen:
            canRecord = hasScreenRecordingPermission
            isConfigured = hasScreenRecordingPermission
            statusMessage = hasScreenRecordingPermission
                ? "Ready to record screen."
                : "Screen recording access is denied. Enable it in System Settings."
        case .screenWithCamera:
            let ready = hasScreenRecordingPermission && hasReadyVideoInput
            canRecord = ready
            isConfigured = ready
            if !hasScreenRecordingPermission {
                statusMessage = "Screen recording access is denied. Enable it in System Settings."
            } else if !hasReadyVideoInput {
                statusMessage = "Camera is not ready for Screen + Cam mode."
            } else {
                statusMessage = "Ready to record screen + camera."
            }
        case .camera:
            break
        }
    }

    private func startScreenPermissionProbe(force: Bool = false, downgradeOnFailure: Bool = false) {
        if !force {
            guard captureSource == .screen || captureSource == .screenWithCamera else { return }
        }
        if downgradeOnFailure {
            screenProbeDowngradeOnFailure = true
        }
        guard screenPermissionProbeTask == nil else { return }

        screenPermissionProbeTask = Task { [weak self] in
            let granted = await Self.probeScreenPermissionViaShareableContent()
            await MainActor.run {
                guard let self else { return }
                self.screenPermissionProbeTask = nil
                if granted {
                    self.hasScreenRecordingPermission = true
                    self.screenProbeDowngradeOnFailure = false

                    if self.captureSource == .screenWithCamera, !self.hasReadyVideoInput {
                        self.prepare()
                    } else if self.captureSource == .screen || self.captureSource == .screenWithCamera {
                        self.updateScreenCaptureReadiness()
                    }
                    return
                }

                if self.screenProbeDowngradeOnFailure {
                    self.screenProbeDowngradeOnFailure = false
                    self.hasScreenRecordingPermission = false
                    if self.captureSource == .screen || self.captureSource == .screenWithCamera {
                        self.updateScreenCaptureReadiness()
                    }
                }
            }
        }
    }

    private nonisolated static func probeScreenPermissionViaShareableContent() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }

    private func startScreenRecording() {
        guard !isRecording else { return }
        guard canRecord else {
            refreshScreenRecordingAvailability()
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macedits-screen-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        recordingDuration = 0
        statusMessage = "Starting screen recording…"

        let attemptID = UUID()
        recordingAttemptID = attemptID
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.configureAndStartScreenStream(outputURL: outputURL)
                self.recordingAttemptID = nil
                self.isRecording = true
                self.statusMessage = "Recording…"
                self.startDurationTimer()
            } catch {
                self.recordingAttemptID = nil
                self.isRecording = false
                self.stopDurationTimer()
                self.statusMessage = "Screen recording failed: \(error.localizedDescription)"
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            guard let self else { return }
            guard self.recordingAttemptID == attemptID, !self.isRecording else { return }
            self.statusMessage = "Screen recording did not start. Check screen recording permission."
        }
    }

    private func startScreenWithCameraRecording() {
        guard !isRecording else { return }
        guard canRecord else {
            prepare()
            return
        }
        guard hasReadyVideoInput else {
            statusMessage = "Camera is not ready for Screen + Cam mode."
            prepare()
            return
        }

        let screenOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macedits-screen-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let cameraOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macedits-camera-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        recordedCompanionTakeURL = nil
        recordingDuration = 0
        statusMessage = "Starting screen + camera recording…"

        isCompositeCaptureInFlight = true
        let out = movieOutput
        let del = fileDelegate
        sessionQueue.async {
            out.startRecording(to: cameraOutputURL, recordingDelegate: del)
        }

        let attemptID = UUID()
        recordingAttemptID = attemptID
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.configureAndStartScreenStream(outputURL: screenOutputURL)
                self.recordingAttemptID = nil
                self.isRecording = true
                self.statusMessage = "Recording screen + camera…"
                self.startDurationTimer()
            } catch {
                self.recordingAttemptID = nil
                self.isRecording = false
                self.stopDurationTimer()
                self.isCompositeCaptureInFlight = false
                self.statusMessage = "Screen + camera recording failed: \(error.localizedDescription)"
                self.sessionQueue.async {
                    if out.isRecording {
                        out.stopRecording()
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
            guard let self else { return }
            guard self.recordingAttemptID == attemptID, !self.isRecording else { return }
            self.statusMessage = "Screen + camera recording did not start."
        }
    }

    private func configureAndStartScreenStream(outputURL: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = preferredDisplay(from: content.displays) else {
            throw NSError(domain: "MacEdits.ScreenRecording", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No display available for capture."
            ])
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: display.width,
            AVVideoHeightKey: display.height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "MacEdits.ScreenRecording", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Unable to create screen recording writer."
            ])
        }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "MacEdits.ScreenRecording", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Screen writer failed to start."
            ])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = display.width
        streamConfig.height = display.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        streamConfig.queueDepth = 5
        streamConfig.showsCursor = true
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA

        let outputDelegate = ScreenStreamOutputDelegate()
        outputDelegate.onSampleBuffer = { [weak self] sampleBuffer in
            self?.handleScreenSampleBuffer(sampleBuffer)
        }
        outputDelegate.onStopWithError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusMessage = "Screen recording stopped: \(error.localizedDescription)"
                await self.stopScreenRecording(finalize: false)
            }
        }

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: outputDelegate)
        try stream.addStreamOutput(outputDelegate, type: .screen, sampleHandlerQueue: screenWriteQueue)
        screenRecordingState = ScreenRecordingState(outputURL: outputURL, writer: writer, videoInput: videoInput)
        screenOutputDelegate = outputDelegate
        screenStream = stream

        do {
            try await startScreenCapture(stream, timeoutSeconds: 5)
        } catch {
            screenRecordingState = nil
            screenOutputDelegate = nil
            screenStream = nil
            try? await stream.stopCapture()
            throw error
        }
    }

    nonisolated private func handleScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let state = screenRecordingState else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !state.sessionStarted {
            state.writer.startSession(atSourceTime: pts)
            state.sessionStarted = true
        }

        guard state.videoInput.isReadyForMoreMediaData else { return }
        _ = state.videoInput.append(sampleBuffer)
    }

    private func stopScreenRecording(finalize: Bool) async {
        let stream = screenStream
        let state = screenRecordingState
        let wasRecording = isRecording
        screenStream = nil
        screenOutputDelegate = nil
        screenRecordingState = nil
        recordingAttemptID = nil

        if let stream {
            try? await stream.stopCapture()
        }

        isRecording = false
        stopDurationTimer()
        audioLevel = 0

        guard let state else {
            if !finalize, wasRecording {
                statusMessage = "Screen recording stopped."
            }
            return
        }

        state.videoInput.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.writer.finishWriting {
                continuation.resume()
            }
        }

        if finalize {
            if state.writer.status == .completed {
                recordedTakeURL = state.outputURL
                statusMessage = "Take captured."
            } else {
                statusMessage = "Recording failed."
            }
        } else if wasRecording {
            statusMessage = "Screen recording stopped."
        }
    }

    private func preferredDisplay(from displays: [SCDisplay]) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }
        if let screen = NSScreen.main,
           let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let activeDisplayID = CGDirectDisplayID(screenNumber.uint32Value)
            if let match = displays.first(where: { $0.displayID == activeDisplayID }) {
                return match
            }
        }
        return displays.first
    }

    private func startScreenCapture(_ stream: SCStream, timeoutSeconds: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await stream.startCapture()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw NSError(domain: "MacEdits.ScreenRecording", code: -4, userInfo: [
                    NSLocalizedDescriptionKey: "Timed out while starting screen capture."
                ])
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NSError(domain: "MacEdits.ScreenRecording", code: -5, userInfo: [
                    NSLocalizedDescriptionKey: "Screen capture failed to start."
                ])
            }
            _ = result
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartedAt = nil
    }

    private func discoverDevices() {
        let vDisc = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let aDisc = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        allVideoDevices = vDisc.devices
        allAudioDevices = aDisc.devices
        videoDevices = allVideoDevices.map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
        audioDevices = allAudioDevices.map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
        if selectedVideoDeviceID.isEmpty { selectedVideoDeviceID = videoDevices.first?.id ?? "" }
        if selectedAudioDeviceID.isEmpty { selectedAudioDeviceID = audioDevices.first?.id ?? "" }
    }

    private func configureSession() {
        let vDevice = resolvedDevice(.video, id: selectedVideoDeviceID)
        let aDevice = hasMicrophonePermission ? resolvedDevice(.audio, id: selectedAudioDeviceID) : nil
        let hasMicrophonePermission = self.hasMicrophonePermission
        let session = self.session
        let movieOutput = self.movieOutput
        let audioDataOutput = self.audioDataOutput
        let audioDelegate = self.audioDelegate

        sessionQueue.async {
            session.beginConfiguration()
            session.sessionPreset = .high
            let hasVideoInput = self.addInput(device: vDevice, type: .video, to: session)
            let hasAudioInput = self.addInput(device: aDevice, type: .audio, to: session)
            if session.canAddOutput(movieOutput), !session.outputs.contains(movieOutput) {
                session.addOutput(movieOutput)
            }
            if hasAudioInput, session.canAddOutput(audioDataOutput), !session.outputs.contains(audioDataOutput) {
                audioDataOutput.setSampleBufferDelegate(
                    audioDelegate,
                    queue: DispatchQueue(label: "com.macedits.capture.meter", qos: .userInteractive)
                )
                session.addOutput(audioDataOutput)
            } else if !hasAudioInput, session.outputs.contains(audioDataOutput) {
                audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(audioDataOutput)
            }
            session.commitConfiguration()
            if hasVideoInput, !session.isRunning { session.startRunning() }
            Task { @MainActor [weak self] in
                self?.hasReadyVideoInput = hasVideoInput
                if self?.captureSource == .screenWithCamera {
                    let ready = hasVideoInput && (self?.hasScreenRecordingPermission ?? false)
                    self?.canRecord = ready
                    self?.isConfigured = ready
                    if !hasVideoInput {
                        self?.statusMessage = "No camera detected. Screen + Cam needs a camera."
                    } else if !(self?.hasScreenRecordingPermission ?? false) {
                        self?.statusMessage = "Camera ready. Enable Screen Recording permission."
                    } else if hasMicrophonePermission, !hasAudioInput {
                        self?.statusMessage = "Ready to record screen + camera. Microphone not detected."
                    } else if !hasMicrophonePermission {
                        self?.statusMessage = "Ready to record screen + camera. Microphone permission denied."
                    } else {
                        self?.statusMessage = "Ready to record screen + camera."
                    }
                } else {
                    self?.canRecord = hasVideoInput
                    self?.isConfigured = hasVideoInput
                    if !hasVideoInput {
                        self?.statusMessage = "No camera detected. Connect one and retry."
                    } else if hasMicrophonePermission, !hasAudioInput {
                        self?.statusMessage = "Camera ready. Microphone not detected; recording video only."
                    } else if !hasMicrophonePermission {
                        self?.statusMessage = "Camera ready. Microphone permission denied; recording video only."
                    } else {
                        self?.statusMessage = "Ready to record."
                    }
                }
            }
        }
    }

    private func reconfigureInput(type: AVMediaType, deviceID: String) {
        if type == .audio, !hasMicrophonePermission {
            statusMessage = "Microphone permission denied. Enable it in System Settings."
            return
        }
        let device = resolvedDevice(type, id: deviceID)
        let session = self.session
        sessionQueue.async {
            session.beginConfiguration()
            let inputAttached = self.addInput(device: device, type: type, to: session)
            session.commitConfiguration()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == .video {
                    self.hasReadyVideoInput = inputAttached
                    if self.captureSource == .screenWithCamera {
                        let ready = inputAttached && self.hasScreenRecordingPermission
                        self.canRecord = ready
                        self.isConfigured = ready
                        if !inputAttached {
                            self.statusMessage = "Unable to use selected camera for Screen + Cam."
                        } else if !self.hasScreenRecordingPermission {
                            self.statusMessage = "Camera ready. Enable Screen Recording permission."
                        } else {
                            self.statusMessage = "Ready to record screen + camera."
                        }
                    } else if self.statusMessage.contains("Unable to use selected camera")
                        || self.statusMessage.contains("No camera detected") {
                        self.canRecord = inputAttached
                        self.isConfigured = inputAttached
                        self.statusMessage = "Ready to record."
                    } else {
                        self.canRecord = inputAttached
                        self.isConfigured = inputAttached
                        if !inputAttached {
                            self.statusMessage = "Unable to use selected camera."
                        }
                    }
                }
            }
        }
    }

    nonisolated private func addInput(device: AVCaptureDevice?, type: AVMediaType, to session: AVCaptureSession) -> Bool {
        switch type {
        case .video:
            if let existing = videoDeviceInput {
                session.removeInput(existing)
                videoDeviceInput = nil
            }
            guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                return false
            }
            session.addInput(input)
            videoDeviceInput = input
            return true
        case .audio:
            if let existing = audioDeviceInput {
                session.removeInput(existing)
                audioDeviceInput = nil
            }
            guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                return false
            }
            session.addInput(input)
            audioDeviceInput = input
            return true
        default:
            return false
        }
    }

    private func resolvedDevice(_ type: AVMediaType, id: String) -> AVCaptureDevice? {
        let pool = type == .video ? allVideoDevices : allAudioDevices
        return pool.first(where: { $0.uniqueID == id }) ?? pool.first
    }

    private func requestPermissions() async -> (video: Bool, audio: Bool) {
        let video = await requestAccess(.video)
        let audio = await requestAccess(.audio)
        return (video, audio)
    }

    private func requestAccess(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
}
