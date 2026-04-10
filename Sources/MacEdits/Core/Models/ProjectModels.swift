import Foundation

struct ProjectSummary: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var projectURL: URL
    var createdAt: Date
    var updatedAt: Date
    var origin: ProjectOrigin
}

struct ProjectWorkspace: Identifiable, Hashable {
    var summary: ProjectSummary
    var file: ReelProjectFile

    var id: UUID { summary.id }
}

enum ProjectOrigin: String, Codable, Hashable {
    case recording
    case importedFiles
    case mixed
}

struct ReelProjectFile: Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var origin: ProjectOrigin
    var notes: String
    var assets: [ProjectAsset]
    var timelineTracks: [ProjectTrack]
    var timelineClips: [TimelineClip]
    var textOverlays: [ProjectTextOverlay]
    var transitions: [ClipTransition]
    var markers: [TimelineMarker]
    var styleSettings: ProjectStyleSettings
    var exportPreset: ExportPreset

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        origin: ProjectOrigin,
        notes: String,
        assets: [ProjectAsset],
        timelineTracks: [ProjectTrack],
        timelineClips: [TimelineClip] = [],
        textOverlays: [ProjectTextOverlay] = [],
        transitions: [ClipTransition] = [],
        markers: [TimelineMarker] = [],
        styleSettings: ProjectStyleSettings = .default,
        exportPreset: ExportPreset
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.origin = origin
        self.notes = notes
        self.assets = assets
        self.timelineTracks = timelineTracks
        self.timelineClips = timelineClips
        self.textOverlays = textOverlays
        self.transitions = transitions
        self.markers = markers
        self.styleSettings = styleSettings
        self.exportPreset = exportPreset
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case origin
        case notes
        case assets
        case timelineTracks
        case timelineClips
        case textOverlays
        case transitions
        case markers
        case styleSettings
        case exportPreset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        origin = try container.decode(ProjectOrigin.self, forKey: .origin)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        assets = try container.decodeIfPresent([ProjectAsset].self, forKey: .assets) ?? []
        timelineTracks = try container.decodeIfPresent([ProjectTrack].self, forKey: .timelineTracks) ?? []
        timelineClips = try container.decodeIfPresent([TimelineClip].self, forKey: .timelineClips) ?? []
        textOverlays = try container.decodeIfPresent([ProjectTextOverlay].self, forKey: .textOverlays) ?? []
        transitions = try container.decodeIfPresent([ClipTransition].self, forKey: .transitions) ?? []
        markers = try container.decodeIfPresent([TimelineMarker].self, forKey: .markers) ?? []
        styleSettings = try container.decodeIfPresent(ProjectStyleSettings.self, forKey: .styleSettings) ?? .default
        exportPreset = try container.decodeIfPresent(ExportPreset.self, forKey: .exportPreset) ?? .reels1080
    }
}

struct ProjectAsset: Codable, Hashable, Identifiable {
    let id: UUID
    var type: AssetType
    var fileName: String
    var originalName: String
    var importedAt: Date
}

enum AssetType: String, Codable, Hashable {
    case video
    case audio
    case image
    case unknown
}

struct ProjectTrack: Codable, Hashable, Identifiable {
    let id: UUID
    var kind: TrackKind
    var displayName: String
}

enum TrackKind: String, Codable, Hashable {
    case video
    case music
    case voiceover
    case captions
}

struct TimelineClip: Codable, Hashable, Identifiable {
    let id: UUID
    var assetID: UUID
    var trackID: UUID
    var lane: TrackKind
    var title: String
    var startTime: Double
    var duration: Double
    var sourceStart: Double
    var sourceDuration: Double
    var volume: Double
    var isMuted: Bool
    var speedMultiplier: Double

    var effectiveDuration: Double {
        duration / speedMultiplier
    }

    init(
        id: UUID,
        assetID: UUID,
        trackID: UUID,
        lane: TrackKind,
        title: String,
        startTime: Double,
        duration: Double,
        sourceStart: Double = 0,
        sourceDuration: Double? = nil,
        volume: Double = 1,
        isMuted: Bool = false,
        speedMultiplier: Double = 1.0
    ) {
        self.id = id
        self.assetID = assetID
        self.trackID = trackID
        self.lane = lane
        self.title = title
        self.startTime = startTime
        self.duration = duration
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration ?? duration
        self.volume = volume
        self.isMuted = isMuted
        self.speedMultiplier = speedMultiplier
    }

