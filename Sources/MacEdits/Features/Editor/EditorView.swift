import AVFoundation
import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

// MARK: - EditorView (Task 1.3 – split shell)
struct EditorView: View {
    @Environment(AppModel.self) private var appModel
    @State private var editorEnv = EditorEnvironment()
    @State private var exportEngine = ExportEngine()
    @State private var voiceoverEngine = VoiceoverEngine()
    @State private var captionEngine = CaptionEngine()
    @State private var filterPreviewService = FilterPreviewService()

    @State private var draftWorkspace: ProjectWorkspace
    @State private var selectedAssetID: UUID?
    @State private var selectedClipID: UUID?
    @State private var selectedClipIDs: Set<UUID>
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var lastExportURL: URL?
    @State private var exportFailureMessage: String?
    @State private var isCancellingExport = false
    @State private var inspectorTab: InspectorTab = .edit
    @State private var playbackTime: Double = 0
    @State private var timeObserverToken: Any?
    @State private var playbackDidEndObserver: NSObjectProtocol?
    @State private var selectedTextOverlayID: UUID?
    @State private var selectedMarkerID: UUID?
    @State private var isPreparingPreview = false
    @State private var pendingScrubTimelineTime: Double?
    @State private var previewAudioMixRevision = 0
    @State private var isDroppingMedia = false
    @State private var timelineZoom: CGFloat = 1.0
    @State private var timelineMagnifyStartZoom: CGFloat?
    @State private var leftRailWidth: CGFloat = 200
    @State private var inspectorWidth: CGFloat = 300
    @State private var previewHeightRatio: CGFloat = 0.64
    @State private var centerViewportWidth: CGFloat = 960
    @State private var leftRailDragStart: CGFloat?
    @State private var inspectorDragStart: CGFloat?
    @State private var previewSplitDragStartHeight: CGFloat?
    @State private var snapToFramesEnabled = true
    @State private var magneticScrubEnabled = true
    @State private var rippleEditsEnabled = true
    @State private var lockedTrackIDs: Set<UUID> = []
    @State private var mutedTrackIDs: Set<UUID> = []
    @State private var soloTrackIDs: Set<UUID> = []
    @State private var collapsedTrackIDs: Set<UUID> = []
    @State private var marqueeTrackID: UUID?
    @State private var marqueeXRange: ClosedRange<CGFloat>?
    @State private var endHandoffClipID: UUID?
    @State private var isUpdatingPlayer = false
    @State private var needsPlayerRefresh = false
    @State private var layoutPreset: EditorLayoutPreset = .balanced

    private let timelinePlayheadInset: CGFloat = 14
    private let timelineTrackLabelWidth: CGFloat = 196
    private let timelineLaneHeight: CGFloat = 74
    private let collapsedTimelineLaneHeight: CGFloat = 34
    private let baseTimelinePointsPerSecond: CGFloat = 44
    private let toolRailHeight: CGFloat = 112
    private let centerStackSpacing: CGFloat = 12

    private var timelinePointsPerSecond: CGFloat {
        baseTimelinePointsPerSecond * timelineZoom
    }

    private static let minZoom: CGFloat = 0.25
    private static let maxZoom: CGFloat = 6.0
    private static let leftRailWidthRange: ClosedRange<CGFloat> = 170...360
    private static let inspectorWidthRange: ClosedRange<CGFloat> = 260...460
    private static let previewHeightRatioRange: ClosedRange<CGFloat> = 0.40...0.80

    let workspace: ProjectWorkspace

    private var frameDuration: Double {
        1.0 / max(1, Double(draftWorkspace.file.exportPreset.frameRate))
    }

    init(workspace: ProjectWorkspace) {
        self.workspace = workspace
        let initialClipID = workspace.file.timelineClips.first(where: { $0.lane == .video })?.id
        _draftWorkspace = State(initialValue: workspace)
        _selectedAssetID = State(initialValue: workspace.file.assets.first(where: { $0.type == .video })?.id)
        _selectedClipID = State(initialValue: initialClipID)
        _selectedClipIDs = State(initialValue: initialClipID.map { Set([$0]) } ?? Set<UUID>())
        _selectedTextOverlayID = State(initialValue: workspace.file.textOverlays.first?.id)
        _selectedMarkerID = State(initialValue: workspace.file.markers.first?.id)
    }

    var body: some View {
        layoutContent
            .overlay(dropOverlay)
            .onDrop(of: [.fileURL, .movie, .audio, .image], isTargeted: $isDroppingMedia, perform: handleDrop)
            .background(editorBackground)
    }

