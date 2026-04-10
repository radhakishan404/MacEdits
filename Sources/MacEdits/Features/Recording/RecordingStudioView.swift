import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import Speech

struct RecordingStudioView: View {
    @Environment(AppModel.self) private var appModel
    @State private var captureEngine = CaptureEngine()
    @State private var aspectRatio: AspectRatioPreset = .vertical9x16
    @State private var sidebarTab: RecordingSidebarTab = .setup
    @State private var teleprompterEnabled = false
    @State private var transcriptText = ""
    @State private var teleprompterSpeed: Double = 34
    @State private var teleprompterFontSize: Double = 28
    @State private var teleprompterMirrored = false
    @State private var teleprompterPausedAt: Double?
    @State private var teleprompterPausedAccumulated: Double = 0
    @State private var countdownSetting: CountdownOption = .three
    @State private var countdownActive: Int? = nil
    @State private var recordButtonScale: CGFloat = 1.0
    @State private var recordingPulse = false
    @State private var recentTakeAssetIDs: [UUID] = []
    @State private var selectedTakeAssetID: UUID?
    @State private var captureSource: CaptureSource = .camera
    @State private var permissionRefreshToken = 0
    @State private var screenPreviewImage: NSImage?
    @State private var screenPreviewTimer: Timer?

    let workspace: ProjectWorkspace

