import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

struct ProjectRecoveryInfo: Hashable {
    let message: String
}

@Observable
final class ProjectStore {
    private final class DurationLoadResult: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var resolvedValue: Double = 5.0

        func setValue(_ value: Double) {
            lock.lock()
            resolvedValue = value
            lock.unlock()
        }

        func value() -> Double {
            lock.lock()
            defer { lock.unlock() }
            return resolvedValue
        }
    }

    private(set) var recentProjects: [ProjectSummary] = []

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let autosavePrefix = "snapshot-"
    private let autosaveMaxSnapshots = 20

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        loadRecentProjects()
    }

    func createProject(
        named rawName: String,
        origin: ProjectOrigin,
        importedAssetURLs: [URL] = []
    ) throws -> ProjectWorkspace {
        let name = sanitizedName(from: rawName)
        let projectID = UUID()
        let rootURL = try projectsDirectory()
        let projectURL = rootURL.appendingPathComponent(
            "\(name)-\(projectID.uuidString.prefix(6)).macedits",
            isDirectory: true
        )

        try makeProjectDirectories(at: projectURL)

        var file = ReelProjectFile(
            id: projectID,
            name: name,
            createdAt: Date(),
            updatedAt: Date(),
            origin: origin,
            notes: "Mac Edits project.",
            assets: [],
            timelineTracks: [
                ProjectTrack(id: UUID(), kind: .video, displayName: "Video"),
                ProjectTrack(id: UUID(), kind: .music, displayName: "Music"),
                ProjectTrack(id: UUID(), kind: .voiceover, displayName: "Voiceover"),
                ProjectTrack(id: UUID(), kind: .captions, displayName: "Captions"),
            ],
            timelineClips: [],
            textOverlays: [],
            styleSettings: .default,
            exportPreset: .reels1080
        )

        if !importedAssetURLs.isEmpty {
            file.assets = try copyAssets(importedAssetURLs, into: projectURL)
            file.timelineClips = buildInitialTimelineClips(
                for: file.assets,
                tracks: file.timelineTracks,
                in: projectURL
            )
        }

        let summary = ProjectSummary(
            id: projectID,
            name: name,
            projectURL: projectURL,
            createdAt: file.createdAt,
            updatedAt: file.updatedAt,
            origin: origin
        )

        let workspace = ProjectWorkspace(summary: summary, file: file)
        try save(workspace)
        addRecent(summary)
        return workspace
    }

    func loadProject(at projectURL: URL, preferAutosave: Bool = true) throws -> ProjectWorkspace {
        let fileURL = metadataURL(for: projectURL)
        let autosaveURL = latestAutosaveURL(for: projectURL)

        guard fileManager.fileExists(atPath: fileURL.path()) || autosaveURL != nil else {
            throw ProjectStoreError.invalidProjectPackage
        }

        let candidateURLs = orderedLoadCandidates(primary: fileURL, autosave: autosaveURL, preferAutosave: preferAutosave)
        var loadedFile: ReelProjectFile?
        var lastError: Error?

        for candidate in candidateURLs {
            guard fileManager.fileExists(atPath: candidate.path()) else { continue }
            do {
                let data = try Data(contentsOf: candidate)
                loadedFile = try decoder.decode(ReelProjectFile.self, from: data)
                break
            } catch {
                lastError = error
            }
        }

        guard let file = loadedFile else {
            throw lastError ?? ProjectStoreError.invalidProjectPackage
        }

        let summary = ProjectSummary(
            id: file.id,
            name: file.name,
            projectURL: projectURL,
            createdAt: file.createdAt,
            updatedAt: file.updatedAt,
            origin: file.origin
        )
        let workspace = ProjectWorkspace(summary: summary, file: file)
        addRecent(summary)
        return workspace
    }

    func recoveryInfo(for projectURL: URL) -> ProjectRecoveryInfo? {
        let primaryURL = metadataURL(for: projectURL)
        guard let autosaveURL = latestAutosaveURL(for: projectURL) else {
            return nil
        }
        guard fileManager.fileExists(atPath: primaryURL.path()) else {
            return nil
        }

        let primaryDate = (try? primaryURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let autosaveDate = (try? autosaveURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        guard autosaveDate > primaryDate else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        let message = """
        A newer autosave exists.
        Autosave: \(formatter.string(from: autosaveDate))
        Last saved: \(formatter.string(from: primaryDate))
        """
        return ProjectRecoveryInfo(message: message)
    }

    func autosaveRecoveryMessage(for projectURL: URL) -> String? {
        let primaryURL = metadataURL(for: projectURL)
        guard let autosaveURL = latestAutosaveURL(for: projectURL) else {
            return nil
        }

        let autosaveDate = (try? autosaveURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        guard fileManager.fileExists(atPath: primaryURL.path()) else {
            return "Recovered from autosave snapshot captured on \(formatter.string(from: autosaveDate))."
        }

        let primaryDate = (try? primaryURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        guard autosaveDate > primaryDate else {
            return nil
        }

        return "Recovered newer autosave from \(formatter.string(from: autosaveDate)) instead of project file from \(formatter.string(from: primaryDate))."
    }

    func removeRecentProject(at projectURL: URL) {
        let updated = recentProjects.filter { $0.projectURL != projectURL }
        guard updated.count != recentProjects.count else { return }
        recentProjects = updated
        persistRecentProjects()
    }

    func saveWorkspace(_ workspace: ProjectWorkspace) throws -> ProjectWorkspace {
        var updated = workspace
        updated.file.updatedAt = Date()
        updated.summary.updatedAt = updated.file.updatedAt
        try save(updated)
        do {
            try saveAutosaveSnapshot(for: updated)
        } catch {
            // Autosave is best-effort to avoid blocking core save flow.
        }
        addRecent(updated.summary)
        return updated
    }

    func ingestAsset(
        from sourceURL: URL,
        into workspace: ProjectWorkspace,
        preferredType: AssetType? = nil,
        preferredTrackKind: TrackKind? = nil,
        timelineStartOverride: Double? = nil,
        insertIntoTimeline: Bool = true
    ) throws -> ProjectWorkspace {
        var updatedWorkspace = workspace
        let mediaDirectory = workspace.summary.projectURL.appendingPathComponent("media", isDirectory: true)
        let fileName = uniqueMediaFileName(for: sourceURL, in: mediaDirectory)
        let destinationURL = mediaDirectory.appendingPathComponent(fileName)

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let asset = ProjectAsset(
            id: UUID(),
            type: preferredType ?? assetType(for: sourceURL),
            fileName: fileName,
            originalName: sourceURL.lastPathComponent,
            importedAt: Date()
        )
        updatedWorkspace.file.assets.append(asset)
        if insertIntoTimeline {
            appendTimelineClip(
                for: asset,
                in: &updatedWorkspace.file,
                projectURL: workspace.summary.projectURL,
                preferredTrackKind: preferredTrackKind,
                timelineStartOverride: timelineStartOverride
            )
        }
        if updatedWorkspace.file.origin == .recording, preferredType != .audio {
            updatedWorkspace.file.origin = .mixed
        }
        updatedWorkspace.summary.origin = updatedWorkspace.file.origin
        return try saveWorkspace(updatedWorkspace)
    }

    func ingestAssets(
        from sourceURLs: [URL],
        into workspace: ProjectWorkspace
    ) throws -> ProjectWorkspace {
        var updated = workspace
        for url in sourceURLs {
            updated = try ingestAsset(from: url, into: updated)
        }
        return updated
    }

    private func save(_ workspace: ProjectWorkspace) throws {
        let fileURL = metadataURL(for: workspace.summary.projectURL)
        let data = try encoder.encode(workspace.file)
        try data.write(to: fileURL, options: .atomic)
    }

    private func copyAssets(_ urls: [URL], into projectURL: URL) throws -> [ProjectAsset] {
        let mediaDirectory = projectURL.appendingPathComponent("media", isDirectory: true)

        return try urls.map { sourceURL in
            let fileName = uniqueMediaFileName(for: sourceURL, in: mediaDirectory)
            let destinationURL = mediaDirectory.appendingPathComponent(fileName)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)

            return ProjectAsset(
                id: UUID(),
                type: assetType(for: sourceURL),
                fileName: fileName,
                originalName: sourceURL.lastPathComponent,
                importedAt: Date()
            )
        }
    }

    private func makeProjectDirectories(at projectURL: URL) throws {
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: projectURL.appendingPathComponent("media", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: projectURL.appendingPathComponent("cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: projectURL.appendingPathComponent("autosave", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func projectsDirectory() throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ProjectStoreError.documentsDirectoryUnavailable
        }

        let projectsURL = documents.appendingPathComponent("Mac Edits Projects", isDirectory: true)
        if !fileManager.fileExists(atPath: projectsURL.path()) {
            try fileManager.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        }
        return projectsURL
    }

    private func recentsFileURL() throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ProjectStoreError.appSupportUnavailable
        }

        let directory = appSupport.appendingPathComponent("MacEdits", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path()) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        return directory.appendingPathComponent("recent-projects.json")
    }

    private func metadataURL(for projectURL: URL) -> URL {
        projectURL.appendingPathComponent("project.json")
    }

    private func autosaveDirectoryURL(for projectURL: URL) -> URL {
        projectURL.appendingPathComponent("autosave", isDirectory: true)
    }

    private func orderedLoadCandidates(primary: URL, autosave: URL?, preferAutosave: Bool) -> [URL] {
        guard let autosave else {
            return [primary]
        }

        guard preferAutosave else {
            return [primary, autosave]
        }

        let primaryDate = (try? primary.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let autosaveDate = (try? autosave.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast

        if autosaveDate >= primaryDate {
            return [autosave, primary]
        }

        return [primary, autosave]
    }

    private func saveAutosaveSnapshot(for workspace: ProjectWorkspace) throws {
        let autosaveDirectory = autosaveDirectoryURL(for: workspace.summary.projectURL)
        if !fileManager.fileExists(atPath: autosaveDirectory.path()) {
            try fileManager.createDirectory(at: autosaveDirectory, withIntermediateDirectories: true)
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let snapshotURL = autosaveDirectory
            .appendingPathComponent("\(autosavePrefix)\(timestamp)")
            .appendingPathExtension("json")

        let data = try encoder.encode(workspace.file)
        try data.write(to: snapshotURL, options: .atomic)
        pruneAutosaveSnapshots(in: autosaveDirectory)
    }

    private func latestAutosaveURL(for projectURL: URL) -> URL? {
        let directory = autosaveDirectoryURL(for: projectURL)
        guard fileManager.fileExists(atPath: directory.path()) else { return nil }

        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent.hasPrefix(autosavePrefix) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private func pruneAutosaveSnapshots(in directory: URL) {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let snapshots = urls
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent.hasPrefix(autosavePrefix) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        guard snapshots.count > autosaveMaxSnapshots else { return }
        for staleURL in snapshots.dropFirst(autosaveMaxSnapshots) {
            try? fileManager.removeItem(at: staleURL)
        }
    }

    private func buildInitialTimelineClips(
        for assets: [ProjectAsset],
        tracks: [ProjectTrack],
        in projectURL: URL
    ) -> [TimelineClip] {
        var clips: [TimelineClip] = []
        for asset in assets {
            appendTimelineClip(
                for: asset,
                in: &clips,
                tracks: tracks,
                projectURL: projectURL
            )
        }
        return clips
    }

    private func appendTimelineClip(
        for asset: ProjectAsset,
        in file: inout ReelProjectFile,
        projectURL: URL,
        preferredTrackKind: TrackKind? = nil,
        timelineStartOverride: Double? = nil
    ) {
        appendTimelineClip(
            for: asset,
            in: &file.timelineClips,
            tracks: file.timelineTracks,
            projectURL: projectURL,
            preferredTrackKind: preferredTrackKind,
            timelineStartOverride: timelineStartOverride
        )
    }

    private func appendTimelineClip(
        for asset: ProjectAsset,
        in clips: inout [TimelineClip],
        tracks: [ProjectTrack],
        projectURL: URL,
        preferredTrackKind: TrackKind? = nil,
        timelineStartOverride: Double? = nil
    ) {
        guard let track = preferredTrack(for: asset.type, in: tracks, preferredTrackKind: preferredTrackKind) else {
            return
        }

        let duration = resolvedDuration(for: asset, projectURL: projectURL)
        let startTime = timelineStartOverride ?? (clips
            .filter { $0.trackID == track.id }
            .map { $0.startTime + $0.duration }
            .max() ?? 0)

        clips.append(
            TimelineClip(
                id: UUID(),
                assetID: asset.id,
                trackID: track.id,
                lane: track.kind,
                title: asset.originalName,
                startTime: startTime,
                duration: duration
            )
        )
    }

    private func preferredTrack(
        for type: AssetType,
        in tracks: [ProjectTrack],
        preferredTrackKind: TrackKind? = nil
    ) -> ProjectTrack? {
        if let preferredTrackKind, let preferred = tracks.first(where: { $0.kind == preferredTrackKind }) {
            return preferred
        }

        switch type {
        case .video, .image:
            return tracks.first(where: { $0.kind == .video })
        case .audio:
            return tracks.first(where: { $0.kind == .music })
        case .unknown:
            return nil
        }
    }

    private func resolvedDuration(for asset: ProjectAsset, projectURL: URL) -> Double {
        let url = projectURL.appendingPathComponent("media", isDirectory: true).appendingPathComponent(asset.fileName)

        switch asset.type {
        case .image:
            return 3.0
        case .video, .audio:
            let timeout = DispatchTime.now() + .seconds(2)
            let result = DurationLoadResult()

            Task.detached(priority: .utility) { [url] in
                defer { result.semaphore.signal() }
                let mediaAsset = AVURLAsset(url: url)
                do {
                    let duration = try await mediaAsset.load(.duration)
                    let seconds = duration.seconds
                    if seconds.isFinite, seconds > 0 {
                        result.setValue(seconds)
                    }
                } catch {
                    // Keep default fallback duration.
                }
            }

            _ = result.semaphore.wait(timeout: timeout)
            return result.value()
        case .unknown:
            return 5.0
        }
    }

    private func assetType(for url: URL) -> AssetType {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return .unknown
        }

        if type.conforms(to: .movie) {
            return .video
        }
        if type.conforms(to: .audio) {
            return .audio
        }
        if type.conforms(to: .image) {
            return .image
        }

        return .unknown
    }

    private func uniqueMediaFileName(for sourceURL: URL, in directory: URL) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var candidate = sourceURL.lastPathComponent
        var suffix = 1

        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path()) {
            candidate = "\(baseName)-\(suffix).\(ext)"
            suffix += 1
        }

        return candidate
    }

    private func sanitizedName(from rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "Untitled Project" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let filtered = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return filtered.replacingOccurrences(of: "  ", with: " ")
    }

    private func loadRecentProjects() {
        do {
            let url = try recentsFileURL()
            guard fileManager.fileExists(atPath: url.path()) else {
                recentProjects = []
                return
            }

            let data = try Data(contentsOf: url)
            let decoded = try decoder.decode([ProjectSummary].self, from: data)
            recentProjects = decoded.filter {
                let projectPath = $0.projectURL.path()
                guard fileManager.fileExists(atPath: projectPath) else { return false }
                let metadataPath = metadataURL(for: $0.projectURL).path()
                return fileManager.fileExists(atPath: metadataPath)
            }
            persistRecentProjects()
        } catch {
            recentProjects = []
        }
    }

    private func addRecent(_ summary: ProjectSummary) {
        var updated = recentProjects.filter { $0.projectURL != summary.projectURL }
        updated.insert(summary, at: 0)
        recentProjects = Array(updated.prefix(12))
        persistRecentProjects()
    }

    private func persistRecentProjects() {
        do {
            let url = try recentsFileURL()
            let data = try encoder.encode(recentProjects)
            try data.write(to: url, options: .atomic)
        } catch {
            // Keep recent projects best-effort to avoid blocking core flows.
        }
    }
}

enum ProjectStoreError: LocalizedError, Equatable {
    case documentsDirectoryUnavailable
    case appSupportUnavailable
    case invalidProjectPackage

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Mac Edits could not access your Documents directory."
        case .appSupportUnavailable:
            return "Mac Edits could not access Application Support."
        case .invalidProjectPackage:
            return "The selected folder is not a valid Mac Edits project."
        }
    }
}