    // Extracted to keep body short for Swift type-checker
    private var layoutContent: some View {
        VStack(spacing: 14) {
            topBar

            HStack(alignment: .top, spacing: 14) {
                if !editorEnv.isRailCollapsed {
                    leftRail
                        .frame(width: leftRailWidth)
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                    verticalResizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if leftRailDragStart == nil {
                                        leftRailDragStart = leftRailWidth
                                        layoutPreset = .custom
                                    }
                                    let start = leftRailDragStart ?? leftRailWidth
                                    leftRailWidth = max(
                                        Self.leftRailWidthRange.lowerBound,
                                        min(Self.leftRailWidthRange.upperBound, start + value.translation.width)
                                    )
                                }
                                .onEnded { _ in
                                    leftRailDragStart = nil
                                }
                        )
                }
                centerWorkspace
                if editorEnv.isInspectorVisible {
                    verticalResizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if inspectorDragStart == nil {
                                        inspectorDragStart = inspectorWidth
                                        layoutPreset = .custom
                                    }
                                    let start = inspectorDragStart ?? inspectorWidth
                                    inspectorWidth = max(
                                        Self.inspectorWidthRange.lowerBound,
                                        min(Self.inspectorWidthRange.upperBound, start - value.translation.width)
                                    )
                                }
                                .onEnded { _ in
                                    inspectorDragStart = nil
                                }
                        )
                    inspector
                        .frame(width: inspectorWidth)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: editorEnv.isRailCollapsed)
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: editorEnv.isInspectorVisible)
        }
        .padding(18)
        .frame(minWidth: 1020, minHeight: 720, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if exportEngine.isExporting {
                exportProgressOverlay
            }
        }
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: workspace, handleWorkspaceChange)
        .onChange(of: appModel.currentWorkspace, handleCurrentWorkspaceChange)
        .onChange(of: selectedAssetID, handleAssetSelectionChange)
        .onChange(of: selectedClipID, handleClipSelection)
        .onChange(of: draftWorkspace.file.styleSettings.look) { _, _ in persistStyleAndRefreshPreview() }
        .onChange(of: draftWorkspace.file.styleSettings.lookIntensity) { _, _ in persistStyleAndRefreshPreview() }
        .onChange(of: draftWorkspace.file.styleSettings.captionStyle) { _, _ in persistStyleAndRefreshPreview() }
        .onChange(of: draftWorkspace.file.timelineClips) { _, _ in
            refreshPreviewAudioMix()
        }
        .onChange(of: draftWorkspace.file.textOverlays) { _, _ in syncSelectionIfNeeded() }
        .onChange(of: draftWorkspace.file.markers) { _, _ in syncSelectionIfNeeded() }
        .onChange(of: mutedTrackIDs) { _, _ in
            refreshPreviewAudioMix()
        }
        .onChange(of: soloTrackIDs) { _, _ in
            refreshPreviewAudioMix()
        }
        .onChange(of: voiceoverEngine.recordedFileURL, handleVoiceover)
        .modifier(EditorKeyboardShortcuts(
            onSpace: {
                guard selectedClip != nil else { return }
                togglePlayback()
            },
            onDelete: {
                if selectedClipIDs.count > 1 {
                    deleteSelectedClips()
                    return
                }
                guard let clipID = selectedClipID else { return }
                deleteClipWithCurrentEditMode(clipID)
            },
            onLeft: selectPreviousClip,
            onRight: selectNextClip,
            onUndo: {
                if let restored = editorEnv.undo(current: draftWorkspace) {
                    draftWorkspace = restored
                    syncSelectionIfNeeded()
                    updatePlayer()
                    appModel.saveCurrentWorkspace(restored)
                }
            },
            onRedo: {
                if let restored = editorEnv.redo(current: draftWorkspace) {
                    draftWorkspace = restored
                    syncSelectionIfNeeded()
                    updatePlayer()
                    appModel.saveCurrentWorkspace(restored)
                }
            },
            onZoomIn: { adjustZoom(by: 0.25) },
            onZoomOut: { adjustZoom(by: -0.25) },
            onZoomReset: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    timelineZoom = 1.0
                }
            },
            onFitTimeline: fitTimelineToView,
            onExport: {
                guard !exportEngine.isExporting, !draftWorkspace.file.timelineClips.isEmpty else { return }
                startExportFlow()
            },
            onSplitClip: splitSelectedClipAtPlayhead,
            onAddMarker: addMarkerAtPlayhead,
            onNextMarker: { jumpToMarker(direction: .next) },
            onPreviousMarker: { jumpToMarker(direction: .previous) },
            onNextCut: { jumpToCut(direction: .next) },
            onPreviousCut: { jumpToCut(direction: .previous) },
            onFrameStepBackward: { stepTimelineByFrames(-1) },
            onFrameStepForward: { stepTimelineByFrames(1) },
            onShuttleBackward: { shuttleTimeline(by: -0.5) },
            onShuttlePausePlay: { togglePlayback() },
            onShuttleForward: { shuttleTimeline(by: 0.5) },
            onToggleRipple: { rippleEditsEnabled.toggle() }
        ))
        .alert("Export Failed", isPresented: exportFailureAlertBinding, actions: {
            Button("Retry Export") {
                startExportFlow()
            }
            Button("Close", role: .cancel) {}
        }, message: {
            Text(exportFailureMessage ?? "The export did not complete.")
        })
        .focusable()
    }

    // MARK: - Event Handlers (extracted for type-checking performance)

    private func handleAppear() {
        syncSelectionIfNeeded()
        applyLayoutPreset(layoutPreset, animated: false)
        if let pendingAssetID = appModel.pendingEditorAssetSelectionID {
            applyPendingEditorSelection(assetID: pendingAssetID)
            appModel.pendingEditorAssetSelectionID = nil
        }
        installTimeObserverIfNeeded()
        updatePlayer()
    }

    private func handleDisappear() {
        removeTimeObserver()
        removePlaybackDidEndObserver()
    }

    private func handleWorkspaceChange(_ old: ProjectWorkspace, _ new: ProjectWorkspace) {
        draftWorkspace = new
        syncSelectionIfNeeded()
        updatePlayer()
    }

    private func handleCurrentWorkspaceChange(_ old: ProjectWorkspace?, _ new: ProjectWorkspace?) {
        guard let new, new.id == draftWorkspace.id else { return }
        draftWorkspace = new
        syncSelectionIfNeeded()
        if let pendingAssetID = appModel.pendingEditorAssetSelectionID {
            applyPendingEditorSelection(assetID: pendingAssetID)
            appModel.pendingEditorAssetSelectionID = nil
        }
        updatePlayer()
    }

    private func handleAssetSelectionChange(_ old: UUID?, _ new: UUID?) {
        guard old != new else { return }
        guard let assetID = new else {
            updatePlayer()
            return
        }

        if let clip = selectedClip, clip.assetID == assetID {
            return
        }

        if let firstClipForAsset = draftWorkspace.file.timelineClips.first(where: { $0.assetID == assetID && $0.lane == .video }) {
            if selectedClipID != firstClipForAsset.id {
                selectedClipID = firstClipForAsset.id
                selectedClipIDs = [firstClipForAsset.id]
                return
            }
        }

        updatePlayer()
    }

    private func handleClipSelection(_ old: UUID?, _ new: UUID?) {
        if let clip = draftWorkspace.file.clip(for: new) {
            selectedAssetID = clip.assetID
            if selectedClipIDs.isEmpty {
                selectedClipIDs = [clip.id]
            } else if !selectedClipIDs.contains(clip.id) {
                selectedClipIDs = [clip.id]
            }
        }
        endHandoffClipID = nil
        updatePlayer()
    }

    private func handleVoiceover(_ old: URL?, _ new: URL?) {
        guard let new else { return }
        let insertionTime = max(0, currentTimelineTime)
        appModel.attachVoiceoverAsset(from: new, startTime: insertionTime)
        voiceoverEngine.clearRecordedFile()
    }

    private func selectPreviousClip() {
        let clips = videoTimelineClips
        guard let currentID = selectedClipID,
              let idx = clips.firstIndex(where: { $0.id == currentID }),
              idx > 0 else { return }
        let prev = clips[idx - 1]
        selectedClipID = prev.id
        selectedClipIDs = [prev.id]
        selectedAssetID = prev.assetID
    }

    private func selectNextClip() {
        let clips = videoTimelineClips
        guard let currentID = selectedClipID,
              let idx = clips.firstIndex(where: { $0.id == currentID }),
              idx < clips.count - 1 else { return }
        let next = clips[idx + 1]
        selectedClipID = next.id
        selectedClipIDs = [next.id]
        selectedAssetID = next.assetID
    }


    // MARK: - Component views extracted for compiler type-check performance

    @ViewBuilder
    private var dropOverlay: some View {
        if isDroppingMedia {
            ZStack {
                AppTheme.accent.opacity(0.10)
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(AppTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [14, 8]))
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(AppTheme.accent)
                    Text("Drop media to import")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Videos, audio files and images")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .ignoresSafeArea()
        }
    }

    private var editorBackground: some View {
        ZStack {
            AppTheme.windowBackground
            AppTheme.editorGlow
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            // Close / back
            Button { appModel.returnHome() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close project")
            .accessibilityLabel("Close project and return home")

            // Rail toggle (Task 2.2)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                    editorEnv.isRailCollapsed.toggle()
                }
            } label: {
                Image(systemName: editorEnv.isRailCollapsed ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(editorEnv.isRailCollapsed ? AppTheme.accent : .white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(editorEnv.isRailCollapsed ? "Show media library" : "Hide media library")
            .accessibilityLabel(editorEnv.isRailCollapsed ? "Show media library" : "Hide media library")

            VStack(alignment: .leading, spacing: 2) {
                Text(draftWorkspace.summary.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Mac Edits")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 20)

            // Undo / Redo (Task 5.1)
            HStack(spacing: 4) {
                Button {
                    if let restored = editorEnv.undo(current: draftWorkspace) {
                        draftWorkspace = restored
                        syncSelectionIfNeeded()
                        updatePlayer()
                        appModel.saveCurrentWorkspace(restored)
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(editorEnv.canUndo ? .white : Color.white.opacity(0.3))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!editorEnv.canUndo)
                .help("Undo (⌘Z)")
                .accessibilityLabel("Undo")

                Button {
                    if let restored = editorEnv.redo(current: draftWorkspace) {
                        draftWorkspace = restored
                        syncSelectionIfNeeded()
                        updatePlayer()
                        appModel.saveCurrentWorkspace(restored)
                    }
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(editorEnv.canRedo ? .white : Color.white.opacity(0.3))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!editorEnv.canRedo)
                .help("Redo (⌘⇧Z)")
                .accessibilityLabel("Redo")
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                FeatureBadge(label: "\(draftWorkspace.file.exportPreset.width)×\(draftWorkspace.file.exportPreset.height)")
                FeatureBadge(label: String(format: "%.1fs", draftWorkspace.file.totalDuration))
            }

            HStack(spacing: 6) {
                ForEach(EditorLayoutPreset.selectableCases, id: \.self) { preset in
                    Button {
                        applyLayoutPreset(preset)
                    } label: {
                        Text(preset.shortLabel)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(layoutPreset == preset ? .white : AppTheme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(layoutPreset == preset ? AppTheme.accent.opacity(0.3) : Color.white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Switch to \(preset.label) layout")
                }

                if layoutPreset == .custom {
                    Text("Custom")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.04))
                        .clipShape(Capsule())
                }
            }

            Spacer(minLength: 20)

            HStack(spacing: 8) {
                toolbarButton(title: "Import", systemImage: "square.and.arrow.down.on.square") {
                    appModel.importAssetsIntoCurrentProject()
                }

                toolbarButton(title: "Record", systemImage: "record.circle", tint: AppTheme.recordAccent) {
                    appModel.moveToRecording()
                }

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                        let shouldEnterFocus = !(editorEnv.isRailCollapsed && !editorEnv.isInspectorVisible)
                        editorEnv.isRailCollapsed = shouldEnterFocus
                        editorEnv.isInspectorVisible = !shouldEnterFocus
                    }
                } label: {
                    Image(systemName: "rectangle.center.inset.filled")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle((editorEnv.isRailCollapsed && !editorEnv.isInspectorVisible) ? AppTheme.accent : .white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help((editorEnv.isRailCollapsed && !editorEnv.isInspectorVisible) ? "Exit focus mode" : "Enter focus mode")
                .accessibilityLabel((editorEnv.isRailCollapsed && !editorEnv.isInspectorVisible) ? "Exit focus mode" : "Enter focus mode")

                // Inspector toggle (Task 2.1)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                        editorEnv.isInspectorVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(editorEnv.isInspectorVisible ? .white : AppTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(editorEnv.isInspectorVisible ? "Hide inspector" : "Show inspector")
                .accessibilityLabel(editorEnv.isInspectorVisible ? "Hide inspector" : "Show inspector")

                Button {
                    startExportFlow()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: exportEngine.isExporting ? "arrow.up.circle" : "square.and.arrow.up")
                        Text(exportEngine.isExporting ? "Exporting \(Int(exportEngine.progress * 100))%" : "Export Reel")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(red: 0.23, green: 0.42, blue: 1.0))
                    )
                }
                .buttonStyle(.plain)
                .disabled(exportEngine.isExporting || draftWorkspace.file.timelineClips.isEmpty)
                .opacity((exportEngine.isExporting || draftWorkspace.file.timelineClips.isEmpty) ? 0.6 : 1)
                .accessibilityLabel(exportEngine.isExporting ? "Exporting project" : "Export reel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.panel(cornerRadius: 24))
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Media")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(draftWorkspace.file.assets.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
            }

            HStack(spacing: 6) {
                miniCount(icon: "film", count: draftWorkspace.file.assets.filter { $0.type == .video }.count)
                miniCount(icon: "waveform", count: draftWorkspace.file.assets.filter { $0.type == .audio }.count)
                miniCount(icon: "photo", count: draftWorkspace.file.assets.filter { $0.type == .image }.count)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(draftWorkspace.file.assets) { asset in
                        Button {
                            selectedAssetID = asset.id
                            if let clip = draftWorkspace.file.timelineClips.first(where: { $0.assetID == asset.id }) {
                                selectedClipID = clip.id
                                selectedClipIDs = [clip.id]
                            }
                        } label: {
                            AssetRow(asset: asset, isSelected: asset.id == selectedAssetID)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if draftWorkspace.file.assets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(AppTheme.tertiaryText)
                    Text("Import or record media")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.panel(cornerRadius: 18))
    }

    private func miniCount(icon: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(count > 0 ? .white : AppTheme.tertiaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.04))
        .clipShape(Capsule())
    }

    private var verticalResizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.01))
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(width: 3, height: 42)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private var horizontalResizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.01))
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(width: 64, height: 3)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private var centerWorkspace: some View {
        GeometryReader { proxy in
            let availableHeight = max(420, proxy.size.height)
            let contentHeight = max(
                280,
                availableHeight - toolRailHeight - centerStackSpacing - centerStackSpacing
            )
            let rawPreviewHeight = contentHeight * previewHeightRatio
            let previewHeight = max(220, min(contentHeight - 170, rawPreviewHeight))
            let timelineHeight = max(150, contentHeight - previewHeight)

            VStack(spacing: centerStackSpacing) {
                previewStage
                    .frame(height: previewHeight)

                horizontalResizeHandle
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if previewSplitDragStartHeight == nil {
                                    previewSplitDragStartHeight = previewHeight
                                    layoutPreset = .custom
                                }
                                let start = previewSplitDragStartHeight ?? previewHeight
                                let updatedHeight = start + value.translation.height
                                let ratio = updatedHeight / max(contentHeight, 1)
                                previewHeightRatio = max(
                                    Self.previewHeightRatioRange.lowerBound,
                                    min(Self.previewHeightRatioRange.upperBound, ratio)
                                )
                            }
                            .onEnded { _ in
                                previewSplitDragStartHeight = nil
                            }
                    )

                timelinePanel
                    .frame(height: timelineHeight)

                bottomToolRail
                    .frame(height: toolRailHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                centerViewportWidth = proxy.size.width
            }
            .onChange(of: proxy.size.width) { _, newValue in
                centerViewportWidth = newValue
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewStage: some View {
        VStack(spacing: 0) {
            // Preview canvas — full bleed, no headers
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black)
                previewCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                // Minimal overlay badges
                VStack {
                    HStack(spacing: 6) {
                        if draftWorkspace.file.styleSettings.look != .clean {
                            overlayChip(draftWorkspace.file.styleSettings.look.rawValue)
                        }
                        Spacer()
                        if let clip = selectedClip {
                            overlayChip(String(format: "%.1fs", clip.duration))
                        }
                    }
                    .padding(12)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // Compact transport bar
            HStack(spacing: 10) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color(red: 0.24, green: 0.42, blue: 1.0))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(selectedClip == nil)
                .opacity(selectedClip == nil ? 0.4 : 1)

                Button {
                    seekToSelectedClipStart(playIfNeeded: isPlaying)
                    playbackTime = 0
                    if isPlaying { player.play() }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(selectedClip == nil)

                // Scrubber placeholder
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 4)
                        if draftWorkspace.file.totalDuration > 0 {
                            let progress = max(0, min(1, currentTimelineTime / max(draftWorkspace.file.totalDuration, 0.01)))
                            Capsule()
                                .fill(AppTheme.accent)
                                .frame(
                                    width: max(4, geo.size.width * CGFloat(progress)),
                                    height: 4
                                )

                            Circle()
                                .fill(AppTheme.accent)
                                .frame(width: 10, height: 10)
                                .offset(x: max(0, min(geo.size.width - 10, (geo.size.width * CGFloat(progress)) - 5)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let ratio = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                                scrubTimeline(to: ratio * max(draftWorkspace.file.totalDuration, 0))
                            }
                    )
                }
                .frame(height: 32)

                Text(playheadLabel)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 54, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(AppTheme.panel(cornerRadius: 22))
    }

    private func overlayChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial.opacity(0.5))
            .clipShape(Capsule())
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Timeline")
                .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Playhead \(currentTimelineTime.formatted(.number.precision(.fractionLength(2))))s")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())

                Text(String(format: "%.1fs", draftWorkspace.file.totalDuration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)

                // Zoom controls
                HStack(spacing: 4) {
                    Button {
                        adjustZoom(by: -0.25)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(timelineZoom <= Self.minZoom)
                    .accessibilityLabel("Zoom out timeline")

                    Text(String(format: "%d%%", Int(timelineZoom * 100)))
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 36)

                    Button {
                        adjustZoom(by: 0.25)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(timelineZoom >= Self.maxZoom)
                    .accessibilityLabel("Zoom in timeline")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())

                Button {
                    fitTimelineToView()
                } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fit timeline to visible width (Shift+Z)")
                .accessibilityLabel("Fit timeline to view")

                Button {
                    snapToFramesEnabled.toggle()
                } label: {
                    Image(systemName: "dot.squareshape.split.2x2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(snapToFramesEnabled ? AppTheme.accent : AppTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle frame snapping")
                .accessibilityLabel(snapToFramesEnabled ? "Disable frame snapping" : "Enable frame snapping")

                Button {
                    magneticScrubEnabled.toggle()
                } label: {
                    Image(systemName: "magnet")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(magneticScrubEnabled ? AppTheme.accent : AppTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle magnetic snap to nearby cuts and markers")
                .accessibilityLabel(magneticScrubEnabled ? "Disable magnetic snapping" : "Enable magnetic snapping")

                Button {
                    rippleEditsEnabled.toggle()
                } label: {
                    Image(systemName: rippleEditsEnabled ? "link" : "link.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(rippleEditsEnabled ? AppTheme.accent : AppTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(rippleEditsEnabled ? "Disable ripple edits (preserve gaps)" : "Enable ripple edits (close gaps)")
                .accessibilityLabel(rippleEditsEnabled ? "Disable ripple edits" : "Enable ripple edits")

                Button {
                    addMarkerAtPlayhead()
                } label: {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add marker at playhead (M)")
                .accessibilityLabel("Add marker at playhead")

                Button {
                    splitSelectedClipAtPlayhead()
                } label: {
                    Image(systemName: "scissors")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selectedClip == nil)
                .help("Split selected clip at playhead (S)")
                .accessibilityLabel("Split selected clip at playhead")

                Button {
                    jumpToCut(direction: .previous)
                } label: {
                    Image(systemName: "backward.to.line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump to previous cut ([)")
                .accessibilityLabel("Jump to previous cut")

                Button {
                    jumpToCut(direction: .next)
                } label: {
                    Image(systemName: "forward.to.line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump to next cut (])")
                .accessibilityLabel("Jump to next cut")

                Menu {
                    Button("Import Media") {
                        appModel.importAssetsIntoCurrentProject()
                    }
                    Button("Open Recording Studio") {
                        appModel.moveToRecording()
                    }
                    Divider()
                    Button("Add Marker At Playhead") {
                        addMarkerAtPlayhead()
                    }
                    Button("Add Title Overlay") {
                        addTextOverlay(style: .title, position: .top)
                    }
                    Button("Add Caption Overlay") {
                        addTextOverlay(style: .caption, position: .bottom)
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("Add media, marker, or overlay")
                .accessibilityLabel("Timeline add actions")

                Text("9:16")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
            }

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                VStack(spacing: 6) {
                    timelineRuler
                    ForEach(draftWorkspace.file.timelineTracks) { track in
                        timelineTrackRow(track)
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            timelineFooter
            timelineMinimap
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.panel(cornerRadius: 28))
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    if timelineMagnifyStartZoom == nil {
                        timelineMagnifyStartZoom = timelineZoom
                    }
                    let startZoom = timelineMagnifyStartZoom ?? timelineZoom
                    let newZoom = max(Self.minZoom, min(Self.maxZoom, startZoom * value.magnification))
                    timelineZoom = newZoom
                }
                .onEnded { _ in
                    timelineMagnifyStartZoom = nil
                }
        )
    }

    private func timelineTrackRow(_ track: ProjectTrack) -> some View {
        let clips = draftWorkspace.file.clips(for: track.id)
        let isCollapsed = collapsedTrackIDs.contains(track.id)
        let laneHeight = isCollapsed ? collapsedTimelineLaneHeight : timelineLaneHeight
        let trackLocked = lockedTrackIDs.contains(track.id)
        let trackMuted = mutedTrackIDs.contains(track.id)
        let trackSoloSuppressed = !soloTrackIDs.isEmpty && !soloTrackIDs.contains(track.id)
        let trackDimmed = trackMuted || trackSoloSuppressed

        return HStack(alignment: .center, spacing: 10) {
            trackBadge(track, isCollapsed: isCollapsed)
                .frame(minWidth: timelineTrackLabelWidth, maxWidth: timelineTrackLabelWidth, alignment: .leading)
                .opacity(trackDimmed ? 0.58 : 1)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(trackLaneBackground(for: track.kind))

                HStack(spacing: CGFloat(timelineRulerTickInterval) * timelinePointsPerSecond) {
                    let totalDuration = max(8, draftWorkspace.file.totalDuration + 4)
                    let tickCount = Int(ceil(totalDuration / timelineRulerTickInterval))
                    ForEach(0..<tickCount, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, timelinePlayheadInset)

                ZStack(alignment: .topLeading) {
                    if clips.isEmpty {
                        Text("No clips")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .offset(x: timelinePlayheadInset + 10, y: max(5, (laneHeight - 22) / 2))
                    } else {
                        if isCollapsed {
                            let compactClipHeight = max(14, laneHeight - 10)
                            ForEach(clips) { clip in
                                let clipWidth = max(16, CGFloat(clip.duration) * timelinePointsPerSecond)
                                Button {
                                    selectClipFromTimelineTap(clip)
                                } label: {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(trackTint(for: track.kind).opacity(selectedClipIDs.contains(clip.id) ? 0.38 : 0.24))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(selectedClipIDs.contains(clip.id) ? AppTheme.accent : trackTint(for: track.kind).opacity(0.75), lineWidth: selectedClipIDs.contains(clip.id) ? 2 : 1)
                                        )
                                        .overlay(alignment: .leading) {
                                            if clipWidth > 90 {
                                                Text(clip.title)
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.white.opacity(0.88))
                                                    .lineLimit(1)
                                                    .padding(.horizontal, 7)
                                            }
                                        }
                                        .frame(width: clipWidth, height: compactClipHeight)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Timeline clip \(clip.title)")
                                .accessibilityHint("Click to select clip. Expand track for drag trim actions.")
                                .contextMenu {
                                    timelineClipContextMenu(for: clip)
                                }
                                .offset(
                                    x: timelinePlayheadInset + (CGFloat(clip.startTime) * timelinePointsPerSecond),
                                    y: (laneHeight - compactClipHeight) / 2
                                )
                                .opacity(trackDimmed ? 0.55 : 1)
                            }
                        } else {
                            ForEach(clips) { clip in
                                if let asset = draftWorkspace.file.asset(for: clip.assetID) {
                                    Button {
                                        selectClipFromTimelineTap(clip)
                                    } label: {
                                        TimelineClipPill(
                                            clip: clip,
                                            asset: asset,
                                            projectURL: draftWorkspace.summary.projectURL,
                                            isSelected: selectedClipIDs.contains(clip.id),
                                            pixelsPerSecond: timelinePointsPerSecond,
                                            onClipDragged: { translation in
                                                guard !trackLocked else { return }
                                                reorderClipFromDrag(clip, translationWidth: translation)
                                            },
                                            onTrimStartDragged: { delta in
                                                guard !trackLocked else { return }
                                                trimClipStartFromDrag(clip, deltaSeconds: delta)
                                            },
                                            onTrimEndDragged: { delta in
                                                guard !trackLocked else { return }
                                                trimClipEndFromDrag(clip, deltaSeconds: delta)
                                            }
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Timeline clip \(clip.title)")
                                    .accessibilityHint("Drag to reorder. Drag clip handles to trim. Right click for more actions.")
                                    .contextMenu {
                                        timelineClipContextMenu(for: clip)
                                    }
                                    .offset(
                                        x: timelinePlayheadInset + (CGFloat(clip.startTime) * timelinePointsPerSecond),
                                        y: 6
                                    )
                                    .opacity(trackDimmed ? 0.5 : 1)
                                }
                            }

                            // Transition diamonds between adjacent clips
                            ForEach(transitionPairs(for: clips), id: \.0.id) { fromClip, toClip in
                                let trans = draftWorkspace.file.transition(between: fromClip.id, and: toClip.id)
                                let x = timelinePlayheadInset + CGFloat(fromClip.startTime + fromClip.duration) * timelinePointsPerSecond
                                TransitionDiamond(
                                    type: trans?.type ?? .none,
                                    duration: trans?.duration ?? 0.5,
                                    onSelectType: { selectedTransitionType in
                                        applyTimelineEdit {
                                            $0.file.setTransition(
                                                from: fromClip.id,
                                                to: toClip.id,
                                                type: selectedTransitionType,
                                                duration: trans?.duration ?? 0.5
                                            )
                                        }
                                    },
                                    onSelectDuration: { selectedDuration in
                                        guard let existingTransition = draftWorkspace.file.transition(between: fromClip.id, and: toClip.id) else { return }
                                        applyTimelineEdit {
                                            $0.file.setTransition(
                                                from: fromClip.id,
                                                to: toClip.id,
                                                type: existingTransition.type,
                                                duration: selectedDuration
                                            )
                                        }
                                    }
                                )
                                .offset(x: x - 12, y: laneHeight / 2 - 11)
                            }
                        }
                    }

                    if marqueeTrackID == track.id, let marqueeXRange {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(AppTheme.accent.opacity(0.22))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(AppTheme.accent.opacity(0.85), lineWidth: 1)
                            )
                            .frame(width: marqueeXRange.upperBound - marqueeXRange.lowerBound, height: laneHeight - 8)
                            .offset(x: marqueeXRange.lowerBound, y: 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: timelineCanvasWidth, height: laneHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if isMarqueeSelectionModifierActive {
                                updateTrackMarqueeSelection(
                                    track: track,
                                    startX: value.startLocation.x,
                                    currentX: value.location.x
                                )
                            } else {
                                scrubTimelineFromTimelineCanvas(x: value.location.x)
                            }
                        }
                        .onEnded { _ in
                            marqueeTrackID = nil
                            marqueeXRange = nil
                        }
                )

                Rectangle()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 1.5)
                    .frame(height: laneHeight)
                    .offset(x: playheadXInCanvas)
            }
            .opacity(trackDimmed ? 0.62 : 1)
        }
        .frame(height: laneHeight)
    }

    private var timelineFooter: some View {
        HStack(spacing: 10) {
            Button {
                nudgeTimeline(by: -1)
            } label: {
                Image(systemName: "gobackward.1")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .disabled(draftWorkspace.file.totalDuration <= 0)
            .accessibilityLabel("Move playhead backward by one second")

            Button {
                nudgeTimeline(by: 1)
            } label: {
                Image(systemName: "goforward.1")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .disabled(draftWorkspace.file.totalDuration <= 0)
            .accessibilityLabel("Move playhead forward by one second")

            Button {
                stepTimelineByFrames(-1)
            } label: {
                Image(systemName: "backward.frame.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .disabled(draftWorkspace.file.totalDuration <= 0)
            .accessibilityLabel("Step backward one frame")

            Button {
                stepTimelineByFrames(1)
            } label: {
                Image(systemName: "forward.frame.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .disabled(draftWorkspace.file.totalDuration <= 0)
            .accessibilityLabel("Step forward one frame")

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 14)

            Text(playheadLabel)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 108, alignment: .leading)

            GeometryReader { geo in
                Capsule()
                    .fill(Color.white.opacity(0.07))
                    .overlay(alignment: .leading) {
                        let ratio = max(0, min(1, currentTimelineTime / max(draftWorkspace.file.totalDuration, 0.01)))
                        Capsule()
                            .fill(AppTheme.accent)
                            .frame(width: max(8, geo.size.width * ratio))
                    }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 4)

            Text("Drag reorder  •  Shift-drag range select  •  C/B/X/S split  •  [/] cuts  •  ,/. frame  •  R ripple  •  Ripple \(rippleEditsEnabled ? "On" : "Off")")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 6)
    }

    private var timelineMinimap: some View {
        GeometryReader { geo in
            let total = max(0.01, draftWorkspace.file.totalDuration)
            let width = max(1, geo.size.width)
            let playheadRatio = CGFloat(currentTimelineTime / total)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                ForEach(videoTimelineClips) { clip in
                    let start = CGFloat(clip.startTime / total)
                    let clipWidth = max(2, CGFloat(clip.duration / total) * width)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill((selectedClipID == clip.id ? AppTheme.accent : AppTheme.importAccent).opacity(selectedClipID == clip.id ? 0.88 : 0.5))
                        .frame(width: clipWidth, height: 10)
                        .offset(x: start * width)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 2, height: 16)
                    .offset(x: min(max(0, playheadRatio * width), width - 2))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(max(0, value.location.x / max(width, 1)), 1)
                        scrubTimeline(to: total * Double(ratio))
                    }
            )
        }
        .frame(height: 18)
        .accessibilityLabel("Timeline overview minimap")
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorTabs

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    switch inspectorTab {
                    case .edit:
                        editInspector
                    case .audio:
                        audioInspector
                    case .style:
                        styleInspector
                    case .text:
                        textInspector
                    case .output:
                        outputInspector
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.panel(cornerRadius: 22))
    }

    private var editInspector: some View {
        Group {
            InspectorCard(title: "Project") {
                InspectorMetric(label: "Origin", value: draftWorkspace.summary.origin.rawValue)
                InspectorMetric(label: "Assets", value: "\(draftWorkspace.file.assets.count)")
                InspectorMetric(label: "Clips", value: "\(draftWorkspace.file.timelineClips.count)")
                InspectorMetric(label: "Canvas", value: "\(draftWorkspace.file.exportPreset.width)×\(draftWorkspace.file.exportPreset.height)")
            }

            InspectorCard(title: "Timeline Markers") {
                clipActionButton("Add Marker At Playhead") {
                    addMarkerAtPlayhead()
                }

                if draftWorkspace.file.markers.isEmpty {
                    Text("No markers yet. Add one at the playhead to mark an edit point.")
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 8) {
                        ForEach(draftWorkspace.file.markers) { marker in
                            Button {
                                selectMarker(marker.id, seek: true)
                            } label: {
                                TimelineMarkerRow(
                                    marker: marker,
                                    isSelected: marker.id == selectedMarkerID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let marker = selectedMarker {
                    TextField(
                        "Marker label",
                        text: Binding(
                            get: { marker.label },
                            set: { updateSelectedMarker(label: $0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Picker("Color", selection: Binding(
                        get: { marker.color },
                        set: { updateSelectedMarker(color: $0) }
                    )) {
                        ForEach(MarkerColor.allCases, id: \.self) { color in
                            Text(color.displayName).tag(color)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField(
                        "Note (optional)",
                        text: Binding(
                            get: { marker.note ?? "" },
                            set: { updateSelectedMarker(note: $0) }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)

                    HStack {
                        clipActionButton("Jump To Marker") {
                            scrubTimeline(to: marker.time)
                        }
                        clipActionButton("Delete Marker", role: .destructive) {
                            applyTimelineEdit { $0.file.removeMarker(marker.id) }
                        }
                    }
                }
            }

            if let clip = selectedClip {
                InspectorCard(title: "Selected Clip") {
                    InspectorMetric(label: "Title", value: clip.title)
                    InspectorMetric(label: "Track", value: clip.lane.rawValue.capitalized)
                    InspectorMetric(label: "Start", value: clip.startTime.formatted(.number.precision(.fractionLength(1))) + "s")
                    InspectorMetric(label: "Duration", value: clip.duration.formatted(.number.precision(.fractionLength(1))) + "s")
                    InspectorMetric(label: "Source In", value: clip.sourceStart.formatted(.number.precision(.fractionLength(1))) + "s")
                }

                InspectorCard(title: "Clip Actions") {
                    clipActionButton("Trim Start -0.5s") {
                        guard ensureClipEditable(clip, action: "trimming") else { return }
                        trimClipStartByEditMode(clip, delta: 0.5)
                    }
                    clipActionButton("Extend Start +0.5s") {
                        guard ensureClipEditable(clip, action: "trimming") else { return }
                        trimClipStartByEditMode(clip, delta: -0.5)
                    }
                    clipActionButton("Trim End -0.5s") {
                        guard ensureClipEditable(clip, action: "trimming") else { return }
                        trimClipEndByEditMode(clip, delta: -0.5)
                    }
                    clipActionButton("Extend End +0.5s") {
                        guard ensureClipEditable(clip, action: "trimming") else { return }
                        trimClipEndByEditMode(clip, delta: 0.5)
                    }
                    clipActionButton("Split At Playhead") { splitClipAtPlayhead(clip) }
                    clipActionButton("Reverse Clip") { Task { await reverseClipMedia(clip) } }
                    clipActionButton("Cut Silences") { Task { await cutSilences(from: clip) } }
                    clipActionButton("Duplicate Clip") {
                        guard ensureClipEditable(clip, action: "duplicating") else { return }
                        applyTimelineEdit { $0.file.duplicateClip(clip.id) }
                    }
                    clipActionButton("Move Left") {
                        guard ensureClipEditable(clip, action: "moving") else { return }
                        applyTimelineEdit { $0.file.moveClip(clip.id, direction: .left) }
                    }
                    clipActionButton("Move Right") {
                        guard ensureClipEditable(clip, action: "moving") else { return }
                        applyTimelineEdit { $0.file.moveClip(clip.id, direction: .right) }
                    }
                    clipActionButton("Delete Clip", role: .destructive) {
                        guard ensureClipEditable(clip, action: "deleting") else { return }
                        deleteClipWithCurrentEditMode(clip.id)
                        if draftWorkspace.file.clip(for: clip.id) == nil {
                            selectedClipID = draftWorkspace.file.timelineClips.first?.id
                            selectedClipIDs = selectedClipID.map { [$0] } ?? []
                        }
                    }
                }

                InspectorCard(title: "Speed Control") {
                    HStack {
                        Text("Playback Speed")
                            .foregroundStyle(AppTheme.secondaryText)
                        Spacer()
                        Text("\(clip.speedMultiplier, format: .number.precision(.fractionLength(1)))×")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Slider(
                        value: Binding(
                            get: { clip.speedMultiplier },
                            set: { newValue in
                                applyTimelineEdit { $0.file.setClipSpeed(clip.id, speed: newValue) }
                            }
                        ),
                        in: 0.25...4.0,
                        step: 0.25
                    )
                    .tint(AppTheme.importAccent)

                    HStack(spacing: 6) {
                        ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                            Button("\(speed, format: .number.precision(.fractionLength(1)))×") {
                                applyTimelineEdit { $0.file.setClipSpeed(clip.id, speed: speed) }
                            }
                            .buttonStyle(.bordered)
                            .tint(clip.speedMultiplier == speed ? AppTheme.accent : .secondary)
                        }
                    }
                }
            } else {
                InspectorCard(title: "Selected Clip") {
                    Text("Select a timeline clip to trim, split, duplicate, or reorder it.")
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var audioInspector: some View {
        Group {
            InspectorCard(title: "Voiceover Booth") {
                HStack(alignment: .center, spacing: 12) {
                    audioLevelMeter(
                        level: voiceoverEngine.audioLevel,
                        tint: AppTheme.recordAccent
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(voiceoverEngine.statusMessage)
                            .foregroundStyle(.white)
                        Text(voiceoverDurationLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                }

                Button {
                    Task {
                        await toggleVoiceoverRecording()
                    }
                } label: {
                    Label(
                        voiceoverEngine.isRecording ? "Stop Voiceover" : "Record Voiceover",
                        systemImage: voiceoverEngine.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(voiceoverEngine.isRecording ? AppTheme.recordAccent : AppTheme.openAccent)

                Text("Voiceover lands on the voiceover track at the current playhead.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InspectorCard(title: "Mix") {
                if let clip = selectedClip {
                    InspectorMetric(label: "Selected", value: clip.title)
                    InspectorMetric(label: "Track", value: clip.lane.rawValue.capitalized)

                    Slider(
                        value: Binding(
                            get: { clip.volume },
                            set: { newValue in
                                applyTimelineEdit { $0.file.setClipVolume(clip.id, volume: newValue) }
                            }
                        ),
                        in: 0...2
                    )
                    .tint(AppTheme.accent)

                    InspectorMetric(label: "Volume", value: "\(Int(clip.volume * 100))%")

                    Button(clip.isMuted ? "Unmute Clip" : "Mute Clip") {
                        applyTimelineEdit { $0.file.toggleClipMute(clip.id) }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Select a clip to adjust clip volume or mute it before export.")
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            InspectorCard(title: "Audio Tracks") {
                VStack(spacing: 8) {
                    ForEach(audioTimelineClips) { clip in
                        Button {
                            selectedClipID = clip.id
                            selectedClipIDs = [clip.id]
                            selectedAssetID = clip.assetID
                        } label: {
                            AudioTrackRow(clip: clip, isSelected: clip.id == selectedClipID)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if audioTimelineClips.isEmpty {
                    Text("Import music or record a voiceover to populate the audio lanes.")
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var styleInspector: some View {
        Group {
            InspectorCard(title: "Look Presets") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(LookPreset.allCases, id: \.self) { preset in
                            Button {
                                draftWorkspace.file.styleSettings.look = preset
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        if let preview = filterPreviewService.previewImage(for: preset, intensity: draftWorkspace.file.styleSettings.lookIntensity) {
                                            Image(nsImage: preview)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 72, height: 54)
                                                .clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        } else {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(preset.gradient)
                                                .frame(width: 72, height: 54)
                                        }
                                    }
                                    Text(preset.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .padding(8)
                                .background(draftWorkspace.file.styleSettings.look == preset ? AppTheme.accent.opacity(0.24) : AppTheme.raisedBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(draftWorkspace.file.styleSettings.look == preset ? AppTheme.accent : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .onAppear {
                    filterPreviewService.updateSourceFrame(from: player)
                }
            }

            InspectorCard(title: "Intensity") {
                Slider(value: $draftWorkspace.file.styleSettings.lookIntensity, in: 0...1)
                    .tint(AppTheme.accent)
                InspectorMetric(label: "Look Amount", value: "\(Int(draftWorkspace.file.styleSettings.lookIntensity * 100))%")
            }

            InspectorCard(title: "Color Correction") {
                colorSlider(label: "Brightness", value: $draftWorkspace.file.styleSettings.colorCorrection.brightness, range: -1...1, tint: AppTheme.importAccent)
                colorSlider(label: "Contrast", value: $draftWorkspace.file.styleSettings.colorCorrection.contrast, range: 0...2, tint: AppTheme.accent)
                colorSlider(label: "Saturation", value: $draftWorkspace.file.styleSettings.colorCorrection.saturation, range: 0...2, tint: Color(red: 0.82, green: 0.28, blue: 0.95))
                colorSlider(label: "Temperature", value: $draftWorkspace.file.styleSettings.colorCorrection.temperature, range: 2000...10000, tint: AppTheme.recordAccent)
                colorSlider(label: "Highlights", value: $draftWorkspace.file.styleSettings.colorCorrection.highlights, range: -1...1, tint: .white)
                colorSlider(label: "Shadows", value: $draftWorkspace.file.styleSettings.colorCorrection.shadows, range: -1...1, tint: .gray)
                colorSlider(label: "Vibrance", value: $draftWorkspace.file.styleSettings.colorCorrection.vibrance, range: -1...1, tint: AppTheme.openAccent)

                Button("Reset Color") {
                    draftWorkspace.file.styleSettings.colorCorrection = ColorCorrection()
                    persistStyleAndRefreshPreview()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func colorSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Text("\(value.wrappedValue, format: .number.precision(.fractionLength(1)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
            }
            Slider(value: value, in: range)
                .tint(tint)
                .onChange(of: value.wrappedValue) { _, _ in
                    persistStyleAndRefreshPreview()
                }
        }
    }

    private var textInspector: some View {
        Group {
            InspectorCard(title: "Auto Captions") {
                Button {
                    Task {
                        await generateAutoCaptions()
                    }
                } label: {
                    Label(
                        captionEngine.isGenerating ? "Generating Captions..." : "Generate From Selected Clip",
                        systemImage: "captions.bubble.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(captionEngine.isGenerating || selectedClip?.lane != .video)

                Button {
                    Task {
                        await generateTimingCaptionsOnly()
                    }
                } label: {
                    Label("Generate Timing Blocks", systemImage: "waveform.path.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(captionEngine.isGenerating || selectedClip?.lane != .video)

                Text(captionEngine.statusMessage)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InspectorCard(title: "Caption Style") {
                Picker("Caption Style", selection: $draftWorkspace.file.styleSettings.captionStyle) {
                    ForEach(CaptionLook.allCases, id: \.self) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 10) {
                    captionToken("Hook", tint: AppTheme.recordAccent)
                    captionToken("Clean", tint: AppTheme.accent)
                    captionToken("Bold", tint: AppTheme.importAccent)
                }
            }

            InspectorCard(title: "Overlay Actions") {
                clipActionButton("Add Title") {
                    addTextOverlay(style: .title, position: .top)
                }
                clipActionButton("Add Subtitle") {
                    addTextOverlay(style: .subtitle, position: .center)
                }
                clipActionButton("Add Caption Block") {
                    addTextOverlay(style: .caption, position: .bottom)
                }
            }

            InspectorCard(title: "Text Timeline") {
                if draftWorkspace.file.textOverlays.isEmpty {
                    Text("No text overlays yet. Add one above and it will appear over the current preview clip.")
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 8) {
                        ForEach(draftWorkspace.file.textOverlays) { overlay in
                            Button {
                                selectedTextOverlayID = overlay.id
                            } label: {
                                TextOverlayRow(
                                    overlay: overlay,
                                    isSelected: overlay.id == selectedTextOverlayID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let overlay = selectedTextOverlay {
                InspectorCard(title: "Selected Overlay") {
                    TextField(
                        "Overlay text",
                        text: Binding(
                            get: { selectedTextOverlay?.text ?? "" },
                            set: { newValue in
                                updateSelectedTextOverlay(text: newValue)
                            }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)

                    Picker("Position", selection: Binding(
                        get: { selectedTextOverlay?.position ?? .bottom },
                        set: { newValue in
                            updateSelectedTextOverlay(position: newValue)
                        }
                    )) {
                        ForEach(TextOverlayPosition.allCases, id: \.self) { position in
                            Text(position.rawValue.capitalized).tag(position)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Style", selection: Binding(
                        get: { selectedTextOverlay?.style ?? .caption },
                        set: { newValue in
                            updateSelectedTextOverlay(style: newValue)
                        }
                    )) {
                        ForEach(TextOverlayStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack {
                        Button("-0.5s Start") {
                            updateSelectedTextOverlay(startTime: max(0, overlay.startTime - 0.5))
                        }
                        .buttonStyle(.bordered)

                        Button("+0.5s End") {
                            updateSelectedTextOverlay(endTime: overlay.endTime + 0.5)
                        }
                        .buttonStyle(.bordered)
                    }

                    clipActionButton("Delete Overlay", role: .destructive) {
                        removeSelectedTextOverlay()
                    }
                }
            }
        }
    }

    private var outputInspector: some View {
        Group {
            InspectorCard(title: "Platform Presets") {
                VStack(spacing: 8) {
                    ForEach(PlatformPreset.allCases) { preset in
                        Button {
                            draftWorkspace.file.exportPreset = preset.exportPreset
                            persistWorkspace()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: preset.iconName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                    Text("\(preset.exportPreset.width)×\(preset.exportPreset.height) • \(preset.exportPreset.frameRate)fps")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer()
                                if draftWorkspace.file.exportPreset == preset.exportPreset {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppTheme.accent)
                                }
                            }
                            .padding(10)
                            .background(
                                draftWorkspace.file.exportPreset == preset.exportPreset
                                    ? AppTheme.accent.opacity(0.16)
                                    : Color.white.opacity(0.03)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            InspectorCard(title: "Export Status") {
                if exportEngine.isExporting {
                    ProgressView(value: exportEngine.progress)
                        .tint(AppTheme.accent)
                    InspectorMetric(label: "Progress", value: "\(Int(exportEngine.progress * 100))%")
                } else {
                    InspectorMetric(label: "Codec", value: draftWorkspace.file.exportPreset.codec)
                    InspectorMetric(label: "Resolution", value: "\(draftWorkspace.file.exportPreset.width)×\(draftWorkspace.file.exportPreset.height)")
                }
            }

            if let lastExportURL {
                InspectorCard(title: "Last Export") {
                    InspectorMetric(label: "File", value: lastExportURL.lastPathComponent)
                    Button("Reveal In Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var sceneStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolMiniPanel(
                title: "Look",
                value: draftWorkspace.file.styleSettings.look.rawValue
            )
            toolMiniPanel(
                title: "Captions",
                value: draftWorkspace.file.styleSettings.captionStyle.rawValue
            )
            toolMiniPanel(
                title: "Intensity",
                value: "\(Int(draftWorkspace.file.styleSettings.lookIntensity * 100))%"
            )
            toolMiniPanel(
                title: "Playhead",
                value: playheadLabel
            )
        }
    }

    private var timelineRuler: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                Text("Tracks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .frame(minWidth: timelineTrackLabelWidth, maxWidth: timelineTrackLabelWidth, alignment: .leading)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.035))

                HStack(spacing: CGFloat(timelineRulerTickInterval) * timelinePointsPerSecond) {
                    let totalDuration = max(8, draftWorkspace.file.totalDuration + 4)
                    let tickCount = Int(ceil(totalDuration / timelineRulerTickInterval))
                    ForEach(0..<tickCount, id: \.self) { index in
                        let seconds = Double(index) * timelineRulerTickInterval
                        VStack(alignment: .leading, spacing: 2) {
                            Rectangle()
                                .fill(Color.white.opacity(index == 0 ? 0.55 : 0.24))
                                .frame(width: 1, height: index == 0 ? 16 : 10)
                            Text(timelineRulerLabel(seconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .frame(width: CGFloat(timelineRulerTickInterval) * timelinePointsPerSecond, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, timelinePlayheadInset)
                .padding(.top, 4)

                Rectangle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 1.5, height: 32)
                    .offset(x: playheadXInCanvas, y: 0)

                Image(systemName: "triangle.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: playheadXInCanvas - 3.5, y: 0)

                ForEach(draftWorkspace.file.markers) { marker in
                    TimelineMarkerFlag(
                        marker: marker,
                        isSelected: marker.id == selectedMarkerID,
                        onSelect: {
                            selectMarker(marker.id, seek: true)
                        },
                        onDelete: {
                            applyTimelineEdit { $0.file.removeMarker(marker.id) }
                        }
                    )
                    .offset(
                        x: timelinePlayheadInset + CGFloat(marker.time) * timelinePointsPerSecond - 5,
                        y: 0
                    )
                }
            }
            .frame(width: timelineCanvasWidth, height: 34, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubTimelineFromTimelineCanvas(x: value.location.x)
                    }
            )
        }
    }

    private var inspectorTabs: some View {
        HStack(spacing: 8) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    inspectorTab = tab
                } label: {
                    Text(tab.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(inspectorTab == tab ? .white : AppTheme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(inspectorTab == tab ? Color.white.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(AppTheme.subpanel(cornerRadius: 16))
    }

    private var bottomToolRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                toolRailButton(tab: .audio, icon: "music.note")
                toolRailButton(tab: .text, icon: "textformat")
                toolRailButton(tab: .audio, icon: "mic")
                toolRailButton(tab: .text, icon: "captions.bubble")
                toolRailButton(tab: .text, icon: "square.on.square")
                toolRailButton(tab: .style, icon: "wand.and.stars")
                Spacer()
                if selectedTimelineClips.count > 1 {
                    Text("\(selectedTimelineClips.count) clips selected")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                } else if let clip = selectedClip {
                    Text(clip.title)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                } else {
                    Text("Select a clip for quick actions")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if selectedTimelineClips.count > 1 {
                        actionChip("Delete Selected", icon: "trash", destructive: true) {
                            deleteSelectedClips()
                        }
                        actionChip("Duplicate Selected", icon: "plus.square.on.square") {
                            duplicateSelectedClips()
                        }
                        actionChip("Move Selected Left", icon: "arrow.left.to.line.compact") {
                            moveSelectedClips(.left)
                        }
                        actionChip("Move Selected Right", icon: "arrow.right.to.line.compact") {
                            moveSelectedClips(.right)
                        }
                        actionChip("Mute / Unmute Selected", icon: "speaker.slash.fill") {
                            toggleMuteSelectedClips()
                        }
                        actionChip("1.0× Selected", icon: "speedometer") {
                            setSpeedForSelectedClips(1.0)
                        }
                        actionChip("Clear Selection", icon: "xmark.circle") {
                            clearClipSelection()
                        }
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 1, height: 24)
                    }
                    if let clip = selectedClip {
                        actionChip("Split", icon: "scissors") {
                            splitClipAtPlayhead(clip)
                        }
                        actionChip("Slip -0.25s", icon: "arrow.left.arrow.right") {
                            slipClipContent(clip, by: -0.25)
                        }
                        actionChip("Slip +0.25s", icon: "arrow.left.arrow.right") {
                            slipClipContent(clip, by: 0.25)
                        }
                        actionChip("0.5×", icon: "speedometer") {
                            guard ensureClipEditable(clip, action: "changing speed") else { return }
                            applyTimelineEdit { $0.file.setClipSpeed(clip.id, speed: 0.5) }
                        }
                        actionChip("1.0×", icon: "speedometer") {
                            guard ensureClipEditable(clip, action: "changing speed") else { return }
                            applyTimelineEdit { $0.file.setClipSpeed(clip.id, speed: 1.0) }
                        }
                        actionChip("1.5×", icon: "speedometer") {
                            guard ensureClipEditable(clip, action: "changing speed") else { return }
                            applyTimelineEdit { $0.file.setClipSpeed(clip.id, speed: 1.5) }
                        }
                        actionChip("2.0×", icon: "speedometer") {
                            guard ensureClipEditable(clip, action: "changing speed") else { return }
                            applyTimelineEdit { $0.file.setClipSpeed(clip.id, speed: 2.0) }
                        }
                        actionChip("Duplicate", icon: "plus.square.on.square") {
                            guard ensureClipEditable(clip, action: "duplicating") else { return }
                            applyTimelineEdit { $0.file.duplicateClip(clip.id) }
                        }
                        actionChip("Extract Audio", icon: "waveform") {
                            extractAudio(from: clip)
                        }
                        actionChip("Reverse", icon: "backward") {
                            Task { await reverseClipMedia(clip) }
                        }
                        actionChip("Cut Silences", icon: "waveform.and.magnifyingglass") {
                            Task { await cutSilences(from: clip) }
                        }
                        actionChip("Freeze 0.5s", icon: "snowflake") {
                            Task { await insertFreezeFrame(from: clip) }
                        }
                        if clip.lane == .video {
                            Menu {
                                ForEach(videoAssetsForReplacement(clipID: clip.id), id: \.id) { asset in
                                    Button(asset.originalName) {
                                        Task { await replaceClipAsset(clip, with: asset) }
                                    }
                                }
                            } label: {
                                actionChipLabel("Replace", icon: "arrow.triangle.2.circlepath")
                            }
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel("Replace selected clip media")
                        }
                        actionChip("Delete", icon: "trash", destructive: true) {
                            guard ensureClipEditable(clip, action: "deleting") else { return }
                            deleteClipWithCurrentEditMode(clip.id)
                        }
                    }

                    actionChip("Add Media", icon: "plus") {
                        appModel.importAssetsIntoCurrentProject()
                    }
                    actionChip("Record", icon: "record.circle") {
                        appModel.moveToRecording()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.panel(cornerRadius: 24))
    }

    private var exportProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Exporting Reel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(exportEngine.phase.isEmpty ? "Preparing..." : exportEngine.phase)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)

                ProgressView(value: exportEngine.progress)
                    .tint(AppTheme.accent)

                Text("\(Int((exportEngine.progress * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                HStack {
                    Spacer()
                    Button(isCancellingExport ? "Cancelling…" : "Cancel Export") {
                        isCancellingExport = true
                        exportEngine.cancelExport()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.recordAccent)
                    .accessibilityLabel("Cancel current export")
                    .disabled(isCancellingExport || exportEngine.phase == "Cancelled")
                }
            }
            .padding(18)
            .frame(width: 360)
            .background(AppTheme.panel(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        }
        .transition(.opacity)
    }

    private func actionChip(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionChipLabel(title, icon: icon, destructive: destructive)
        }
        .buttonStyle(.plain)
    }

    private func actionChipLabel(_ title: String, icon: String, destructive: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(destructive ? AppTheme.recordAccent : .white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(destructive ? AppTheme.recordAccent.opacity(0.18) : Color.white.opacity(0.08))
        )
    }

    private var selectedClip: TimelineClip? {
        draftWorkspace.file.clip(for: selectedClipID)
    }

    private var audioTimelineClips: [TimelineClip] {
        draftWorkspace.file.timelineClips
            .filter { $0.lane == .music || $0.lane == .voiceover || ($0.lane == .video && draftWorkspace.file.asset(for: $0.assetID)?.type == .video) }
            .sorted { lhs, rhs in
                if lhs.lane == rhs.lane {
                    return lhs.startTime < rhs.startTime
                }
                return lhs.lane.rawValue < rhs.lane.rawValue
            }
    }

    @ViewBuilder
    private var previewCanvas: some View {
        if selectedClip != nil {
            ZStack {
                PlayerPreviewView(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))

                if isPreparingPreview {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Preparing preview")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.18))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        SectionChip(title: draftWorkspace.file.styleSettings.look.rawValue, accent: AppTheme.accent)
                        SectionChip(title: draftWorkspace.file.styleSettings.captionStyle.rawValue, accent: AppTheme.recordAccent)
                    }

                    previewTextOverlayLayer
                }
                .padding(16)
            }
            .overlay(alignment: .bottomTrailing) {
                if let clip = selectedClip {
                    Text("Source \(clip.sourceStart.formatted(.number.precision(.fractionLength(1))))s")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.52))
                        .clipShape(Capsule())
                        .padding(16)
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.black, Color.black.opacity(0.82), AppTheme.accent.opacity(0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(.white.opacity(0.86))
                        Text("Import or record a clip to activate the preview stage.")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
        }
    }

    private func captionToken(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tint.opacity(0.24))
            .clipShape(Capsule())
    }

    private func audioLevelMeter(level: Double, tint: Color) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<12, id: \.self) { index in
                let threshold = Double(index + 1) / 12
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(level >= threshold ? tint : Color.white.opacity(0.08))
                    .frame(width: 8, height: CGFloat(18 + (index * 4)))
            }
        }
        .padding(.vertical, 6)
    }

    private func toolMiniPanel(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.subpanel())
    }

    private func compactMetricChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func toolbarButton(
        title: String,
        systemImage: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func timelineTransportButton(
        title: String,
        systemImage: String,
        prominent: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(prominent ? Color(red: 0.24, green: 0.42, blue: 1.0) : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func playheadInfoPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func trackBadge(_ track: ProjectTrack, isCollapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(trackTint(for: track.kind).opacity(0.16))
                    Image(systemName: track.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(trackTint(for: track.kind))
                }
                .frame(width: 22, height: 22)

                Text(track.displayName)
                    .font((isCollapsed ? Font.caption2 : Font.caption).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                Text(shortTrackCode(for: track.kind))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(trackTint(for: track.kind))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(trackTint(for: track.kind).opacity(0.16))
                    .clipShape(Capsule())
                    .fixedSize()

                trackControlButton(
                    icon: isCollapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                    active: isCollapsed,
                    label: isCollapsed ? "Expand track" : "Collapse track"
                ) {
                    if isCollapsed {
                        collapsedTrackIDs.remove(track.id)
                    } else {
                        collapsedTrackIDs.insert(track.id)
                    }
                }
            }

            if !isCollapsed {
                HStack(spacing: 4) {
                    trackControlButton(
                        icon: lockedTrackIDs.contains(track.id) ? "lock.fill" : "lock.open",
                        active: lockedTrackIDs.contains(track.id),
                        label: lockedTrackIDs.contains(track.id) ? "Unlock track" : "Lock track"
                    ) {
                        if lockedTrackIDs.contains(track.id) {
                            lockedTrackIDs.remove(track.id)
                        } else {
                            lockedTrackIDs.insert(track.id)
                        }
                    }

                    trackControlButton(
                        icon: mutedTrackIDs.contains(track.id) ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        active: mutedTrackIDs.contains(track.id),
                        label: mutedTrackIDs.contains(track.id) ? "Unmute track" : "Mute track"
                    ) {
                        if mutedTrackIDs.contains(track.id) {
                            mutedTrackIDs.remove(track.id)
                        } else {
                            mutedTrackIDs.insert(track.id)
                        }
                    }

                    trackControlButton(
                        icon: soloTrackIDs.contains(track.id) ? "s.circle.fill" : "s.circle",
                        active: soloTrackIDs.contains(track.id),
                        label: soloTrackIDs.contains(track.id) ? "Disable solo" : "Solo track"
                    ) {
                        if soloTrackIDs.contains(track.id) {
                            soloTrackIDs.remove(track.id)
                        } else {
                            soloTrackIDs.insert(track.id)
                        }
                    }
                }
            }
        }
        .padding(.leading, 3)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func shortTrackCode(for kind: TrackKind) -> String {
        switch kind {
        case .video: return "VID"
        case .music: return "MUS"
        case .voiceover: return "VO"
        case .captions: return "CAP"
        }
    }

    private func trackControlButton(icon: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(active ? .white : AppTheme.secondaryText)
                .frame(width: 18, height: 18)
                .background(active ? AppTheme.accent.opacity(0.26) : Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func toolRailButton(tab: InspectorTab, icon: String) -> some View {
        Button {
            inspectorTab = tab
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(toolRailLabel(for: icon))
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(inspectorTab == tab ? .white : AppTheme.secondaryText)
            .frame(width: 68, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(inspectorTab == tab ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(toolRailLabel(for: icon)) tools")
    }

    private func toolRailLabel(for icon: String) -> String {
        switch icon {
        case "music.note":
            return "Audio"
        case "textformat":
            return "Text"
        case "mic":
            return "Voice"
        case "captions.bubble":
            return "Captions"
        case "square.on.square":
            return "Overlay"
        case "wand.and.stars":
            return "Style"
        default:
            return "Tool"
        }
    }

    private func trackTint(for kind: TrackKind) -> Color {
        switch kind {
        case .video:
            return AppTheme.importAccent
        case .music:
            return Color(red: 0.82, green: 0.28, blue: 0.95)
        case .voiceover:
            return Color(red: 1.0, green: 0.34, blue: 0.68)
        case .captions:
            return AppTheme.accent
        }
    }

    private func icon(for type: AssetType) -> String {
        switch type {
        case .video:
            return "film"
        case .audio:
            return "waveform"
        case .image:
            return "photo"
        case .unknown:
            return "questionmark.square.dashed"
        }
    }

    private func clipActionButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(role == .destructive ? AppTheme.recordAccent.opacity(0.16) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    @discardableResult
    private func applyTimelineEdit<Result>(_ mutate: (inout ProjectWorkspace) -> Result) -> Result {
        // Capture snapshot for undo (Task 5.1)
        editorEnv.pushUndo(draftWorkspace)
        var updated = draftWorkspace
        let result = mutate(&updated)
        draftWorkspace = updated
        syncSelectionIfNeeded()
        appModel.saveCurrentWorkspace(updated)
        updatePlayer()
        return result
    }

    private func splitSelectedClipAtPlayhead() {
        guard let clip = selectedClip else { return }
        splitClipAtPlayhead(clip)
    }

    private func splitClipAtPlayhead(_ clip: TimelineClip) {
        guard ensureClipEditable(clip, action: "splitting") else { return }
        let splitTime = splitPoint(for: clip)
        let newClipID = applyTimelineEdit { workspace in
            workspace.file.splitClip(clip.id, at: splitTime, ripple: rippleEditsEnabled)
        }
        if let newClipID {
            selectedClipID = newClipID
            selectedClipIDs = [newClipID]
            if let newClip = draftWorkspace.file.clip(for: newClipID) {
                selectedAssetID = newClip.assetID
            }
            if clip.lane == .video {
                scrubTimeline(to: splitTime)
            }
        } else {
            appModel.errorMessage = "Split needs at least 0.25s on both sides of the playhead."
        }
    }

    private func splitPoint(for clip: TimelineClip) -> Double {
        let minimumSegmentDuration = 0.25
        let minSplit = clip.startTime + minimumSegmentDuration
        let maxSplit = clip.startTime + clip.duration - minimumSegmentDuration
        let midpoint = clip.startTime + (clip.duration / 2)

        guard maxSplit > minSplit else { return midpoint }
        return min(max(currentTimelineTime, minSplit), maxSplit)
    }

    private var selectedTimelineClips: [TimelineClip] {
        let ids = selectedClipIDs
        return draftWorkspace.file.timelineClips
            .filter { ids.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.trackID == rhs.trackID {
                    return lhs.startTime < rhs.startTime
                }
                return lhs.lane.rawValue < rhs.lane.rawValue
            }
    }

    private var isMarqueeSelectionModifierActive: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    private func updateTrackMarqueeSelection(track: ProjectTrack, startX: CGFloat, currentX: CGFloat) {
        let lowerX = max(0, min(startX, currentX))
        let upperX = max(0, max(startX, currentX))
        marqueeTrackID = track.id
        marqueeXRange = lowerX...upperX

        let contentLower = max(0, lowerX - timelinePlayheadInset)
        let contentUpper = max(0, upperX - timelinePlayheadInset)
        let startTime = max(0, Double(contentLower / max(timelinePointsPerSecond, 1)))
        let endTime = max(startTime, Double(contentUpper / max(timelinePointsPerSecond, 1)))

        let clipsInRange = draftWorkspace.file.clips(for: track.id).filter { clip in
            let clipStart = clip.startTime
            let clipEnd = clip.startTime + clip.duration
            return clipEnd >= startTime && clipStart <= endTime
        }

        let additive = NSEvent.modifierFlags.contains(.command)
        if additive {
            selectedClipIDs.formUnion(clipsInRange.map(\.id))
        } else {
            selectedClipIDs = Set(clipsInRange.map(\.id))
        }

        if let primary = clipsInRange.first {
            selectedClipID = primary.id
            selectedAssetID = primary.assetID
        } else if !additive {
            selectedClipID = nil
            selectedAssetID = nil
        }
    }

    private func clipEditable(_ clip: TimelineClip) -> Bool {
        !lockedTrackIDs.contains(clip.trackID)
    }

    private func ensureClipEditable(_ clip: TimelineClip, action: String) -> Bool {
        guard clipEditable(clip) else {
            appModel.errorMessage = "Track is locked. Unlock it before \(action)."
            return false
        }
        return true
    }

    private func ensureSelectionEditable(action: String) -> Bool {
        let lockedSelectedCount = selectedTimelineClips.filter { lockedTrackIDs.contains($0.trackID) }.count
        guard lockedSelectedCount == 0 else {
            appModel.errorMessage = "Some selected clips are on locked tracks. Unlock them before \(action)."
            return false
        }
        return true
    }

    private func selectClip(_ clip: TimelineClip, additive: Bool) {
        if additive {
            if selectedClipIDs.contains(clip.id) {
                selectedClipIDs.remove(clip.id)
                if selectedClipIDs.isEmpty {
                    selectedClipIDs = [clip.id]
                }
            } else {
                selectedClipIDs.insert(clip.id)
            }
        } else {
            selectedClipIDs = [clip.id]
        }
        selectedClipID = clip.id
        selectedAssetID = clip.assetID
    }

    private func selectClipFromTimelineTap(_ clip: TimelineClip) {
        let flags = NSEvent.modifierFlags
        let additive = flags.contains(.command) || flags.contains(.shift)
        selectClip(clip, additive: additive)
    }

    private func clearClipSelection() {
        if let selectedClipID {
            selectedClipIDs = [selectedClipID]
        } else if let first = draftWorkspace.file.timelineClips.first?.id {
            selectedClipID = first
            selectedClipIDs = [first]
            if let clip = draftWorkspace.file.clip(for: first) {
                selectedAssetID = clip.assetID
            }
        } else {
            selectedClipIDs.removeAll()
            selectedClipID = nil
        }
    }

    private func deleteSelectedClips() {
        let clipIDs = selectedTimelineClips.map(\.id)
        guard !clipIDs.isEmpty else { return }
        guard ensureSelectionEditable(action: "deleting clips") else { return }
        applyTimelineEdit { workspace in
            for clipID in clipIDs {
                workspace.file.deleteClip(clipID, ripple: rippleEditsEnabled)
            }
        }
        selectedClipID = draftWorkspace.file.timelineClips.first?.id
        selectedClipIDs = selectedClipID.map { [$0] } ?? []
    }

    private func deleteClipWithCurrentEditMode(_ clipID: UUID) {
        applyTimelineEdit { workspace in
            workspace.file.deleteClip(clipID, ripple: rippleEditsEnabled)
        }
        selectedClipID = draftWorkspace.file.timelineClips.first?.id
        selectedClipIDs = selectedClipID.map { [$0] } ?? []
    }

    private func trimClipStartByEditMode(_ clip: TimelineClip, delta: Double) {
        applyTimelineEdit {
            $0.file.trimClipStart(clip.id, delta: delta, ripple: rippleEditsEnabled)
        }
    }

    private func trimClipEndByEditMode(_ clip: TimelineClip, delta: Double) {
        applyTimelineEdit {
            $0.file.trimClipEnd(clip.id, delta: delta, ripple: rippleEditsEnabled)
        }
    }

    private func duplicateSelectedClips() {
        let clipIDs = selectedTimelineClips.map(\.id)
        guard !clipIDs.isEmpty else { return }
        guard ensureSelectionEditable(action: "duplicating clips") else { return }
        applyTimelineEdit { workspace in
            for clipID in clipIDs {
                workspace.file.duplicateClip(clipID)
            }
        }
    }

    private func setSpeedForSelectedClips(_ speed: Double) {
        let clipIDs = selectedTimelineClips.map(\.id)
        guard !clipIDs.isEmpty else { return }
        guard ensureSelectionEditable(action: "changing speed") else { return }
        applyTimelineEdit { workspace in
            for clipID in clipIDs {
                workspace.file.setClipSpeed(clipID, speed: speed)
            }
        }
    }

    private func toggleMuteSelectedClips() {
        let clips = selectedTimelineClips
        guard !clips.isEmpty else { return }
        guard ensureSelectionEditable(action: "toggling mute") else { return }
        let shouldMute = clips.contains { !$0.isMuted }
        applyTimelineEdit { workspace in
            for clip in clips {
                if let current = workspace.file.clip(for: clip.id), current.isMuted != shouldMute {
                    workspace.file.toggleClipMute(clip.id)
                }
            }
        }
    }

    private func moveSelectedClips(_ direction: MoveDirection) {
        let clips = selectedTimelineClips
        guard !clips.isEmpty else { return }
        guard ensureSelectionEditable(action: "moving clips") else { return }

        let grouped = Dictionary(grouping: clips, by: \.trackID)
        applyTimelineEdit { workspace in
            for (_, trackClips) in grouped {
                let ordered = trackClips.sorted { $0.startTime < $1.startTime }
                let orderedIDs = direction == .left
                    ? ordered.map(\.id)
                    : ordered.reversed().map(\.id)
                for clipID in orderedIDs {
                    workspace.file.moveClip(clipID, direction: direction)
                }
            }
        }
    }

    func persistWorkspace() {
        appModel.saveCurrentWorkspace(draftWorkspace)
    }

    // MARK: - Drag-and-Drop from Finder (Task 4.1)
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { await handleDroppedFiles(providers: providers) }
        return true
    }

    private func handleDroppedFiles(providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = await resolveFileURL(from: provider) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        do {
            let updated = try appModel.store.ingestAssets(from: urls, into: draftWorkspace)
            draftWorkspace = updated
            syncSelectionIfNeeded()
            updatePlayer()
            appModel.saveCurrentWorkspace(updated)
        } catch {
            // Surface the error via appModel
        }
    }

    private func resolveFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func syncSelectionIfNeeded() {
        let validClipIDs = Set(draftWorkspace.file.timelineClips.map(\.id))
        selectedClipIDs = selectedClipIDs.intersection(validClipIDs)

        if selectedClipID == nil {
            selectedClipID = draftWorkspace.file.timelineClips.first(where: { $0.lane == .video })?.id
        }
        if selectedAssetID == nil {
            selectedAssetID = draftWorkspace.file.assets.first(where: { $0.type == .video })?.id
        }
        if draftWorkspace.file.clip(for: selectedClipID) == nil {
            selectedClipID = draftWorkspace.file.timelineClips.first(where: { $0.lane == .video })?.id
        }
        if let selectedClipID {
            selectedClipIDs.insert(selectedClipID)
        } else if let first = draftWorkspace.file.timelineClips.first?.id {
            selectedClipID = first
            selectedClipIDs = [first]
        }
        if let selectedClip, draftWorkspace.file.asset(for: selectedClip.assetID) != nil {
            selectedAssetID = selectedClip.assetID
        } else if draftWorkspace.file.asset(for: selectedAssetID ?? UUID()) == nil {
            selectedAssetID = draftWorkspace.file.assets.first(where: { $0.type == .video })?.id
        }
        if selectedTextOverlayID == nil {
            selectedTextOverlayID = draftWorkspace.file.textOverlays.first?.id
        }
        if draftWorkspace.file.textOverlay(for: selectedTextOverlayID) == nil {
            selectedTextOverlayID = draftWorkspace.file.textOverlays.first?.id
        }
        if selectedMarkerID == nil {
            selectedMarkerID = draftWorkspace.file.markers.first?.id
        }
        if draftWorkspace.file.markers.first(where: { $0.id == selectedMarkerID }) == nil {
            selectedMarkerID = draftWorkspace.file.markers.first?.id
        }
    }

    private func applyPendingEditorSelection(assetID: UUID) {
        guard draftWorkspace.file.asset(for: assetID) != nil else { return }
        selectedAssetID = assetID
        if let clip = draftWorkspace.file.timelineClips.first(where: { $0.assetID == assetID }) {
            selectedClipID = clip.id
            selectedClipIDs = [clip.id]
            scrubTimeline(to: clip.startTime)
        }
    }

    private func updatePlayer() {
        if isUpdatingPlayer {
            needsPlayerRefresh = true
            return
        }
        isUpdatingPlayer = true
        defer {
            isUpdatingPlayer = false
            if needsPlayerRefresh {
                needsPlayerRefresh = false
                updatePlayer()
            }
        }

        isPreparingPreview = true
        let shouldResumePlayback = isPlaying
        endHandoffClipID = nil

        guard
            let clip = selectedClip,
            let asset = draftWorkspace.file.asset(for: clip.assetID),
            asset.type == .video
        else {
            player.replaceCurrentItem(with: nil)
            playbackTime = 0
            isPlaying = false
            isPreparingPreview = false
            return
        }

        let url = draftWorkspace.summary.projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(asset.fileName)

        guard FileManager.default.fileExists(atPath: url.path) else {
            player.replaceCurrentItem(with: nil)
            playbackTime = 0
            isPlaying = false
            isPreparingPreview = false
            return
        }

        player.pause()
        player.automaticallyWaitsToMinimizeStalling = false

        let assetSource = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: assetSource)
        item.videoComposition = LookPipeline.makePreviewComposition(
            for: assetSource,
            style: draftWorkspace.file.styleSettings
        )
        applyPreviewAudioMix(to: item, for: clip)
        item.forwardPlaybackEndTime = CMTime(
            seconds: clip.sourceStart + clip.duration,
            preferredTimescale: 600
        )
        player.replaceCurrentItem(with: item)
        installPlaybackDidEndObserver(for: item, sourceClipID: clip.id)
        player.actionAtItemEnd = .pause
        isPlaying = false
        if let pendingScrubTimelineTime,
           let scrubClip = selectedClip {
            let relative = max(0, min(scrubClip.duration, pendingScrubTimelineTime - scrubClip.startTime))
            playbackTime = relative
            let target = CMTime(seconds: scrubClip.sourceStart + relative, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            self.pendingScrubTimelineTime = nil
        } else {
            playbackTime = 0
            seekToSelectedClipStart(playIfNeeded: false)
        }
        if shouldResumePlayback {
            player.play()
            isPlaying = true
        }
        isPreparingPreview = false
    }

    private func refreshPreviewAudioMix() {
        guard let clip = selectedClip, let item = player.currentItem else { return }
        applyPreviewAudioMix(to: item, for: clip)
    }

    private func applyPreviewAudioMix(to item: AVPlayerItem, for clip: TimelineClip) {
        let gain = effectivePreviewVolume(for: clip)
        player.isMuted = gain <= 0.0001
        previewAudioMixRevision &+= 1
        let revision = previewAudioMixRevision

        Task { @MainActor in
            let tracks = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
            guard revision == previewAudioMixRevision, player.currentItem === item else { return }
            guard !tracks.isEmpty else {
                item.audioMix = nil
                return
            }

            let params = tracks.map { track -> AVMutableAudioMixInputParameters in
                let input = AVMutableAudioMixInputParameters(track: track)
                input.setVolume(gain, at: .zero)
                return input
            }

            let mix = AVMutableAudioMix()
            mix.inputParameters = params
            item.audioMix = mix
        }
    }

    private func effectivePreviewVolume(for clip: TimelineClip) -> Float {
        if clip.isMuted || clip.volume <= 0 {
            return 0
        }
        if mutedTrackIDs.contains(clip.trackID) {
            return 0
        }
        if !soloTrackIDs.isEmpty, !soloTrackIDs.contains(clip.trackID) {
            return 0
        }
        return Float(min(max(clip.volume, 0), 2.0))
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func seekToSelectedClipStart(playIfNeeded: Bool) {
        guard let clip = selectedClip else { return }

        let target = CMTime(seconds: clip.sourceStart, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if playIfNeeded {
            player.play()
        }
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserverToken == nil else { return }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                guard !isPreparingPreview else { return }
                guard let clip = selectedClip else {
                    playbackTime = 0
                    return
                }

                let relative = max(0, time.seconds - clip.sourceStart)
                playbackTime = min(relative, clip.duration)

                let endThreshold = max(0.02, frameDuration * 0.5)
                if relative >= (clip.duration - endThreshold) {
                    guard endHandoffClipID != clip.id else { return }
                    endHandoffClipID = clip.id

                    if isPlaying,
                       let nextClip = nextVideoClip(afterTimelineTime: clip.startTime + clip.duration, excluding: clip.id) {
                        pendingScrubTimelineTime = nextClip.startTime
                        selectedClipID = nextClip.id
                        selectedClipIDs = [nextClip.id]
                        selectedAssetID = nextClip.assetID
                    } else {
                        player.pause()
                        isPlaying = false
                    }
                } else if endHandoffClipID == clip.id {
                    endHandoffClipID = nil
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    private func installPlaybackDidEndObserver(for item: AVPlayerItem, sourceClipID: UUID) {
        removePlaybackDidEndObserver()
        playbackDidEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard isPlaying else {
                    player.pause()
                    isPlaying = false
                    return
                }

                // Ignore stale end events when a previous clip has already handed off.
                guard selectedClipID == sourceClipID else { return }
                guard let clip = draftWorkspace.file.clip(for: sourceClipID) else {
                    player.pause()
                    isPlaying = false
                    return
                }

                endHandoffClipID = sourceClipID
                if let nextClip = nextVideoClip(afterTimelineTime: clip.startTime + clip.duration, excluding: sourceClipID) {
                    pendingScrubTimelineTime = nextClip.startTime
                    selectedClipID = nextClip.id
                    selectedClipIDs = [nextClip.id]
                    selectedAssetID = nextClip.assetID
                } else {
                    player.pause()
                    isPlaying = false
                }
            }
        }
    }

    private func removePlaybackDidEndObserver() {
        if let observer = playbackDidEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackDidEndObserver = nil
        }
    }

    private func persistStyleAndRefreshPreview() {
        appModel.saveCurrentWorkspace(draftWorkspace)
        updatePlayer()
    }


    private func startExportFlow() {
        guard !exportEngine.isExporting else { return }
        exportFailureMessage = nil
        isCancellingExport = false
        Task { await exportCurrentProject() }
    }

    private func exportCurrentProject() async {
        do {
            let url = try await exportEngine.export(workspace: draftWorkspace)
            lastExportURL = url
            isCancellingExport = false
        } catch {
            isCancellingExport = false
            if case ExportEngineError.cancelled = error {
                return
            }
            exportFailureMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var exportFailureAlertBinding: Binding<Bool> {
        Binding(
            get: { exportFailureMessage != nil },
            set: { newValue in
                if !newValue {
                    exportFailureMessage = nil
                }
            }
        )
    }

    private var playheadLabel: String {
        guard selectedClip != nil else { return "0.0s" }
        return "\(currentTimelineTime.formatted(.number.precision(.fractionLength(1))))s / \(draftWorkspace.file.totalDuration.formatted(.number.precision(.fractionLength(1))))s"
    }

    private var selectedTextOverlay: ProjectTextOverlay? {
        draftWorkspace.file.textOverlay(for: selectedTextOverlayID)
    }

    private var selectedMarker: TimelineMarker? {
        draftWorkspace.file.markers.first(where: { $0.id == selectedMarkerID })
    }

    private var currentTimelineTime: Double {
        guard let clip = selectedClip else { return playbackTime }
        return clip.startTime + playbackTime
    }

    private var playheadXInCanvas: CGFloat {
        timelinePlayheadInset + CGFloat(currentTimelineTime) * timelinePointsPerSecond
    }

    private var timelineCanvasWidth: CGFloat {
        max(960, timelinePlayheadInset + CGFloat(draftWorkspace.file.totalDuration + 2) * timelinePointsPerSecond + 96)
    }

    // MARK: - Timeline Zoom

    private func adjustZoom(by delta: CGFloat) {
        timelineZoom = max(Self.minZoom, min(Self.maxZoom, timelineZoom + delta))
    }

    private func fitTimelineToView() {
        let duration = max(1.0, draftWorkspace.file.totalDuration)
        let visibleCanvasWidth = max(280, centerViewportWidth - timelineTrackLabelWidth - 120)
        let target = visibleCanvasWidth / (CGFloat(duration) * baseTimelinePointsPerSecond)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            timelineZoom = max(Self.minZoom, min(Self.maxZoom, target))
        }
    }

    private func applyLayoutPreset(_ preset: EditorLayoutPreset, animated: Bool = true) {
        let update = {
            switch preset {
            case .balanced:
                leftRailWidth = 200
                inspectorWidth = 300
                previewHeightRatio = 0.64
                if !editorEnv.isInspectorVisible {
                    editorEnv.isInspectorVisible = true
                }
            case .preview:
                leftRailWidth = 184
                inspectorWidth = 280
                previewHeightRatio = 0.74
                if !editorEnv.isInspectorVisible {
                    editorEnv.isInspectorVisible = true
                }
            case .precision:
                leftRailWidth = 176
                inspectorWidth = 340
                previewHeightRatio = 0.5
                if !editorEnv.isInspectorVisible {
                    editorEnv.isInspectorVisible = true
                }
            case .custom:
                break
            }
            layoutPreset = preset
        }

        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9), update)
        } else {
            update()
        }
    }

    private var timelineRulerTickInterval: Double {
        let effectivePPS = baseTimelinePointsPerSecond * timelineZoom
        if effectivePPS > 150 { return 0.5 }
        if effectivePPS > 80 { return 1 }
        if effectivePPS > 30 { return 2 }
        if effectivePPS > 15 { return 5 }
        return 10
    }

    private func trackLaneBackground(for kind: TrackKind) -> Color {
        switch kind {
        case .video:
            return Color.white.opacity(0.04)
        case .music:
            return Color(red: 0.74, green: 0.24, blue: 0.94).opacity(0.10)
        case .voiceover:
            return Color(red: 1.0, green: 0.34, blue: 0.68).opacity(0.08)
        case .captions:
            return AppTheme.accent.opacity(0.09)
        }
    }

    private func nudgeTimeline(by seconds: Double) {
        scrubTimeline(to: currentTimelineTime + seconds)
    }

    private func stepTimelineByFrames(_ frames: Int) {
        guard frames != 0 else { return }
        scrubTimeline(to: currentTimelineTime + (Double(frames) * frameDuration))
    }

    private func shuttleTimeline(by seconds: Double) {
        scrubTimeline(to: currentTimelineTime + seconds)
    }

    private func transitionPairs(for clips: [TimelineClip]) -> [(TimelineClip, TimelineClip)] {
        guard clips.count > 1 else { return [] }
        let sorted = clips.sorted { $0.startTime < $1.startTime }
        return zip(sorted, sorted.dropFirst()).map { ($0, $1) }
    }

    private func reorderClipFromDrag(_ clip: TimelineClip, translationWidth: CGFloat) {
        guard clipEditable(clip) else { return }
        let deltaSeconds = Double(translationWidth / max(timelinePointsPerSecond, 1))
        guard abs(deltaSeconds) > 0.12 else { return }

        let trackClips = draftWorkspace.file.clips(for: clip.trackID)
        guard trackClips.count > 1,
              let currentIndex = trackClips.firstIndex(where: { $0.id == clip.id }) else { return }

        let targetTimelineTime = clip.startTime + deltaSeconds
        var targetIndex = currentIndex

        if deltaSeconds > 0 {
            while targetIndex < trackClips.count - 1 {
                let next = trackClips[targetIndex + 1]
                let crossingPoint = next.startTime + (next.duration * 0.5)
                if targetTimelineTime >= crossingPoint {
                    targetIndex += 1
                } else {
                    break
                }
            }
        } else {
            while targetIndex > 0 {
                let previous = trackClips[targetIndex - 1]
                let crossingPoint = previous.startTime + (previous.duration * 0.5)
                if targetTimelineTime <= crossingPoint {
                    targetIndex -= 1
                } else {
                    break
                }
            }
        }

        guard targetIndex != currentIndex else { return }
        applyTimelineEdit { $0.file.moveClip(clip.id, toIndex: targetIndex) }
        selectedClipID = clip.id
        selectedClipIDs = [clip.id]
        selectedAssetID = clip.assetID
    }

    private func trimClipStartFromDrag(_ clip: TimelineClip, deltaSeconds: Double) {
        guard clipEditable(clip) else { return }
        let snappedDelta: Double
        if snapToFramesEnabled {
            snappedDelta = (deltaSeconds / frameDuration).rounded() * frameDuration
        } else {
            snappedDelta = deltaSeconds
        }
        guard abs(snappedDelta) > 0.01 else { return }
        trimClipStartByEditMode(clip, delta: snappedDelta)
        selectedClipID = clip.id
        selectedClipIDs = [clip.id]
    }

    private func trimClipEndFromDrag(_ clip: TimelineClip, deltaSeconds: Double) {
        guard clipEditable(clip) else { return }
        let snappedDelta: Double
        if snapToFramesEnabled {
            snappedDelta = (deltaSeconds / frameDuration).rounded() * frameDuration
        } else {
            snappedDelta = deltaSeconds
        }
        guard abs(snappedDelta) > 0.01 else { return }
        trimClipEndByEditMode(clip, delta: snappedDelta)
        selectedClipID = clip.id
        selectedClipIDs = [clip.id]
    }

    @ViewBuilder
    private func timelineClipContextMenu(for clip: TimelineClip) -> some View {
        if clip.lane == .video, let nextClip = immediateNextVideoClip(after: clip) {
            let activeTransition = draftWorkspace.file.transition(between: clip.id, and: nextClip.id)?.type ?? .none
            let activeDuration = draftWorkspace.file.transition(between: clip.id, and: nextClip.id)?.duration ?? 0.5
            Menu("Transition To Next") {
                ForEach(TransitionType.allCases, id: \.self) { transitionType in
                    Button {
                        applyTimelineEdit {
                            $0.file.setTransition(
                                from: clip.id,
                                to: nextClip.id,
                                type: transitionType,
                                duration: activeDuration
                            )
                        }
                    } label: {
                        Label(transitionType.displayName, systemImage: transitionType.iconName)
                    }
                }
            }
            Menu("Transition Duration") {
                ForEach(transitionDurationOptions, id: \.self) { duration in
                    let isSelected = abs(activeDuration - duration) < 0.001
                    Button {
                        let transitionType = activeTransition == .none ? TransitionType.crossDissolve : activeTransition
                        applyTimelineEdit {
                            $0.file.setTransition(
                                from: clip.id,
                                to: nextClip.id,
                                type: transitionType,
                                duration: duration
                            )
                        }
                    } label: {
                        HStack {
                            Text(String(format: "%.2fs", duration))
                            if isSelected && activeTransition != .none {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Text("Current: \(activeTransition.displayName)")
                .font(.caption2)
            Divider()
        }

        if selectedClipIDs.count > 1, selectedClipIDs.contains(clip.id) {
            Button("Move Selected Left") {
                moveSelectedClips(.left)
            }
            Button("Move Selected Right") {
                moveSelectedClips(.right)
            }
            Button("Duplicate Selected") {
                duplicateSelectedClips()
            }
            Button("Delete Selected", role: .destructive) {
                deleteSelectedClips()
            }
            Divider()
        }
        Button("Split At Playhead") {
            splitClipAtPlayhead(clip)
        }
        Button("Duplicate Clip") {
            guard ensureClipEditable(clip, action: "duplicating") else { return }
            applyTimelineEdit { $0.file.duplicateClip(clip.id) }
        }
        Button("Extract Audio") {
            extractAudio(from: clip)
        }
        Button("Reverse Clip") {
            Task { await reverseClipMedia(clip) }
        }
        Button("Cut Silences") {
            Task { await cutSilences(from: clip) }
        }
        Button("Freeze Frame At Playhead") {
            Task { await insertFreezeFrame(from: clip) }
        }
        if clip.lane == .video {
            Menu("Replace Media") {
                ForEach(videoAssetsForReplacement(clipID: clip.id), id: \.id) { asset in
                    Button(asset.originalName) {
                        Task { await replaceClipAsset(clip, with: asset) }
                    }
                }
            }
        }
        Divider()
        Button("Go To Clip Start") {
            selectedClipID = clip.id
            selectedClipIDs = [clip.id]
            selectedAssetID = clip.assetID
            scrubTimeline(to: clip.startTime)
        }
        Button("Go To Clip End") {
            selectedClipID = clip.id
            selectedClipIDs = [clip.id]
            selectedAssetID = clip.assetID
            scrubTimeline(to: clip.startTime + clip.duration)
        }
        Divider()
        Button("Trim Start -0.5s") {
            guard ensureClipEditable(clip, action: "trimming") else { return }
            trimClipStartByEditMode(clip, delta: 0.5)
        }
        Button("Trim End -0.5s") {
            guard ensureClipEditable(clip, action: "trimming") else { return }
            trimClipEndByEditMode(clip, delta: -0.5)
        }
        Button("Slip Content -0.25s") {
            slipClipContent(clip, by: -0.25)
        }
        Button("Slip Content +0.25s") {
            slipClipContent(clip, by: 0.25)
        }
        Divider()
        Button("Move Left") {
            guard ensureClipEditable(clip, action: "moving") else { return }
            applyTimelineEdit { $0.file.moveClip(clip.id, direction: .left) }
        }
        Button("Move Right") {
            guard ensureClipEditable(clip, action: "moving") else { return }
            applyTimelineEdit { $0.file.moveClip(clip.id, direction: .right) }
        }
        Divider()
        Button("Delete Clip", role: .destructive) {
            guard ensureClipEditable(clip, action: "deleting") else { return }
            deleteClipWithCurrentEditMode(clip.id)
        }
    }

    private func addMarkerAtPlayhead() {
        editorEnv.pushUndo(draftWorkspace)
        let id = draftWorkspace.file.addMarker(
            at: currentTimelineTime,
            label: "Marker \(draftWorkspace.file.markers.count + 1)"
        )
        selectedMarkerID = id
        persistWorkspace()
    }

    private func timelineRulerLabel(_ seconds: Double) -> String {
        if seconds == 0 { return "0s" }
        if seconds < 60 {
            return seconds.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(seconds))s"
                : String(format: "%.1fs", seconds)
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return s == 0 ? "\(m)m" : "\(m):\(String(format: "%02d", s))"
    }

    private var videoTimelineClips: [TimelineClip] {
        draftWorkspace.file.timelineClips
            .filter { clip in
                clip.lane == .video && draftWorkspace.file.asset(for: clip.assetID)?.type == .video
            }
            .sorted { $0.startTime < $1.startTime }
    }

    private func nextVideoClip(afterTimelineTime timelineTime: Double, excluding clipID: UUID?) -> TimelineClip? {
        let epsilon = max(0.001, frameDuration * 0.5)
        return videoTimelineClips.first { candidate in
            if let clipID, candidate.id == clipID {
                return false
            }
            return candidate.startTime >= (timelineTime - epsilon)
        }
    }

    private func immediateNextVideoClip(after clip: TimelineClip) -> TimelineClip? {
        let epsilon = max(0.001, frameDuration * 0.5)
        return videoTimelineClips.first { candidate in
            candidate.id != clip.id && candidate.startTime >= (clip.startTime + clip.duration - epsilon)
        }
    }

    private var transitionDurationOptions: [Double] {
        [0.15, 0.25, 0.35, 0.5, 0.75, 1.0, 1.5, 2.0]
    }

    private func scrubTimelineFromTimelineCanvas(x: CGFloat) {
        let timelineTime = max(0, Double((x - timelinePlayheadInset) / timelinePointsPerSecond))
        scrubTimeline(to: timelineTime)
    }

    private func snappedTimelineTime(_ timelineTime: Double) -> Double {
        let totalDuration = max(0, draftWorkspace.file.totalDuration)
        var value = min(max(0, timelineTime), totalDuration)

        if snapToFramesEnabled {
            value = (value / frameDuration).rounded() * frameDuration
        }

        if magneticScrubEnabled {
            let markerTimes = draftWorkspace.file.markers.map(\.time)
            let cutTimes = videoTimelineClips.flatMap { [ $0.startTime, $0.startTime + $0.duration ] }
            let candidates = markerTimes + cutTimes
            let threshold = max(frameDuration * 2, Double(10 / max(timelinePointsPerSecond, 1)))
            if let nearest = candidates.min(by: { abs($0 - value) < abs($1 - value) }),
               abs(nearest - value) <= threshold {
                value = nearest
            }
        }

        return min(max(0, value), totalDuration)
    }

    private func scrubTimeline(to timelineTime: Double) {
        let clamped = snappedTimelineTime(timelineTime)
        guard let clip = videoClip(for: clamped) else {
            playbackTime = clamped
            return
        }

        let relative = max(0, min(clip.duration, clamped - clip.startTime))

        if selectedClipID != clip.id {
            pendingScrubTimelineTime = clamped
            selectedClipID = clip.id
            selectedClipIDs = [clip.id]
            selectedAssetID = clip.assetID
            return
        }

        playbackTime = relative
        let target = CMTime(seconds: clip.sourceStart + relative, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private enum MarkerJumpDirection {
        case previous
        case next
    }

    private enum CutJumpDirection {
        case previous
        case next
    }

    private func selectMarker(_ markerID: UUID, seek: Bool) {
        guard let marker = draftWorkspace.file.markers.first(where: { $0.id == markerID }) else { return }
        selectedMarkerID = marker.id
        if seek {
            scrubTimeline(to: marker.time)
        }
    }

    private func jumpToMarker(direction: MarkerJumpDirection) {
        guard !draftWorkspace.file.markers.isEmpty else { return }
        let markers = draftWorkspace.file.markers.sorted { $0.time < $1.time }
        switch direction {
        case .next:
            if let marker = markers.first(where: { $0.time > currentTimelineTime + 0.001 }) {
                selectMarker(marker.id, seek: true)
            } else if let first = markers.first {
                selectMarker(first.id, seek: true)
            }
        case .previous:
            if let marker = markers.last(where: { $0.time < currentTimelineTime - 0.001 }) {
                selectMarker(marker.id, seek: true)
            } else if let last = markers.last {
                selectMarker(last.id, seek: true)
            }
        }
    }

    private var cutPoints: [Double] {
        let points = videoTimelineClips.flatMap { [ $0.startTime, $0.startTime + $0.duration ] }
        return Array(Set(points)).sorted()
    }

    private func jumpToCut(direction: CutJumpDirection) {
        let points = cutPoints
        guard !points.isEmpty else { return }

        switch direction {
        case .next:
            if let next = points.first(where: { $0 > currentTimelineTime + 0.001 }) {
                scrubTimeline(to: next)
            } else if let first = points.first {
                scrubTimeline(to: first)
            }
        case .previous:
            if let previous = points.last(where: { $0 < currentTimelineTime - 0.001 }) {
                scrubTimeline(to: previous)
            } else if let last = points.last {
                scrubTimeline(to: last)
            }
        }
    }

    private func videoClip(for timelineTime: Double) -> TimelineClip? {
        if let containing = videoTimelineClips.first(where: { timelineTime >= $0.startTime && timelineTime <= ($0.startTime + $0.duration) }) {
            return containing
        }

        if let prior = videoTimelineClips.last(where: { $0.startTime <= timelineTime }) {
            return prior
        }

        return videoTimelineClips.first
    }

    @ViewBuilder
    private var previewTextOverlayLayer: some View {
        let overlays = draftWorkspace.file.activeTextOverlays(at: currentTimelineTime)
        if overlays.isEmpty {
            EmptyView()
        } else {
            ZStack {
                ForEach(overlays) { overlay in
                    DraggableTextOverlay(
                        overlay: overlay,
                        isSelected: selectedTextOverlayID == overlay.id,
                        font: font(for: overlay.style),
                        onSelect: { selectedTextOverlayID = overlay.id },
                        onDragEnd: { newX, newY in
                            applyTimelineEdit {
                                $0.file.updateTextOverlay(overlay.id, offsetX: newX, offsetY: newY)
                            }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func alignment(for position: TextOverlayPosition) -> Alignment {
        switch position {
        case .top:
            return .topLeading
        case .center:
            return .center
        case .bottom:
            return .bottomLeading
        }
    }

    private func font(for style: TextOverlayStyle) -> Font {
        switch style {
        case .title:
            return .system(size: 28, weight: .bold, design: .rounded)
        case .subtitle:
            return .system(size: 20, weight: .semibold, design: .rounded)
        case .caption:
            return .system(size: 18, weight: .bold, design: .rounded)
        }
    }

    private func addTextOverlay(style: TextOverlayStyle, position: TextOverlayPosition) {
        let startTime = max(0, currentTimelineTime)
        let id = draftWorkspace.file.addTextOverlay(
            text: style == .title ? "New title" : style == .subtitle ? "Subtitle line" : "Caption block",
            startTime: startTime,
            duration: 2.5,
            position: position,
            style: style
        )
        selectedTextOverlayID = id
        persistWorkspace()
    }

    private func updateSelectedTextOverlay(
        text: String? = nil,
        startTime: Double? = nil,
        endTime: Double? = nil,
        position: TextOverlayPosition? = nil,
        style: TextOverlayStyle? = nil
    ) {
        guard let selectedTextOverlayID else { return }
        draftWorkspace.file.updateTextOverlay(
            selectedTextOverlayID,
            text: text,
            startTime: startTime,
            endTime: endTime,
            position: position,
            style: style
        )
        persistWorkspace()
    }

    private func removeSelectedTextOverlay() {
        guard let selectedTextOverlayID else { return }
        draftWorkspace.file.removeTextOverlay(selectedTextOverlayID)
        self.selectedTextOverlayID = draftWorkspace.file.textOverlays.first?.id
        persistWorkspace()
    }

    private func updateSelectedMarker(
        label: String? = nil,
        color: MarkerColor? = nil,
        note: String? = nil
    ) {
        guard let selectedMarkerID else { return }
        if let note {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                draftWorkspace.file.clearMarkerNote(selectedMarkerID)
            } else {
                draftWorkspace.file.updateMarker(selectedMarkerID, note: note)
            }
        } else {
            draftWorkspace.file.updateMarker(selectedMarkerID, label: label, color: color)
        }
        persistWorkspace()
    }

    private func toggleVoiceoverRecording() async {
        if voiceoverEngine.isRecording {
            voiceoverEngine.stop()
        } else {
            await voiceoverEngine.start()
        }
    }

    private func selectedVideoClipAndAsset() -> (TimelineClip, ProjectAsset)? {
        guard
            let clip = selectedClip,
            clip.lane == .video,
            let asset = draftWorkspace.file.asset(for: clip.assetID),
            asset.type == .video
        else {
            appModel.errorMessage = "Select a video clip before generating captions."
            return nil
        }
        return (clip, asset)
    }

    private func generateAutoCaptions() async {
        guard let (clip, asset) = selectedVideoClipAndAsset() else { return }

        let mediaURL = draftWorkspace.summary.projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(asset.fileName)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            appModel.errorMessage = "The selected clip media file is missing."
            return
        }

        do {
            let captions = try await captionEngine.generateCaptions(
                for: clip,
                asset: asset,
                projectURL: draftWorkspace.summary.projectURL
            )
            applyGeneratedCaptions(captions, anchoredTo: clip)
        } catch let generationError {
            if shouldFallbackToTimingCaptions(generationError) {
                do {
                    let captions = try await captionEngine.generateTimingOnlyCaptions(
                        for: clip,
                        asset: asset,
                        projectURL: draftWorkspace.summary.projectURL
                    )
                    applyGeneratedCaptions(captions, anchoredTo: clip)
                    appModel.noticeMessage = "Speech transcription is unavailable. Added timing captions; edit text manually."
                    return
                } catch let fallbackError {
                    appModel.errorMessage = (fallbackError as? LocalizedError)?.errorDescription ?? fallbackError.localizedDescription
                    return
                }
            }
            appModel.errorMessage = (generationError as? LocalizedError)?.errorDescription ?? generationError.localizedDescription
        }
    }

    private func generateTimingCaptionsOnly() async {
        guard let (clip, asset) = selectedVideoClipAndAsset() else { return }

        let mediaURL = draftWorkspace.summary.projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(asset.fileName)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            appModel.errorMessage = "The selected clip media file is missing."
            return
        }

        do {
            let captions = try await captionEngine.generateTimingOnlyCaptions(
                for: clip,
                asset: asset,
                projectURL: draftWorkspace.summary.projectURL
            )
            applyGeneratedCaptions(captions, anchoredTo: clip)
            appModel.noticeMessage = "Generated timing caption blocks. Edit text in the Text Timeline."
        } catch {
            appModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func shouldFallbackToTimingCaptions(_ error: Error) -> Bool {
        CaptionFallbackPolicy.shouldFallbackToTimingCaptions(for: error)
    }

    private func applyGeneratedCaptions(_ captions: [GeneratedCaption], anchoredTo clip: TimelineClip) {
        guard !captions.isEmpty else { return }
        editorEnv.pushUndo(draftWorkspace)
        for caption in captions {
            _ = draftWorkspace.file.addTextOverlay(
                text: caption.text,
                startTime: max(clip.startTime, caption.startTime),
                duration: max(0.5, caption.endTime - caption.startTime),
                position: .bottom,
                style: .caption
            )
        }
        selectedTextOverlayID = draftWorkspace.file.textOverlays.last?.id
        persistWorkspace()
    }

    private func slipClipContent(_ clip: TimelineClip, by delta: Double) {
        guard ensureClipEditable(clip, action: "slipping clip content") else { return }
        applyTimelineEdit {
            $0.file.slipClipContent(clip.id, by: delta)
        }
    }

    private func extractAudio(from clip: TimelineClip) {
        guard ensureClipEditable(clip, action: "extracting audio") else { return }
        let extractedID = applyTimelineEdit {
            $0.file.extractAudioFromClip(clip.id, into: .voiceover)
        }
        if let extractedID {
            selectedClipID = extractedID
            selectedClipIDs = [extractedID]
            if let extractedClip = draftWorkspace.file.clip(for: extractedID) {
                selectedAssetID = extractedClip.assetID
                scrubTimeline(to: extractedClip.startTime)
            }
        }
    }

    private func cutSilences(from clip: TimelineClip) async {
        guard ensureClipEditable(clip, action: "cutting silences") else { return }
        guard let asset = draftWorkspace.file.asset(for: clip.assetID) else {
            appModel.errorMessage = "Could not find the selected clip media."
            return
        }

        let mediaURL = draftWorkspace.summary.projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(asset.fileName)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            appModel.errorMessage = "The selected clip media file is missing."
            return
        }

        do {
            let segments = try await Task.detached(priority: .userInitiated) {
                try Self.detectNonSilentSourceSegments(
                    mediaURL: mediaURL,
                    clipSourceStart: clip.sourceStart,
                    clipDuration: clip.duration,
                    silenceThresholdDB: -36,
                    minSegmentDuration: 0.20,
                    analysisWindow: 0.06,
                    maxGapToMerge: 0.10
                )
            }.value

            guard segments.count > 1 else {
                appModel.errorMessage = "No significant silent gaps were detected in this clip."
                return
            }

            let insertedIDs = applyTimelineEdit { workspace in
                workspace.file.replaceClipWithSourceSegments(clip.id, sourceSegments: segments)
            }

            guard !insertedIDs.isEmpty else {
                appModel.errorMessage = "Silence cut did not produce valid segments."
                return
            }

            selectedClipIDs = Set(insertedIDs)
            selectedClipID = insertedIDs.first
            selectedAssetID = clip.assetID
            if let firstID = insertedIDs.first, let firstClip = draftWorkspace.file.clip(for: firstID) {
                scrubTimeline(to: firstClip.startTime)
            }
        } catch {
            appModel.errorMessage = "Cut Silences failed: \(error.localizedDescription)"
        }
    }

    private func reverseClipMedia(_ clip: TimelineClip) async {
        guard ensureClipEditable(clip, action: "reversing") else { return }
        guard let sourceAsset = draftWorkspace.file.asset(for: clip.assetID), sourceAsset.type == .video else {
            appModel.errorMessage = "Reverse works only on video clips."
            return
        }

        let mediaURL = draftWorkspace.summary.projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(sourceAsset.fileName)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            appModel.errorMessage = "The selected clip media file is missing."
            return
        }

        do {
            let reversedURL = try await Task.detached(priority: .userInitiated) {
                try Self.makeReversedVideoFile(
                    from: mediaURL,
                    sourceStart: clip.sourceStart,
                    duration: clip.duration,
                    fps: 30
                )
            }.value
            defer { try? FileManager.default.removeItem(at: reversedURL) }

            let existingAssetIDs = Set(draftWorkspace.file.assets.map(\.id))
            let existingClipIDs = Set(draftWorkspace.file.timelineClips.map(\.id))
            editorEnv.pushUndo(draftWorkspace)

            var updatedWorkspace = try appModel.store.ingestAsset(
                from: reversedURL,
                into: draftWorkspace,
                preferredType: .video,
                preferredTrackKind: .video,
                timelineStartOverride: clip.startTime
            )

            guard
                let newAsset = updatedWorkspace.file.assets.first(where: { !existingAssetIDs.contains($0.id) }),
                let autoInsertedClipID = updatedWorkspace.file.timelineClips.first(where: { !existingClipIDs.contains($0.id) })?.id,
                let originalClipIndex = updatedWorkspace.file.timelineClips.firstIndex(where: { $0.id == clip.id })
            else {
                throw ExportEngineError.exportFailed("Could not insert reversed media.")
            }

            var replaced = updatedWorkspace.file.timelineClips[originalClipIndex]
            replaced.assetID = newAsset.id
            replaced.title = "\(clip.title) Reversed"
            replaced.sourceStart = 0
            replaced.sourceDuration = clip.duration
            replaced.duration = clip.duration
            updatedWorkspace.file.timelineClips[originalClipIndex] = replaced
            updatedWorkspace.file.deleteClip(autoInsertedClipID)

            updatedWorkspace = try appModel.store.saveWorkspace(updatedWorkspace)
            appModel.currentWorkspace = updatedWorkspace
            draftWorkspace = updatedWorkspace
            selectedAssetID = newAsset.id
            selectedClipID = clip.id
            selectedClipIDs = [clip.id]
            scrubTimeline(to: clip.startTime)
        } catch {
            appModel.errorMessage = "Reverse failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func insertFreezeFrame(from clip: TimelineClip, duration: Double = 0.5) async {
        guard ensureClipEditable(clip, action: "creating a freeze frame") else { return }
        guard let sourceAsset = draftWorkspace.file.asset(for: clip.assetID), sourceAsset.type == .video else {
            appModel.errorMessage = "Freeze frame works only on video clips."
            return
        }

        let mediaURL = draftWorkspace.summary.projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(sourceAsset.fileName)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            appModel.errorMessage = "The selected clip media file is missing."
            return
        }

        let localTime = max(0, min(clip.duration, currentTimelineTime - clip.startTime))
        let captureTime = clip.sourceStart + localTime

        do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: mediaURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1080, height: 1920)
            let imageTime = CMTime(seconds: captureTime, preferredTimescale: 600)
            let cgImage = try generator.copyCGImage(at: imageTime, actualTime: nil)

            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                throw ExportEngineError.exportFailed("Could not encode freeze frame image.")
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("macedits-freeze-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try pngData.write(to: tempURL, options: .atomic)

            defer { try? FileManager.default.removeItem(at: tempURL) }

            editorEnv.pushUndo(draftWorkspace)

            let existingAssetIDs = Set(draftWorkspace.file.assets.map(\.id))
            var updatedWorkspace = try appModel.store.ingestAsset(
                from: tempURL,
                into: draftWorkspace,
                preferredType: .image,
                preferredTrackKind: .video,
                timelineStartOverride: currentTimelineTime
            )

            guard
                let insertedAsset = updatedWorkspace.file.assets.first(where: { !existingAssetIDs.contains($0.id) }),
                let insertedClipIndex = updatedWorkspace.file.timelineClips.firstIndex(where: { $0.assetID == insertedAsset.id })
            else {
                throw ExportEngineError.exportFailed("Could not insert freeze frame clip.")
            }

            updatedWorkspace.file.timelineClips[insertedClipIndex].title = "Freeze Frame"
            updatedWorkspace.file.timelineClips[insertedClipIndex].duration = max(0.2, duration)
            updatedWorkspace.file.timelineClips[insertedClipIndex].sourceDuration = max(0.2, duration)

            updatedWorkspace = try appModel.store.saveWorkspace(updatedWorkspace)
            appModel.currentWorkspace = updatedWorkspace
            draftWorkspace = updatedWorkspace

            let freezeClip = updatedWorkspace.file.timelineClips[insertedClipIndex]
            selectedAssetID = insertedAsset.id
            selectedClipID = freezeClip.id
            selectedClipIDs = [freezeClip.id]
            scrubTimeline(to: freezeClip.startTime)
        } catch {
            appModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func videoAssetsForReplacement(clipID: UUID) -> [ProjectAsset] {
        draftWorkspace.file.assets.filter { asset in
            asset.type == .video && draftWorkspace.file.clip(for: clipID)?.assetID != asset.id
        }
    }

    private func replaceClipAsset(_ clip: TimelineClip, with asset: ProjectAsset) async {
        guard ensureClipEditable(clip, action: "replacing media") else { return }
        let mediaURL = draftWorkspace.summary.projectURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(asset.fileName)
        let duration: Double
        do {
            let loaded = try await AVURLAsset(url: mediaURL).load(.duration)
            duration = loaded.seconds
        } catch {
            duration = .nan
        }

        applyTimelineEdit { workspace in
            guard let index = workspace.file.timelineClips.firstIndex(where: { $0.id == clip.id }) else { return }
            var updated = workspace.file.timelineClips[index]
            updated.assetID = asset.id
            updated.title = asset.originalName
            updated.sourceStart = 0

            if duration.isFinite && duration > 0 {
                updated.sourceDuration = duration
                updated.duration = min(updated.duration, duration)
            } else {
                updated.sourceDuration = max(updated.sourceDuration, updated.duration)
            }

            workspace.file.timelineClips[index] = updated
        }

        selectedAssetID = asset.id
        selectedClipID = clip.id
        selectedClipIDs = [clip.id]
    }

    nonisolated private static func detectNonSilentSourceSegments(
        mediaURL: URL,
        clipSourceStart: Double,
        clipDuration: Double,
        silenceThresholdDB: Float,
        minSegmentDuration: Double,
        analysisWindow: Double,
        maxGapToMerge: Double
    ) throws -> [ClosedRange<Double>] {
        let audioFile = try AVAudioFile(forReading: mediaURL)
        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return [] }

        let startFrame = max(0, AVAudioFramePosition(clipSourceStart * sampleRate))
        let totalClipFrames = max(0, AVAudioFramePosition(clipDuration * sampleRate))
        let availableFrames = max(0, audioFile.length - startFrame)
        let framesToRead = min(totalClipFrames, availableFrames)
        guard framesToRead > 0 else { return [] }

        audioFile.framePosition = startFrame
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

        let threshold = powf(10, silenceThresholdDB / 20)
        let windowFrames = max(256, Int(sampleRate * max(0.02, analysisWindow)))

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
            let windowStartTime = Double(index) / sampleRate
            let windowEndTime = Double(end) / sampleRate

            if rms >= threshold {
                if let start = currentStart {
                    if windowStartTime - currentEnd <= maxGapToMerge {
                        currentEnd = windowEndTime
                    } else {
                        localSegments.append(start...currentEnd)
                        currentStart = windowStartTime
                        currentEnd = windowEndTime
                    }
                } else {
                    currentStart = windowStartTime
                    currentEnd = windowEndTime
                }
            }

            index = end
        }

        if let start = currentStart {
            localSegments.append(start...currentEnd)
        }

        let merged = localSegments
            .map { segment -> ClosedRange<Double>? in
                let lower = max(0, segment.lowerBound)
                let upper = min(clipDuration, segment.upperBound)
                guard upper - lower >= minSegmentDuration else { return nil }
                return (clipSourceStart + lower)...(clipSourceStart + upper)
            }
            .compactMap { $0 }
            .sorted { $0.lowerBound < $1.lowerBound }

        return merged
    }

    nonisolated private static func makeReversedVideoFile(
        from mediaURL: URL,
        sourceStart: Double,
        duration: Double,
        fps: Int
    ) throws -> URL {
        let safeDuration = max(0.1, duration)
        let frameRate = max(12, fps)
        let frameCount = max(2, Int((safeDuration * Double(frameRate)).rounded()))
        let timeStep = safeDuration / Double(frameCount - 1)

        let avAsset = AVURLAsset(url: mediaURL)
        let imageGenerator = AVAssetImageGenerator(asset: avAsset)
        imageGenerator.appliesPreferredTrackTransform = true

        let firstTime = CMTime(seconds: sourceStart, preferredTimescale: 600)
        let firstFrame = try imageGenerator.copyCGImage(at: firstTime, actualTime: nil)
        let frameSize = CGSize(width: firstFrame.width, height: firstFrame.height)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macedits-reverse-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: frameSize.width,
            AVVideoHeightKey: frameSize.height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: frameSize.width,
                kCVPixelBufferHeightKey as String: frameSize.height
            ]
        )
        guard writer.canAdd(input) else {
            throw ExportEngineError.exportFailed("Reverse render input could not be attached.")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw ExportEngineError.exportFailed(writer.error?.localizedDescription ?? "Reverse writer failed to start.")
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<frameCount {
            let reverseTime = sourceStart + safeDuration - (Double(frameIndex) * timeStep)
            let clampedTime = max(sourceStart, min(sourceStart + safeDuration, reverseTime))
            let time = CMTime(seconds: clampedTime, preferredTimescale: 600)
            let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)

            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }

            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                throw ExportEngineError.exportFailed("Reverse render pixel buffer pool unavailable.")
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw ExportEngineError.exportFailed("Could not create reverse render pixel buffer.")
            }
            try render(cgImage: cgImage, into: pixelBuffer)

            let pts = CMTime(seconds: Double(frameIndex) / Double(frameRate), preferredTimescale: 600)
            guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                throw ExportEngineError.exportFailed("Reverse frame append failed.")
            }
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        guard writer.status == .completed else {
            throw ExportEngineError.exportFailed(writer.error?.localizedDescription ?? "Reverse render failed.")
        }
        return outputURL
    }

    nonisolated private static func render(cgImage: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: nil)
        context.render(ciImage, to: pixelBuffer)
    }

    private var voiceoverDurationLabel: String {
        let totalSeconds = Int(voiceoverEngine.elapsed.rounded(FloatingPointRoundingRule.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct AssetRow: View {
    let asset: ProjectAsset
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AppTheme.accent.opacity(0.2) : Color.white.opacity(0.05))
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : AppTheme.accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(asset.originalName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Text(asset.type.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(isSelected ? AppTheme.accent.opacity(0.16) : Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var symbol: String {
        switch asset.type {
        case .video:
            return "film"
        case .audio:
            return "waveform"
        case .image:
            return "photo"
        case .unknown:
            return "questionmark.square.dashed"
        }
    }
}

private struct TimelineClipPill: View {
    let clip: TimelineClip
    let asset: ProjectAsset
    let projectURL: URL
    let isSelected: Bool
    let pixelsPerSecond: CGFloat
    let onClipDragged: (CGFloat) -> Void
    let onTrimStartDragged: (Double) -> Void
    let onTrimEndDragged: (Double) -> Void

    @State private var clipDragTranslation: CGFloat = 0
    @State private var isDraggingClip = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)

            ThumbnailStripView(
                asset: asset,
                projectURL: projectURL,
                clipDuration: clip.duration,
                lane: clip.lane
            )
            .frame(height: clipHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.20), Color.black.opacity(0.56)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            HStack(spacing: 6) {
                Image(systemName: laneIcon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(clip.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(clip.duration, format: .number.precision(.fractionLength(1)))s")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
        .frame(width: clipWidth, height: clipHeight, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? laneAccent.opacity(0.95) : Color.white.opacity(0.16),
                    lineWidth: isSelected ? 1.6 : 1
                )
        }
        .overlay {
            if isSelected {
                HStack {
                    trimHandle(direction: .leading)
                    Spacer()
                    trimHandle(direction: .trailing)
                }
                .padding(.horizontal, -4)
            }
        }
        .offset(x: clipDragTranslation)
        .scaleEffect(isDraggingClip ? 1.012 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: clipDragTranslation)
        .shadow(color: laneAccent.opacity(isSelected ? 0.24 : 0), radius: 10, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let handleZone: CGFloat = 14
                    if value.startLocation.x <= handleZone || value.startLocation.x >= (clipWidth - handleZone) {
                        return
                    }
                    isDraggingClip = true
                    clipDragTranslation = value.translation.width
                }
                .onEnded { value in
                    let handleZone: CGFloat = 14
                    if value.startLocation.x <= handleZone || value.startLocation.x >= (clipWidth - handleZone) {
                        clipDragTranslation = 0
                        isDraggingClip = false
                        return
                    }
                    onClipDragged(value.translation.width)
                    clipDragTranslation = 0
                    isDraggingClip = false
                }
        )
    }

    private var clipWidth: CGFloat {
        max(92, CGFloat(clip.duration) * pixelsPerSecond)
    }

    private var clipHeight: CGFloat {
        58
    }

    private var backgroundColor: Color {
        switch clip.lane {
        case .video:
            return isSelected ? Color(red: 0.95, green: 0.80, blue: 0.12).opacity(0.88) : Color.white.opacity(0.06)
        case .music:
            return Color(red: 0.77, green: 0.17, blue: 0.88).opacity(isSelected ? 0.86 : 0.62)
        case .voiceover:
            return Color(red: 0.95, green: 0.21, blue: 0.64).opacity(isSelected ? 0.86 : 0.58)
        case .captions:
            return Color.white.opacity(0.12)
        }
    }

    private var laneAccent: Color {
        switch clip.lane {
        case .video:
            return Color(red: 0.99, green: 0.80, blue: 0.18)
        case .music:
            return Color(red: 0.84, green: 0.28, blue: 0.95)
        case .voiceover:
            return Color(red: 1.0, green: 0.36, blue: 0.66)
        case .captions:
            return AppTheme.accent
        }
    }

    private var laneIcon: String {
        switch clip.lane {
        case .video:
            return "film"
        case .music:
            return "music.note"
        case .voiceover:
            return "mic.fill"
        case .captions:
            return "captions.bubble.fill"
        }
    }

    private func trimHandle(direction: HorizontalEdge) -> some View {
        ZStack {
            Capsule()
                .fill(.white.opacity(0.95))
                .frame(width: 9, height: 44)
            Image(systemName: direction == .leading ? "chevron.left" : "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.7))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onEnded { value in
                    let deltaSeconds = Double(value.translation.width / max(pixelsPerSecond, 1))
                    if direction == .leading {
                        onTrimStartDragged(deltaSeconds)
                    } else {
                        onTrimEndDragged(deltaSeconds)
                    }
                }
        )
        .help(direction == .leading ? "Drag to trim clip start" : "Drag to trim clip end")
    }
}

private struct InspectorCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            content
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct InspectorMetric: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct TextOverlayRow: View {
    let overlay: ProjectTextOverlay
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(overlay.text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
            Text("\(overlay.position.rawValue.capitalized) • \(overlay.startTime.formatted(.number.precision(.fractionLength(1))))s → \(overlay.endTime.formatted(.number.precision(.fractionLength(1))))s")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppTheme.openAccent.opacity(0.18) : Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private enum EditorLayoutPreset: String, CaseIterable, Hashable {
    case balanced
    case preview
    case precision
    case custom

    static var selectableCases: [EditorLayoutPreset] {
        [.balanced, .preview, .precision]
    }

    var label: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .preview:
            return "Creator Preview"
        case .precision:
            return "Edit Precision"
        case .custom:
            return "Custom"
        }
    }

    var shortLabel: String {
        switch self {
        case .balanced:
            return "Bal"
        case .preview:
            return "Prev"
        case .precision:
            return "Edit"
        case .custom:
            return "Custom"
        }
    }
}

private enum InspectorTab: CaseIterable {
    case edit
    case audio
    case style
    case text
    case output

    var label: String {
        switch self {
        case .edit:
            return "Edit"
        case .audio:
            return "Audio"
        case .style:
            return "Style"
        case .text:
            return "Text"
        case .output:
            return "Output"
        }
    }
}

private struct AudioTrackRow: View {
    let clip: TimelineClip
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(clip.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Spacer()
                Text(clip.lane.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            HStack {
                Text("\(clip.startTime.formatted(.number.precision(.fractionLength(1))))s")
                Text("•")
                Text("\(Int(clip.volume * 100))%")
                if clip.isMuted {
                    Text("• muted")
                }
            }
            .font(.caption)
            .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AppTheme.recordAccent.opacity(0.18) : Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension LookPreset {
    var gradient: LinearGradient {
        switch self {
        case .clean:
            return LinearGradient(colors: [.gray.opacity(0.5), .white.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .film:
            return LinearGradient(colors: [.orange.opacity(0.7), .brown.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .punch:
            return LinearGradient(colors: [.pink.opacity(0.8), .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mono:
            return LinearGradient(colors: [.white.opacity(0.9), .black.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private extension ProjectTrack {
    var iconName: String {
        switch kind {
        case .video:
            return "film"
        case .music:
            return "music.note"
        case .voiceover:
            return "mic.fill"
        case .captions:
            return "captions.bubble.fill"
        }
    }
}

// MARK: - Keyboard Shortcut Modifier (extracted for type-checking performance)
private struct EditorKeyboardShortcuts: ViewModifier {
    var onSpace: () -> Void
    var onDelete: () -> Void
    var onLeft: () -> Void
    var onRight: () -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onZoomIn: () -> Void
    var onZoomOut: () -> Void
    var onZoomReset: () -> Void
    var onFitTimeline: () -> Void
    var onExport: () -> Void
    var onSplitClip: () -> Void
    var onAddMarker: () -> Void
    var onNextMarker: () -> Void
    var onPreviousMarker: () -> Void
    var onNextCut: () -> Void
    var onPreviousCut: () -> Void
    var onFrameStepBackward: () -> Void
    var onFrameStepForward: () -> Void
    var onShuttleBackward: () -> Void
    var onShuttlePausePlay: () -> Void
    var onShuttleForward: () -> Void
    var onToggleRipple: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.space) { onSpace(); return .handled }
            .onKeyPress(.delete) { onDelete(); return .handled }
            .onKeyPress(.leftArrow) { onLeft(); return .handled }
            .onKeyPress(.rightArrow) { onRight(); return .handled }
            .onKeyPress { press in
                if press.key == KeyEquivalent("z") {
                    if press.modifiers == [.command, .shift] { onRedo(); return .handled }
                    if press.modifiers == .command { onUndo(); return .handled }
                    if press.modifiers == .shift { onFitTimeline(); return .handled }
                }
                if press.modifiers == .command {
                    if press.key == KeyEquivalent("e") {
                        onExport(); return .handled
                    }
                    if press.key == KeyEquivalent("b") {
                        onSplitClip(); return .handled
                    }
                    if press.key == KeyEquivalent("=") || press.key == KeyEquivalent("+") {
                        onZoomIn(); return .handled
                    }
                    if press.key == KeyEquivalent("-") {
                        onZoomOut(); return .handled
                    }
                    if press.key == KeyEquivalent("0") {
                        onZoomReset(); return .handled
                    }
                }
                if press.modifiers.isEmpty {
                    if press.key == KeyEquivalent("s") {
                        onSplitClip(); return .handled
                    }
                    if press.key == KeyEquivalent("x")
                        || press.key == KeyEquivalent("b")
                        || press.key == KeyEquivalent("c")
                    {
                        onSplitClip(); return .handled
                    }
                    if press.key == KeyEquivalent("m") {
                        onAddMarker(); return .handled
                    }
                    if press.key == KeyEquivalent("n") {
                        onNextMarker(); return .handled
                    }
                    if press.key == KeyEquivalent("p") {
                        onPreviousMarker(); return .handled
                    }
                    if press.key == KeyEquivalent("]") {
                        onNextCut(); return .handled
                    }
                    if press.key == KeyEquivalent("[") {
                        onPreviousCut(); return .handled
                    }
                    if press.key == KeyEquivalent(",") {
                        onFrameStepBackward(); return .handled
                    }
                    if press.key == KeyEquivalent(".") {
                        onFrameStepForward(); return .handled
                    }
                    if press.key == KeyEquivalent("j") {
                        onShuttleBackward(); return .handled
                    }
                    if press.key == KeyEquivalent("k") {
                        onShuttlePausePlay(); return .handled
                    }
                    if press.key == KeyEquivalent("v") {
                        onShuttlePausePlay(); return .handled
                    }
                    if press.key == KeyEquivalent("l") {
                        onShuttleForward(); return .handled
                    }
                    if press.key == KeyEquivalent("r") {
                        onToggleRipple(); return .handled
                    }
                }
                return .ignored
            }
    }
}

// MARK: - Transition Diamond

private struct TransitionDiamond: View {
    let type: TransitionType
    let duration: Double
    let onSelectType: (TransitionType) -> Void
    let onSelectDuration: (Double) -> Void

    @State private var isHovered = false
    @State private var showPopover = false
    @State private var editableDuration: Double

    init(
        type: TransitionType,
        duration: Double,
        onSelectType: @escaping (TransitionType) -> Void,
        onSelectDuration: @escaping (Double) -> Void
    ) {
        self.type = type
        self.duration = duration
        self.onSelectType = onSelectType
        self.onSelectDuration = onSelectDuration
        _editableDuration = State(initialValue: max(0.1, min(2.0, duration)))
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(type == .none
                        ? Color.white.opacity(isHovered ? 0.12 : 0.06)
                        : AppTheme.accent.opacity(isHovered ? 0.7 : 0.5)
                    )
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(45))

                Image(systemName: type == .none ? "plus" : type.iconName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(type == .none ? AppTheme.secondaryText : .white)
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Edit transition")
        .onHover { isHovered = $0 }
        .accessibilityLabel("Transition editor")
        .accessibilityHint("Choose transition type and duration to the next clip.")
        .onChange(of: duration) { _, newValue in
            editableDuration = max(0.1, min(2.0, newValue))
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            transitionPicker
        }
    }

    private var transitionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transition")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            ForEach(TransitionType.allCases, id: \.self) { transType in
                Button {
                    onSelectType(transType)
                    showPopover = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: transType.iconName)
                            .font(.system(size: 11))
                            .frame(width: 16)
                        Text(transType.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if transType == type {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(transType == type ? Color.white.opacity(0.08) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set transition to \(transType.displayName)")
            }

            Divider()
                .overlay(Color.white.opacity(0.1))
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                Text("Duration")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Text(String(format: "%.2fs", editableDuration))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)

            Slider(
                value: Binding(
                    get: { editableDuration },
                    set: { newValue in
                        editableDuration = min(2.0, max(0.1, newValue))
                        if type != .none {
                            onSelectDuration(editableDuration)
                        }
                    }
                ),
                in: 0.1...2.0
            )
            .tint(AppTheme.accent)
            .disabled(type == .none)
            .opacity(type == .none ? 0.45 : 1)
            .padding(.horizontal, 8)
            .accessibilityLabel("Transition duration slider")

            HStack(spacing: 6) {
                ForEach([0.25, 0.5, 0.75, 1.0, 1.5], id: \.self) { presetDuration in
                    Button {
                        editableDuration = max(0.1, min(2.0, presetDuration))
                        if type != .none {
                            onSelectDuration(editableDuration)
                        }
                    } label: {
                        Text(String(format: "%.2f", presetDuration))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(abs(editableDuration - presetDuration) < 0.001 ? .white : AppTheme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(abs(editableDuration - presetDuration) < 0.001 ? AppTheme.accent.opacity(0.28) : Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(type == .none)
                    .opacity(type == .none ? 0.45 : 1)
                    .accessibilityLabel("Set transition duration to \(String(format: "%.2f", presetDuration)) seconds")
                }
            }
            .padding(.horizontal, 8)

            HStack(spacing: 8) {
                Button {
                    editableDuration = max(0.1, editableDuration - 0.1)
                    if type != .none {
                        onSelectDuration(editableDuration)
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(type == .none)
                .opacity(type == .none ? 0.45 : 1)
                .accessibilityLabel("Decrease transition duration")

                Button {
                    editableDuration = min(2.0, editableDuration + 0.1)
                    if type != .none {
                        onSelectDuration(editableDuration)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(type == .none)
                .opacity(type == .none ? 0.45 : 1)
                .accessibilityLabel("Increase transition duration")

                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
        }
        .padding(6)
        .frame(width: 220)
        .background(AppTheme.subpanel(cornerRadius: 12))
    }
}

// MARK: - Timeline Marker UI

private struct TimelineMarkerFlag: View {
    let marker: TimelineMarker
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(marker.color.tint)
                    .shadow(color: marker.color.tint.opacity(0.45), radius: isSelected ? 6 : 0)

                Rectangle()
                    .fill(marker.color.tint.opacity(isSelected ? 1 : 0.8))
                    .frame(width: 1, height: 11)
            }
            .padding(.top, 1)
            .frame(width: 12, height: 30)
            .contentShape(Rectangle())
            .overlay {
                if isSelected || isHovered {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(AppTheme.accent.opacity(0.7), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            isHovered = hovered
        }
        .contextMenu {
            Button("Jump To Marker") { onSelect() }
            Button("Delete Marker", role: .destructive) { onDelete() }
        }
    }
}

private struct TimelineMarkerRow: View {
    let marker: TimelineMarker
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(marker.color.tint)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(marker.label.isEmpty ? "Marker" : marker.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(marker.time, format: .number.precision(.fractionLength(2)))s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 0)

            if marker.note?.isEmpty == false {
                Image(systemName: "note.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? AppTheme.accent.opacity(0.16) : Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Draggable Text Overlay

private struct DraggableTextOverlay: View {
    let overlay: ProjectTextOverlay
    let isSelected: Bool
    let font: Font
    let onSelect: () -> Void
    let onDragEnd: (Double, Double) -> Void

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        Text(overlay.text)
            .font(font)
            .multilineTextAlignment(.center)
            .lineLimit(overlay.style == .caption ? 3 : 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: overlay.style == .caption ? 420 : 520)
            .foregroundStyle(.white)
            .padding(.horizontal, overlay.style == .caption ? 14 : 6)
            .padding(.vertical, overlay.style == .caption ? 10 : 4)
            .background(
                Group {
                    if overlay.style == .caption {
                        Color.black.opacity(0.55)
                    } else if isSelected {
                        Color.white.opacity(0.08)
                    } else {
                        Color.clear
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent : Color.clear, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.3), radius: isSelected ? 8 : 2, y: 2)
            .offset(
                x: CGFloat(overlay.offsetX) + dragOffset.width,
                y: CGFloat(overlay.offsetY) + dragOffset.height
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        let newX = overlay.offsetX + Double(value.translation.width)
                        let newY = overlay.offsetY + Double(value.translation.height)
                        dragOffset = .zero
                        onDragEnd(newX, newY)
                    }
            )
            .onTapGesture {
                onSelect()
            }
    }
}

private extension MarkerColor {
    var tint: Color {
        switch self {
        case .blue: return AppTheme.accent
        case .red: return AppTheme.recordAccent
        case .green: return AppTheme.openAccent
        case .yellow: return AppTheme.importAccent
        case .purple: return Color(red: 0.74, green: 0.48, blue: 0.93)
        }
    }

    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .red: return "Red"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .purple: return "Purple"
        }
    }
}