    private var liveWorkspace: ProjectWorkspace {
        appModel.currentWorkspace ?? workspace
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                cameraArea
                sidebar
            }
        }
        .frame(minWidth: 1024, minHeight: 700, alignment: .topLeading)
        .background(AppTheme.windowBackground.ignoresSafeArea())
        .onAppear {
            captureEngine.setCaptureSource(captureSource)
            captureEngine.prepare()
            captureEngine.refreshPermissionDiagnostics()
            seedRecentTakesIfNeeded()
            startScreenPreviewLoopIfNeeded()
        }
        .onDisappear {
            stopScreenPreviewLoop()
            captureEngine.stopSession()
        }
        .onChange(of: captureEngine.recordedTakeURL) { _, newValue in
            guard let newValue else { return }
            if let assetID = appModel.attachRecordedAsset(from: newValue) {
                registerRecentTake(assetID, makeSelected: true)
            }
            captureEngine.clearRecordedTake()
        }
        .onChange(of: captureEngine.recordedCompanionTakeURL) { _, newValue in
            guard let newValue else { return }
            _ = appModel.attachCompanionRecordedAsset(from: newValue)
            captureEngine.clearRecordedCompanionTake()
        }
        .onChange(of: appModel.currentWorkspace) { _, _ in
            syncTakeSelection()
        }
        .onChange(of: captureEngine.isRecording) { _, isRecording in
            if isRecording {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    recordingPulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    recordingPulse = false
                }
                teleprompterPausedAt = nil
                teleprompterPausedAccumulated = 0
            }
        }
        .onChange(of: captureSource) { _, newValue in
            captureEngine.setCaptureSource(newValue)
            startScreenPreviewLoopIfNeeded()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { appModel.returnHome() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close recording studio")

            VStack(alignment: .leading, spacing: 1) {
                Text(liveWorkspace.summary.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Recording Studio")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.tertiaryText)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(CaptureSource.allCases, id: \.self) { source in
                    Button {
                        captureSource = source
                    } label: {
                        Text(source.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(captureSource == source ? .white : AppTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(captureSource == source ? AppTheme.accent.opacity(0.24) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Switch recording source to \(source.label)")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.05))
            .clipShape(Capsule())

            Spacer()

            // Aspect ratio pills
            HStack(spacing: 6) {
                ForEach(AspectRatioPreset.allCases, id: \.self) { preset in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            aspectRatio = preset
                        }
                    } label: {
                        Text(preset.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(aspectRatio == preset ? .white : AppTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(aspectRatio == preset ? Color.white.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Set aspect ratio to \(preset.label)")
                }
            }

            Spacer()

            // Timer
            HStack(spacing: 6) {
                Circle()
                    .fill(captureEngine.isRecording ? AppTheme.recordAccent : Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(recordingDurationLabel)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())

            Button {
                appModel.moveToEditor()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                    Text("Editor")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open editor")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.panelBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.hairline).frame(height: 1)
        }
    }

    // MARK: - Camera Area (full-bleed)

    private var cameraArea: some View {
        ZStack {
            if captureSource == .camera {
                // Full-bleed camera
                CameraPreviewView(session: captureEngine.session, videoGravity: .resizeAspectFill)
                    .clipShape(RoundedRectangle(cornerRadius: 0))
            } else if captureSource == .screenWithCamera {
                screenPreviewSurface(showCameraInset: true)
            } else {
                screenPreviewSurface(showCameraInset: false)
            }

            // Dark vignette at edges
            LinearGradient(colors: [Color.black.opacity(0.5), .clear, .clear, .clear, Color.black.opacity(0.4)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            // Aspect ratio guide overlay
            GeometryReader { geo in
                let guide = guideRect(in: geo.size)
                ZStack {
                    // Dim everything outside the guide
                    Color.black.opacity(0.45)
                        .reverseMask {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .frame(width: guide.width, height: guide.height)
                        }

                    // Guide border
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            captureEngine.isRecording ? AppTheme.recordAccent.opacity(0.7) : Color.white.opacity(0.25),
                            lineWidth: 1.5
                        )
                        .frame(width: guide.width, height: guide.height)
                }
            }

            // Top-left: live indicator
            VStack {
                HStack {
                    liveIndicator
                    Spacer()
                    // Audio level meter
                    audioLevelBar
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                captureStatusPanel
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                Spacer()
            }

            // Bottom: Record button + countdown selector
            VStack {
                Spacer()
                VStack(spacing: 14) {
                    // Countdown overlay
                    if let count = countdownActive {
                        Text("\(count)")
                            .font(.system(size: 140, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.5), radius: 20)
                            .transition(.scale.combined(with: .opacity))
                    }

                    if !recordingTakes.isEmpty {
                        takeStrip
                    }

                    recordButton

                    // Countdown selector
                    HStack(spacing: 8) {
                        ForEach(CountdownOption.allCases, id: \.self) { option in
                            Button {
                                countdownSetting = option
                            } label: {
                                Text(option.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(countdownSetting == option ? .white : AppTheme.secondaryText)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(countdownSetting == option ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Set recording countdown to \(option.label)")
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func screenPreviewSurface(showCameraInset: Bool) -> some View {
        ZStack {
            if let screenPreviewImage {
                Image(nsImage: screenPreviewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.05, green: 0.06, blue: 0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            Rectangle()
                .fill(Color.black.opacity(0.36))
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(AppTheme.accent)

                Text(captureEngine.isRecording ? "Recording your screen…" : "Screen Recording Preview")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Text(captureEngine.canRecord
                     ? (captureSource == .screenWithCamera
                        ? "Press record to capture your active display and camera companion."
                        : "Press record to capture the active display.")
                     : "Grant Screen Recording permission to start.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)

                if !captureEngine.canRecord {
                    Button("Open Screen Recording Settings") {
                        openPrivacySettings(for: .screenRecording)
                    }
                    .buttonStyle(.borderedProminent)
                } else if screenPreviewImage == nil {
                    Text("Waiting for display preview…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.tertiaryText)
                }
            }
            .padding(24)
            .frame(maxWidth: 460)
            .background(Color.black.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )

            if showCameraInset {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Camera Companion")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                            CameraPreviewView(session: captureEngine.session, videoGravity: .resizeAspectFill)
                                .frame(width: 180, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                                )
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.38))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(20)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 0))
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button {
            handleRecordTap()
        } label: {
            ZStack {
                // Outer pulsing ring (when recording)
                if captureEngine.isRecording {
                    Circle()
                        .stroke(AppTheme.recordAccent.opacity(0.4), lineWidth: 3)
                        .frame(width: 96, height: 96)
                        .scaleEffect(recordingPulse ? 1.15 : 1.0)
                }

                // Main circle
                Circle()
                    .fill(Color.white)
                    .frame(width: 80, height: 80)

                // Inner shape
                if captureEngine.isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppTheme.recordAccent)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(AppTheme.recordAccent)
                        .frame(width: 64, height: 64)
                }
            }
            .scaleEffect(recordButtonScale)
        }
        .buttonStyle(.plain)
        .disabled(!captureEngine.canRecord && !captureEngine.isRecording)
        .opacity((!captureEngine.canRecord && !captureEngine.isRecording) ? 0.45 : 1)
        .accessibilityLabel(captureEngine.isRecording ? "Stop recording" : "Start recording")
        .onHover { hovering in
            withAnimation(.spring(response: 0.2)) {
                recordButtonScale = hovering ? 1.06 : 1.0
            }
        }
    }

    // MARK: - Live Indicator

    private var liveIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(captureEngine.isRecording ? AppTheme.recordAccent : AppTheme.openAccent)
                .frame(width: 9, height: 9)
                .opacity(captureEngine.isRecording && recordingPulse ? 0.5 : 1)
            Text(captureEngine.isRecording ? "REC" : "PREVIEW")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .tracking(0.8)
            if captureEngine.isRecording {
                Text(recordingDurationLabel)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial.opacity(0.7))
        .clipShape(Capsule())
    }

    private var captureStatusPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: captureEngine.canRecord ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(captureEngine.canRecord ? AppTheme.openAccent : AppTheme.importAccent)
            Text(captureEngine.statusMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
            if !captureEngine.canRecord {
                Button("Retry") {
                    captureEngine.retryConfiguration()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Retry recording setup")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Audio Level Bar

    private var audioLevelBar: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(barColor(for: index))
                    .frame(width: 4, height: CGFloat(6 + index * 2))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Sidebar (tabbed)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tab bar
            HStack(spacing: 2) {
                ForEach(RecordingSidebarTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            sidebarTab = tab
                        }
                    } label: {
                        Text(tab.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(sidebarTab == tab ? .white : AppTheme.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(sidebarTab == tab ? Color.white.opacity(0.1) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Divider().overlay(AppTheme.hairline).padding(.top, 10)

            // Tab content
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    switch sidebarTab {
                    case .setup:
                        setupTab
                    case .script:
                        scriptTab
                    case .frame:
                        frameTab
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 300)
        .background(AppTheme.panelBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(AppTheme.hairline).frame(width: 1)
        }
    }

    // MARK: - Setup Tab

    private var setupTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlCard(title: "Capture Source") {
                HStack(spacing: 8) {
                    ForEach(CaptureSource.allCases, id: \.self) { source in
                        Button {
                            captureSource = source
                        } label: {
                            Text(source.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(captureSource == source ? .white : AppTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(captureSource == source ? AppTheme.accent.opacity(0.2) : Color.white.opacity(0.04))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if captureSource != .screen {
                ControlCard(title: "Camera") {
                    CompactPickerRow(
                        label: "Device",
                        selection: $captureEngine.selectedVideoDeviceID,
                        options: captureEngine.videoDevices
                    ) { option in
                        captureEngine.selectVideoDevice(option.id)
                    }
                }

                ControlCard(title: "Microphone") {
                    CompactPickerRow(
                        label: "Device",
                        selection: $captureEngine.selectedAudioDeviceID,
                        options: captureEngine.audioDevices
                    ) { option in
                        captureEngine.selectAudioDevice(option.id)
                    }
                }
            }
            if captureSource != .camera {
                ControlCard(title: "Screen Setup") {
                    Text("Mac Edits captures the active display when you press Record.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Enable Screen Recording permission, then relaunch the app if macOS asks for it.")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ControlCard(title: "Info") {
                ControlRow(label: "Assets", value: "\(liveWorkspace.file.assets.count)")
                ControlRow(label: "Format", value: aspectRatio.label)
                ControlRow(label: "Source", value: captureSource.label)
                ControlRow(label: "Project", value: liveWorkspace.summary.projectURL.lastPathComponent)
            }

            ControlCard(title: "Permissions") {
                VStack(spacing: 8) {
                    ForEach(permissionDiagnosticsItems) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(item.granted ? AppTheme.openAccent : AppTheme.importAccent)
                            Text(item.kind.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Text(item.statusLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(item.granted ? AppTheme.secondaryText : AppTheme.importAccent)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Retry Checks") {
                        captureEngine.retryConfiguration()
                        permissionRefreshToken &+= 1
                    }
                    .buttonStyle(.bordered)
                }

                let blocked = permissionDiagnosticsItems.filter { !$0.granted }
                if !blocked.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(blocked) { item in
                            HStack(spacing: 8) {
                                if item.kind == .speech {
                                    Button("Request Speech Access") {
                                        requestSpeechAccess()
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else if item.kind == .screenRecording {
                                    Button("Request Screen Access") {
                                        requestScreenRecordingAccess()
                                    }
                                    .buttonStyle(.borderedProminent)
                                }

                                Button("Open \(item.kind.label) Settings") {
                                    openPrivacySettings(for: item.kind)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Script Tab

    private var scriptTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlCard(title: "Teleprompter") {
                Toggle(isOn: $teleprompterEnabled) {
                    Text("Show on camera")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                }
                .toggleStyle(.switch)

                if teleprompterEnabled {
                    Toggle(isOn: $teleprompterMirrored) {
                        Text("Mirror text")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                    }
                    .toggleStyle(.switch)

                    CompactSlider(label: "Speed", value: $teleprompterSpeed, range: 10...90, unit: "pt/s", tint: AppTheme.accent)
                    CompactSlider(label: "Text size", value: $teleprompterFontSize, range: 18...42, unit: "pt", tint: AppTheme.importAccent)
                }
            }

            ControlCard(title: "Script") {
                ScrollablePromptEditor(text: $transcriptText)
                    .frame(height: 200)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("Paste or type your script. It scrolls during recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.tertiaryText)
            }
        }
    }

    // MARK: - Frame Tab

    private var frameTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            ControlCard(title: "Aspect Ratio") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(AspectRatioPreset.allCases, id: \.self) { preset in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                aspectRatio = preset
                            }
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(aspectRatio == preset ? AppTheme.accent : Color.white.opacity(0.15), lineWidth: 1.5)
                                    .aspectRatio(preset.ratio, contentMode: .fit)
                                    .frame(height: 40)

                                Text(preset.label)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(aspectRatio == preset ? .white : AppTheme.secondaryText)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(aspectRatio == preset ? AppTheme.accent.opacity(0.15) : Color.white.opacity(0.03))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ControlCard(title: "Countdown") {
                HStack(spacing: 6) {
                    ForEach(CountdownOption.allCases, id: \.self) { option in
                        Button {
                            countdownSetting = option
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(countdownSetting == option ? .white : AppTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(countdownSetting == option ? AppTheme.accent.opacity(0.2) : Color.white.opacity(0.04))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func handleRecordTap() {
        guard captureEngine.canRecord || captureEngine.isRecording else {
            captureEngine.retryConfiguration()
            return
        }
        if captureEngine.isRecording {
            captureEngine.stopRecording()
        } else if countdownSetting == .off {
            captureEngine.startRecording()
        } else {
            startCountdown()
        }
    }

    private func startCountdown() {
        let total = countdownSetting.seconds
        withAnimation(.spring(response: 0.3)) {
            countdownActive = total
        }
        for tick in 1...total {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(tick)) { [self] in
                let value = total - tick
                if value > 0 {
                    withAnimation(.spring(response: 0.3)) {
                        countdownActive = value
                    }
                } else {
                    withAnimation(.spring(response: 0.2)) {
                        countdownActive = nil
                    }
                    captureEngine.startRecording()
                }
            }
        }
    }

    private func guideRect(in size: CGSize) -> CGSize {
        let r = aspectRatio.ratio
        let maxW = size.width * 0.88
        let maxH = size.height * 0.88
        var w = maxW
        var h = w / r
        if h > maxH {
            h = maxH
            w = h * r
        }
        return CGSize(width: w, height: h)
    }

    private var recordingDurationLabel: String {
        let totalSeconds = Int(captureEngine.recordingDuration.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Double(index + 1) / 10.0
        guard captureEngine.audioLevel >= threshold else {
            return Color.white.opacity(0.1)
        }
        if threshold < 0.5 { return AppTheme.openAccent }
        if threshold < 0.8 { return AppTheme.importAccent }
        return AppTheme.recordAccent
    }

    private var permissionDiagnosticsItems: [PermissionDiagnosticsItem] {
        _ = permissionRefreshToken
        let hasCameraUsage = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
        let hasMicrophoneUsage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
        let hasSpeechUsage = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
        let hasScreenUsage = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") != nil

        let cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let speechGranted = speechStatus == .authorized
        let screenGranted = captureEngine.hasScreenRecordingPermission || CGPreflightScreenCaptureAccess()

        return [
            PermissionDiagnosticsItem(
                kind: .camera,
                granted: hasCameraUsage && cameraGranted,
                statusLabel: hasCameraUsage ? permissionStatusLabel(for: .video) : "Build Missing"
            ),
            PermissionDiagnosticsItem(
                kind: .microphone,
                granted: hasMicrophoneUsage && microphoneGranted,
                statusLabel: hasMicrophoneUsage ? permissionStatusLabel(for: .audio) : "Build Missing"
            ),
            PermissionDiagnosticsItem(
                kind: .speech,
                granted: hasSpeechUsage && speechGranted,
                statusLabel: hasSpeechUsage ? speechStatusLabel(speechStatus) : "Build Missing"
            ),
            PermissionDiagnosticsItem(
                kind: .screenRecording,
                granted: hasScreenUsage && screenGranted,
                statusLabel: hasScreenUsage ? (screenGranted ? "Allowed" : "Not Allowed") : "Build Missing"
            )
        ]
    }

    private func permissionStatusLabel(for mediaType: AVMediaType) -> String {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Asked"
        @unknown default:
            return "Unknown"
        }
    }

    private func speechStatusLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Asked"
        @unknown default:
            return "Unknown"
        }
    }

    private func openPrivacySettings(for kind: PrivacyPermissionKind) {
        let urlString: String
        switch kind {
        case .camera:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speech:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestSpeechAccess() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .denied, .restricted:
            permissionRefreshToken &+= 1
        case .notDetermined:
            Task {
                _ = await requestSpeechAuthorizationStatus()
                await MainActor.run {
                    permissionRefreshToken &+= 1
                }
            }
        @unknown default:
            permissionRefreshToken &+= 1
        }
    }

    private nonisolated func requestSpeechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestScreenRecordingAccess() {
        _ = CGRequestScreenCaptureAccess()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            permissionRefreshToken &+= 1
            captureEngine.retryConfiguration()
            refreshScreenPreviewFrame()
        }
    }

    private func startScreenPreviewLoopIfNeeded() {
        stopScreenPreviewLoop()
        guard captureSource != .camera else {
            screenPreviewImage = nil
            return
        }

        refreshScreenPreviewFrame()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in
                refreshScreenPreviewFrame()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        screenPreviewTimer = timer
    }

    private func stopScreenPreviewLoop() {
        screenPreviewTimer?.invalidate()
        screenPreviewTimer = nil
    }

    private func refreshScreenPreviewFrame() {
        guard captureSource != .camera else {
            screenPreviewImage = nil
            return
        }
        let hasAccess = captureEngine.hasScreenRecordingPermission || CGPreflightScreenCaptureAccess()
        guard hasAccess else {
            screenPreviewImage = nil
            captureEngine.refreshPermissionDiagnostics()
            return
        }
        guard
            let screen = NSScreen.main,
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let cgImage = CGDisplayCreateImage(displayID) else { return }
        screenPreviewImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private var recordingTakes: [ProjectAsset] {
        recentTakeAssetIDs.compactMap { id in
            liveWorkspace.file.assets.first(where: { $0.id == id })
        }
    }

    private func seedRecentTakesIfNeeded() {
        guard recentTakeAssetIDs.isEmpty else { return }
        let timelineVideoAssets = liveWorkspace.file.timelineClips
            .filter { $0.lane == .video }
            .sorted { $0.startTime > $1.startTime }
            .map(\.assetID)
        if timelineVideoAssets.isEmpty {
            selectedTakeAssetID = nil
        } else {
            var seen: Set<UUID> = []
            let deduped = timelineVideoAssets.filter { seen.insert($0).inserted }
            recentTakeAssetIDs = Array(deduped.prefix(8))
            selectedTakeAssetID = recentTakeAssetIDs.first
        }
    }

    private func registerRecentTake(_ assetID: UUID, makeSelected: Bool) {
        recentTakeAssetIDs.removeAll { $0 == assetID }
        recentTakeAssetIDs.insert(assetID, at: 0)
        recentTakeAssetIDs = Array(recentTakeAssetIDs.prefix(12))
        if makeSelected || selectedTakeAssetID == nil {
            selectedTakeAssetID = assetID
        }
    }

    private func syncTakeSelection() {
        let validIDs = Set(liveWorkspace.file.assets.map(\.id))
        recentTakeAssetIDs = recentTakeAssetIDs.filter { validIDs.contains($0) }
        if let selectedTakeAssetID, !validIDs.contains(selectedTakeAssetID) {
            self.selectedTakeAssetID = recentTakeAssetIDs.first
        } else if selectedTakeAssetID == nil {
            selectedTakeAssetID = recentTakeAssetIDs.first
        }
    }

    private func takeDurationLabel(for assetID: UUID) -> String {
        let timelineDuration = liveWorkspace.file.timelineClips
            .filter { $0.assetID == assetID && $0.lane == .video }
            .map(\.duration)
            .max() ?? 0
        let totalSeconds = Int(timelineDuration.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func openSelectedTakeInEditor() {
        let targetAssetID = selectedTakeAssetID ?? recordingTakes.first?.id
        appModel.moveToEditor(selectingAssetID: targetAssetID)
    }

    private var takeStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Takes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(recordingTakes.count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recordingTakes) { asset in
                        Button {
                            selectedTakeAssetID = asset.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ThumbnailStripView(
                                    asset: asset,
                                    projectURL: liveWorkspace.summary.projectURL,
                                    clipDuration: max(
                                        1,
                                        liveWorkspace.file.timelineClips
                                            .first(where: { $0.assetID == asset.id })?.duration ?? 1
                                    ),
                                    lane: .video
                                )
                                .frame(width: 120, height: 68)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                }

                                Text(asset.originalName)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(takeDurationLabel(for: asset.id))
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            .frame(width: 124, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selectedTakeAssetID == asset.id ? AppTheme.accent.opacity(0.25) : Color.white.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                Button {
                    if !captureEngine.isRecording {
                        handleRecordTap()
                    }
                } label: {
                    Label("Retake", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
                .disabled(captureEngine.isRecording)

                Button {
                    openSelectedTakeInEditor()
                } label: {
                    Label("Open In Editor", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .disabled(recordingTakes.isEmpty)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private var teleprompterProgress: Double {
        if let pausedAt = teleprompterPausedAt {
            return max(0, pausedAt - teleprompterPausedAccumulated)
        }
        return max(0, captureEngine.recordingDuration - teleprompterPausedAccumulated)
    }
}

// MARK: - Supporting Types

private enum RecordingSidebarTab: String, CaseIterable {
    case setup, script, frame

    var label: String {
        rawValue.capitalized
    }
}

private enum AspectRatioPreset: String, CaseIterable {
    case vertical9x16
    case portrait4x5
    case square1x1
    case landscape16x9

    var label: String {
        switch self {
        case .vertical9x16: return "9:16"
        case .portrait4x5: return "4:5"
        case .square1x1: return "1:1"
        case .landscape16x9: return "16:9"
        }
    }

    var ratio: CGFloat {
        switch self {
        case .vertical9x16: return 9.0 / 16.0
        case .portrait4x5: return 4.0 / 5.0
        case .square1x1: return 1.0
        case .landscape16x9: return 16.0 / 9.0
        }
    }
}

private enum CountdownOption: String, CaseIterable {
    case off, three, five, ten

    var label: String {
        switch self {
        case .off: return "Off"
        case .three: return "3s"
        case .five: return "5s"
        case .ten: return "10s"
        }
    }

    var seconds: Int {
        switch self {
        case .off: return 0
        case .three: return 3
        case .five: return 5
        case .ten: return 10
        }
    }
}

private enum PrivacyPermissionKind: String {
    case camera
    case microphone
    case speech
    case screenRecording

    var label: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .speech: return "Speech"
        case .screenRecording: return "Screen Recording"
        }
    }
}

private struct PermissionDiagnosticsItem: Identifiable {
    let kind: PrivacyPermissionKind
    let granted: Bool
    let statusLabel: String

    var id: String { kind.rawValue }
}

// MARK: - Reusable Components

private struct ControlCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
    }
}

private struct ControlRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct CompactPickerRow: View {
    let label: String
    @Binding var selection: String
    let options: [CaptureDeviceOption]
    let onChangeSelection: (CaptureDeviceOption) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 54, alignment: .leading)
            Picker(label, selection: $selection) {
                ForEach(options) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: selection) { _, newValue in
                guard let option = options.first(where: { $0.id == newValue }) else { return }
                onChangeSelection(option)
            }
        }
    }
}

private struct CompactSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Text("\(Int(value)) \(unit)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Slider(value: $value, in: range)
                .tint(tint)
        }
    }
}

// MARK: - Reverse Mask Extension

extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask(
            ZStack {
                Rectangle()
                mask()
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}