    enum CodingKeys: String, CodingKey {
        case id
        case assetID
        case trackID
        case lane
        case title
        case startTime
        case duration
        case sourceStart
        case sourceDuration
        case volume
        case isMuted
        case speedMultiplier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        assetID = try container.decode(UUID.self, forKey: .assetID)
        trackID = try container.decode(UUID.self, forKey: .trackID)
        lane = try container.decode(TrackKind.self, forKey: .lane)
        title = try container.decode(String.self, forKey: .title)
        startTime = try container.decode(Double.self, forKey: .startTime)
        duration = try container.decode(Double.self, forKey: .duration)
        sourceStart = try container.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0
        sourceDuration = try container.decodeIfPresent(Double.self, forKey: .sourceDuration) ?? duration
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        speedMultiplier = try container.decodeIfPresent(Double.self, forKey: .speedMultiplier) ?? 1.0
    }
}

// MARK: - Transitions

enum TransitionType: String, Codable, CaseIterable, Hashable {
    case none
    case crossDissolve
    case fadeToBlack
    case slideLeft
    case slideRight
    case slideUp
    case slideDown
    case wipeLeft
    case wipeRight
    case zoom

    var displayName: String {
        switch self {
        case .none: return "None"
        case .crossDissolve: return "Dissolve"
        case .fadeToBlack: return "Fade"
        case .slideLeft: return "Slide Left"
        case .slideRight: return "Slide Right"
        case .slideUp: return "Slide Up"
        case .slideDown: return "Slide Down"
        case .wipeLeft: return "Wipe Left"
        case .wipeRight: return "Wipe Right"
        case .zoom: return "Zoom"
        }
    }

    var iconName: String {
        switch self {
        case .none: return "xmark"
        case .crossDissolve: return "circle.lefthalf.filled"
        case .fadeToBlack: return "moon.fill"
        case .slideLeft: return "arrow.left.square"
        case .slideRight: return "arrow.right.square"
        case .slideUp: return "arrow.up.square"
        case .slideDown: return "arrow.down.square"
        case .wipeLeft: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .wipeRight: return "rectangle.righthalf.inset.filled.arrow.right"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

struct ClipTransition: Codable, Hashable, Identifiable {
    let id: UUID
    var fromClipID: UUID
    var toClipID: UUID
    var type: TransitionType
    var duration: Double  // seconds

    init(
        id: UUID = UUID(),
        fromClipID: UUID,
        toClipID: UUID,
        type: TransitionType = .crossDissolve,
        duration: Double = 0.5
    ) {
        self.id = id
        self.fromClipID = fromClipID
        self.toClipID = toClipID
        self.type = type
        self.duration = duration
    }
}

// MARK: - Timeline Markers

struct TimelineMarker: Codable, Hashable, Identifiable {
    let id: UUID
    var time: Double
    var label: String
    var color: MarkerColor
    var note: String?

    init(id: UUID = UUID(), time: Double, label: String, color: MarkerColor = .blue, note: String? = nil) {
        self.id = id
        self.time = time
        self.label = label
        self.color = color
        self.note = note
    }
}

enum MarkerColor: String, Codable, CaseIterable, Hashable {
    case blue
    case red
    case green
    case yellow
    case purple
}

struct ExportPreset: Codable, Hashable {
    var width: Int
    var height: Int
    var frameRate: Int
    var codec: String

    static let reels1080 = ExportPreset(
        width: 1080,
        height: 1920,
        frameRate: 30,
        codec: "H.264"
    )
}

enum PlatformPreset: String, CaseIterable, Identifiable {
    case instagramReels = "Instagram Reels"
    case tikTok = "TikTok"
    case youtubeShorts = "YouTube Shorts"
    case custom = "Custom"

    var id: String { rawValue }

    var exportPreset: ExportPreset {
        switch self {
        case .instagramReels:
            return ExportPreset(width: 1080, height: 1920, frameRate: 30, codec: "H.264")
        case .tikTok:
            return ExportPreset(width: 1080, height: 1920, frameRate: 30, codec: "H.264")
        case .youtubeShorts:
            return ExportPreset(width: 1080, height: 1920, frameRate: 30, codec: "H.264")
        case .custom:
            return .reels1080
        }
    }

    var maxDurationSeconds: Double {
        switch self {
        case .instagramReels: return 90
        case .tikTok: return 180
        case .youtubeShorts: return 60
        case .custom: return .infinity
        }
    }

    var iconName: String {
        switch self {
        case .instagramReels: return "camera.metering.center.weighted"
        case .tikTok: return "music.note"
        case .youtubeShorts: return "play.rectangle.fill"
        case .custom: return "slider.horizontal.3"
        }
    }
}

struct ProjectTextOverlay: Codable, Hashable, Identifiable {
    let id: UUID
    var text: String
    var startTime: Double
    var endTime: Double
    var position: TextOverlayPosition
    var style: TextOverlayStyle
    var offsetX: Double
    var offsetY: Double

    init(
        id: UUID,
        text: String,
        startTime: Double,
        endTime: Double,
        position: TextOverlayPosition,
        style: TextOverlayStyle,
        offsetX: Double = 0,
        offsetY: Double = 0
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.position = position
        self.style = style
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    enum CodingKeys: String, CodingKey {
        case id, text, startTime, endTime, position, style, offsetX, offsetY
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        startTime = try container.decode(Double.self, forKey: .startTime)
        endTime = try container.decode(Double.self, forKey: .endTime)
        position = try container.decode(TextOverlayPosition.self, forKey: .position)
        style = try container.decode(TextOverlayStyle.self, forKey: .style)
        offsetX = try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
    }
}

enum TextOverlayPosition: String, Codable, CaseIterable, Hashable {
    case top
    case center
    case bottom
}

enum TextOverlayStyle: String, Codable, CaseIterable, Hashable {
    case title
    case subtitle
    case caption
}

extension ReelProjectFile {
    func asset(for id: UUID) -> ProjectAsset? {
        assets.first(where: { $0.id == id })
    }

    func clip(for id: UUID?) -> TimelineClip? {
        guard let id else { return nil }
        return timelineClips.first(where: { $0.id == id })
    }

    func clips(for trackID: UUID) -> [TimelineClip] {
        timelineClips
            .filter { $0.trackID == trackID }
            .sorted { $0.startTime < $1.startTime }
    }

    var totalDuration: Double {
        timelineClips.map { $0.startTime + $0.duration }.max() ?? 0
    }

    func textOverlay(for id: UUID?) -> ProjectTextOverlay? {
        guard let id else { return nil }
        return textOverlays.first(where: { $0.id == id })
    }

    func activeTextOverlays(at timelineTime: Double) -> [ProjectTextOverlay] {
        textOverlays.filter { timelineTime >= $0.startTime && timelineTime <= $0.endTime }
    }

    mutating func addTextOverlay(
        text: String,
        startTime: Double,
        duration: Double,
        position: TextOverlayPosition,
        style: TextOverlayStyle
    ) -> UUID {
        let id = UUID()
        let safeDuration = max(0.5, duration)
        textOverlays.append(
            ProjectTextOverlay(
                id: id,
                text: text,
                startTime: max(0, startTime),
                endTime: max(0, startTime) + safeDuration,
                position: position,
                style: style
            )
        )
        textOverlays.sort { $0.startTime < $1.startTime }
        return id
    }

    mutating func updateTextOverlay(
        _ id: UUID,
        text: String? = nil,
        startTime: Double? = nil,
        endTime: Double? = nil,
        position: TextOverlayPosition? = nil,
        style: TextOverlayStyle? = nil,
        offsetX: Double? = nil,
        offsetY: Double? = nil
    ) {
        guard let index = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        if let text {
            textOverlays[index].text = text
        }
        if let startTime {
            textOverlays[index].startTime = max(0, startTime)
        }
        if let endTime {
            textOverlays[index].endTime = max(textOverlays[index].startTime + 0.5, endTime)
        }
        if let position {
            textOverlays[index].position = position
        }
        if let style {
            textOverlays[index].style = style
        }
        if let offsetX {
            textOverlays[index].offsetX = offsetX
        }
        if let offsetY {
            textOverlays[index].offsetY = offsetY
        }
        textOverlays.sort { $0.startTime < $1.startTime }
    }

    mutating func removeTextOverlay(_ id: UUID) {
        textOverlays.removeAll { $0.id == id }
    }

    mutating func duplicateClip(_ clipID: UUID) {
        mutateTrack(containing: clipID) { clips, index in
            var copy = clips[index]
            copy = TimelineClip(
                id: UUID(),
                assetID: copy.assetID,
                trackID: copy.trackID,
                lane: copy.lane,
                title: copy.title + " Copy",
                startTime: copy.startTime + copy.duration,
                duration: copy.duration,
                sourceStart: copy.sourceStart,
                sourceDuration: copy.sourceDuration,
                volume: copy.volume,
                isMuted: copy.isMuted
            )
            clips.insert(copy, at: index + 1)
        }
    }

    @discardableResult
    mutating func splitClip(_ clipID: UUID, ripple: Bool = true) -> UUID? {
        guard let clip = clip(for: clipID) else { return nil }
        let midpoint = clip.startTime + (clip.duration / 2)
        return splitClip(clipID, at: midpoint, ripple: ripple)
    }

    @discardableResult
    mutating func splitClip(_ clipID: UUID, at timelineTime: Double, ripple: Bool = true) -> UUID? {
        var insertedClipID: UUID?

        mutateTrack(containing: clipID, normalizeTiming: ripple) { clips, index in
            let clip = clips[index]
            let minimumSegmentDuration = 0.25
            guard clip.duration > (minimumSegmentDuration * 2) else { return }

            let localSplit = timelineTime - clip.startTime
            let firstDuration = min(
                max(localSplit, minimumSegmentDuration),
                clip.duration - minimumSegmentDuration
            )
            let secondDuration = clip.duration - firstDuration
            guard secondDuration >= minimumSegmentDuration else { return }

            clips[index].duration = firstDuration

            let secondClip = TimelineClip(
                id: UUID(),
                assetID: clip.assetID,
                trackID: clip.trackID,
                lane: clip.lane,
                title: clip.title + " Part 2",
                startTime: clip.startTime + firstDuration,
                duration: secondDuration,
                sourceStart: clip.sourceStart + firstDuration,
                sourceDuration: clip.sourceDuration,
                volume: clip.volume,
                isMuted: clip.isMuted,
                speedMultiplier: clip.speedMultiplier
            )
            clips.insert(secondClip, at: index + 1)
            insertedClipID = secondClip.id
        }

        return insertedClipID
    }

    mutating func setClipVolume(_ clipID: UUID, volume: Double) {
        mutateTrack(containing: clipID) { clips, index in
            clips[index].volume = min(max(volume, 0), 2)
        }
    }

    mutating func setClipSpeed(_ clipID: UUID, speed: Double) {
        mutateTrack(containing: clipID) { clips, index in
            clips[index].speedMultiplier = min(max(speed, 0.1), 10.0)
        }
    }

    mutating func toggleClipMute(_ clipID: UUID) {
        mutateTrack(containing: clipID) { clips, index in
            clips[index].isMuted.toggle()
        }
    }

    mutating func deleteClip(_ clipID: UUID, ripple: Bool = true) {
        guard let clip = clip(for: clipID) else { return }
        timelineClips.removeAll { $0.id == clip.id }
        transitions.removeAll { $0.fromClipID == clip.id || $0.toClipID == clip.id }
        if ripple {
            normalizeTrack(clip.trackID)
        } else {
            sortTimelineClips()
        }
    }

    mutating func moveClip(_ clipID: UUID, direction: MoveDirection) {
        mutateTrack(containing: clipID) { clips, index in
            switch direction {
            case .left:
                guard index > 0 else { return }
                clips.swapAt(index, index - 1)
            case .right:
                guard index < clips.count - 1 else { return }
                clips.swapAt(index, index + 1)
            }
        }
    }

    mutating func moveClip(_ clipID: UUID, toIndex targetIndex: Int) {
        mutateTrack(containing: clipID) { clips, index in
            guard clips.count > 1 else { return }
            let clampedTarget = min(max(0, targetIndex), clips.count - 1)
            guard clampedTarget != index else { return }

            let clip = clips.remove(at: index)
            clips.insert(clip, at: clampedTarget)
        }
    }

    mutating func trimClipStart(_ clipID: UUID, delta: Double, ripple: Bool = true) {
        mutateTrack(containing: clipID, normalizeTiming: ripple) { clips, index in
            var clip = clips[index]
            let minDuration = 0.25

            if ripple {
                if delta > 0 {
                    let allowed = min(delta, clip.duration - minDuration)
                    clip.sourceStart += allowed
                    clip.duration -= allowed
                } else if delta < 0 {
                    let allowed = min(abs(delta), clip.sourceStart)
                    clip.sourceStart -= allowed
                    clip.duration += allowed
                }
            } else {
                if delta > 0 {
                    let allowed = min(delta, clip.duration - minDuration)
                    clip.sourceStart += allowed
                    clip.startTime += allowed
                    clip.duration -= allowed
                } else if delta < 0 {
                    let previousEnd = index > 0
                        ? clips[index - 1].startTime + clips[index - 1].duration
                        : 0
                    let maxLeadInByGap = max(0, clip.startTime - previousEnd)
                    let maxLeadInByTimeline = max(0, clip.startTime)
                    let allowed = min(abs(delta), clip.sourceStart, maxLeadInByGap, maxLeadInByTimeline)
                    clip.sourceStart -= allowed
                    clip.startTime -= allowed
                    clip.duration += allowed
                }
            }

            clips[index] = clip
        }
    }

    mutating func trimClipEnd(_ clipID: UUID, delta: Double, ripple: Bool = true) {
        mutateTrack(containing: clipID, normalizeTiming: ripple) { clips, index in
            var clip = clips[index]
            let minDuration = 0.25

            if ripple {
                if delta > 0 {
                    let available = max(0, clip.sourceDuration - (clip.sourceStart + clip.duration))
                    let allowed = min(delta, available)
                    clip.duration += allowed
                } else if delta < 0 {
                    let allowed = min(abs(delta), clip.duration - minDuration)
                    clip.duration -= allowed
                }
            } else {
                if delta > 0 {
                    let available = max(0, clip.sourceDuration - (clip.sourceStart + clip.duration))
                    let nextStart = index < clips.count - 1 ? clips[index + 1].startTime : .greatestFiniteMagnitude
                    let availableGap = max(0, nextStart - (clip.startTime + clip.duration))
                    let allowed = min(delta, available, availableGap)
                    clip.duration += allowed
                } else if delta < 0 {
                    let allowed = min(abs(delta), clip.duration - minDuration)
                    clip.duration -= allowed
                }
            }

            clips[index] = clip
        }
    }

    mutating func slipClipContent(_ clipID: UUID, by delta: Double) {
        mutateTrack(containing: clipID) { clips, index in
            var clip = clips[index]
            let maxSourceStart = max(0, clip.sourceDuration - clip.duration)
            clip.sourceStart = min(max(0, clip.sourceStart + delta), maxSourceStart)
            clips[index] = clip
        }
    }

    @discardableResult
    mutating func extractAudioFromClip(_ clipID: UUID, into trackKind: TrackKind = .voiceover) -> UUID? {
        guard let sourceClip = clip(for: clipID) else { return nil }
        guard let targetTrack = timelineTracks.first(where: { $0.kind == trackKind })
            ?? timelineTracks.first(where: { $0.kind == .voiceover })
            ?? timelineTracks.first(where: { $0.kind == .music })
        else {
            return nil
        }

        let extractedID = UUID()
        let extracted = TimelineClip(
            id: extractedID,
            assetID: sourceClip.assetID,
            trackID: targetTrack.id,
            lane: targetTrack.kind,
            title: sourceClip.title + " Audio",
            startTime: sourceClip.startTime,
            duration: sourceClip.duration,
            sourceStart: sourceClip.sourceStart,
            sourceDuration: sourceClip.sourceDuration,
            volume: min(max(sourceClip.volume, 0), 2),
            isMuted: false,
            speedMultiplier: 1.0
        )
        timelineClips.append(extracted)
        timelineClips.sort {
            if $0.trackID == $1.trackID {
                return $0.startTime < $1.startTime
            }
            return $0.lane.rawValue < $1.lane.rawValue
        }
        return extractedID
    }

    @discardableResult
    mutating func replaceClipWithSourceSegments(
        _ clipID: UUID,
        sourceSegments: [ClosedRange<Double>],
        minimumSegmentDuration: Double = 0.08
    ) -> [UUID] {
        var insertedIDs: [UUID] = []

        mutateTrack(containing: clipID) { clips, index in
            let sourceClip = clips[index]
            let clipStart = sourceClip.sourceStart
            let clipEnd = sourceClip.sourceStart + sourceClip.duration

            let normalizedSegments = sourceSegments
                .map { segment -> ClosedRange<Double>? in
                    let lower = max(clipStart, segment.lowerBound)
                    let upper = min(clipEnd, segment.upperBound)
                    guard upper - lower >= minimumSegmentDuration else { return nil }
                    return lower...upper
                }
                .compactMap { $0 }
                .sorted { $0.lowerBound < $1.lowerBound }

            guard !normalizedSegments.isEmpty else { return }

            clips.remove(at: index)

            var timelineCursor = sourceClip.startTime
            for (segmentIndex, segment) in normalizedSegments.enumerated() {
                let segmentDuration = segment.upperBound - segment.lowerBound
                let clipID = UUID()
                insertedIDs.append(clipID)

                let title = normalizedSegments.count > 1
                    ? "\(sourceClip.title) \(segmentIndex + 1)"
                    : sourceClip.title
                let replacement = TimelineClip(
                    id: clipID,
                    assetID: sourceClip.assetID,
                    trackID: sourceClip.trackID,
                    lane: sourceClip.lane,
                    title: title,
                    startTime: timelineCursor,
                    duration: segmentDuration,
                    sourceStart: segment.lowerBound,
                    sourceDuration: sourceClip.sourceDuration,
                    volume: sourceClip.volume,
                    isMuted: sourceClip.isMuted,
                    speedMultiplier: sourceClip.speedMultiplier
                )
                clips.insert(replacement, at: index + segmentIndex)
                timelineCursor += segmentDuration
            }
        }

        return insertedIDs
    }

    private mutating func mutateTrack(
        containing clipID: UUID,
        normalizeTiming: Bool = true,
        transform: (inout [TimelineClip], Int) -> Void
    ) {
        guard let clip = clip(for: clipID) else { return }

        var trackClips = clips(for: clip.trackID)
        guard let index = trackClips.firstIndex(where: { $0.id == clipID }) else { return }

        transform(&trackClips, index)
        writeTrack(trackClips, for: clip.trackID, normalizeTiming: normalizeTiming)
    }

    private mutating func normalizeTrack(_ trackID: UUID) {
        var trackClips = clips(for: trackID)
        var cursor = 0.0

        for index in trackClips.indices {
            trackClips[index].startTime = cursor
            cursor += trackClips[index].duration
        }

        writeTrack(trackClips, for: trackID, normalizeTiming: true)
    }

    private mutating func writeTrack(_ clips: [TimelineClip], for trackID: UUID, normalizeTiming: Bool = true) {
        timelineClips.removeAll { $0.trackID == trackID }

        var result = clips
        if normalizeTiming {
            // Preserve caller ordering (e.g. drag reorder) and only re-normalize timing.
            var cursor = 0.0
            for index in result.indices {
                result[index].startTime = cursor
                cursor += result[index].duration
            }
        }

        timelineClips.append(contentsOf: result)
        sortTimelineClips()
    }

    private mutating func sortTimelineClips() {
        timelineClips.sort {
            if $0.trackID == $1.trackID {
                return $0.startTime < $1.startTime
            }
            return $0.lane.rawValue < $1.lane.rawValue
        }
    }

    // MARK: - Transitions

    func transition(between fromClipID: UUID, and toClipID: UUID) -> ClipTransition? {
        transitions.first { $0.fromClipID == fromClipID && $0.toClipID == toClipID }
    }

    mutating func setTransition(from fromClipID: UUID, to toClipID: UUID, type: TransitionType, duration: Double = 0.5) {
        if let index = transitions.firstIndex(where: { $0.fromClipID == fromClipID && $0.toClipID == toClipID }) {
            if type == .none {
                transitions.remove(at: index)
            } else {
                transitions[index].type = type
                transitions[index].duration = max(0.1, min(2.0, duration))
            }
        } else if type != .none {
            transitions.append(ClipTransition(
                fromClipID: fromClipID,
                toClipID: toClipID,
                type: type,
                duration: max(0.1, min(2.0, duration))
            ))
        }
    }

    mutating func removeTransition(between fromClipID: UUID, and toClipID: UUID) {
        transitions.removeAll { $0.fromClipID == fromClipID && $0.toClipID == toClipID }
    }

    // MARK: - Markers

    @discardableResult
    mutating func addMarker(at time: Double, label: String, color: MarkerColor = .blue, note: String? = nil) -> UUID {
        let marker = TimelineMarker(time: max(0, time), label: label, color: color, note: note)
        markers.append(marker)
        markers.sort { $0.time < $1.time }
        return marker.id
    }

    mutating func removeMarker(_ id: UUID) {
        markers.removeAll { $0.id == id }
    }

    mutating func updateMarker(_ id: UUID, label: String? = nil, color: MarkerColor? = nil, note: String? = nil) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        if let label { markers[index].label = label }
        if let color { markers[index].color = color }
        if let note { markers[index].note = note }
    }

    mutating func clearMarkerNote(_ id: UUID) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[index].note = nil
    }
}

enum MoveDirection {
    case left
    case right
}
