import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var screen: AppScreen = .home
    var currentWorkspace: ProjectWorkspace?
    var errorMessage: String?
    var noticeMessage: String?
    var pendingRecoveryPrompt: ProjectRecoveryPrompt?
    var pendingEditorAssetSelectionID: UUID?

    let store: ProjectStore

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
    }

    func startNewRecording() {
        do {
            let workspace = try store.createProject(
                named: "Untitled Recording",
                origin: .recording
            )
            currentWorkspace = workspace
            noticeMessage = nil
            pendingRecoveryPrompt = nil
            pendingEditorAssetSelectionID = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                screen = .recording
            }
        } catch {
            present(error)
        }
    }

    func createProjectFromFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.message = "Choose the media files you want to start with."

        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }

        do {
            let workspace = try store.createProject(
                named: suggestedProjectName(from: panel.urls),
                origin: .importedFiles,
                importedAssetURLs: panel.urls
            )
            currentWorkspace = workspace
            noticeMessage = nil
            pendingRecoveryPrompt = nil
            pendingEditorAssetSelectionID = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                screen = .editor
            }
        } catch {
            present(error)
        }
    }

    func openExistingProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a Mac Edits project package."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        openProject(at: url)
    }

    func openRecentProject(_ project: ProjectSummary) {
        openProject(at: project.projectURL)
    }

    func moveToEditor(selectingAssetID: UUID? = nil) {
        guard let currentWorkspace else {
            return
        }

        do {
            self.currentWorkspace = try store.saveWorkspace(currentWorkspace)
            pendingEditorAssetSelectionID = selectingAssetID
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                screen = .editor
            }
        } catch {
            present(error)
        }
    }

    func moveToRecording() {
        guard currentWorkspace != nil else {
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            screen = .recording
        }
    }

    func returnHome() {
        currentWorkspace = nil
        noticeMessage = nil
        pendingRecoveryPrompt = nil
        pendingEditorAssetSelectionID = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            screen = .home
        }
    }

    func saveCurrentWorkspace(_ workspace: ProjectWorkspace) {
        do {
            let saved = try store.saveWorkspace(workspace)
            currentWorkspace = saved
        } catch {
            present(error)
        }
    }

    @discardableResult
    func attachRecordedAsset(from fileURL: URL) -> UUID? {
        attachAsset(from: fileURL, preferredType: .video, preferredTrackKind: .video)
    }

    @discardableResult
    func attachCompanionRecordedAsset(from fileURL: URL) -> UUID? {
        attachAsset(
            from: fileURL,
            preferredType: .video,
            preferredTrackKind: .video,
            insertIntoTimeline: false
        )
    }

    @discardableResult
    func attachVoiceoverAsset(from fileURL: URL, startTime: Double) -> UUID? {
        attachAsset(
            from: fileURL,
            preferredType: .audio,
            preferredTrackKind: .voiceover,
            timelineStartOverride: startTime
        )
    }

    @discardableResult
    private func attachAsset(
        from fileURL: URL,
        preferredType: AssetType,
        preferredTrackKind: TrackKind,
        timelineStartOverride: Double? = nil,
        insertIntoTimeline: Bool = true
    ) -> UUID? {
        guard let workspace = currentWorkspace else {
            return nil
        }

        let existingAssetIDs = Set(workspace.file.assets.map(\.id))
        do {
            let updatedWorkspace = try store.ingestAsset(
                from: fileURL,
                into: workspace,
                preferredType: preferredType,
                preferredTrackKind: preferredTrackKind,
                timelineStartOverride: timelineStartOverride,
                insertIntoTimeline: insertIntoTimeline
            )
            currentWorkspace = updatedWorkspace
            if let appended = updatedWorkspace.file.assets.first(where: { !existingAssetIDs.contains($0.id) }) {
                return appended.id
            }
            return updatedWorkspace.file.assets.last?.id
        } catch {
            present(error)
            return nil
        }
    }

    func importAssetsIntoCurrentProject() {
        guard let workspace = currentWorkspace else {
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.message = "Choose media to add to the current Mac Edits project."

        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }

        do {
            let updatedWorkspace = try store.ingestAssets(from: panel.urls, into: workspace)
            currentWorkspace = updatedWorkspace
        } catch {
            present(error)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissNotice() {
        noticeMessage = nil
    }

    func dismissRecoveryPrompt() {
        pendingRecoveryPrompt = nil
    }

    func resolveRecoveryPrompt(useAutosave: Bool) {
        guard let prompt = pendingRecoveryPrompt else { return }
        pendingRecoveryPrompt = nil
        let recoveryMessage = useAutosave ? store.autosaveRecoveryMessage(for: prompt.projectURL) : nil
        completeOpenProject(at: prompt.projectURL, preferAutosave: useAutosave, recoveryMessage: recoveryMessage)
    }

    private func openProject(at url: URL) {
        if let recovery = store.recoveryInfo(for: url) {
            pendingRecoveryPrompt = ProjectRecoveryPrompt(projectURL: url, message: recovery.message)
            return
        }
        let recoveryMessage = store.autosaveRecoveryMessage(for: url)
        completeOpenProject(at: url, preferAutosave: true, recoveryMessage: recoveryMessage)
    }

    private func completeOpenProject(at url: URL, preferAutosave: Bool, recoveryMessage: String?) {
        do {
            let workspace = try store.loadProject(at: url, preferAutosave: preferAutosave)
            currentWorkspace = workspace
            noticeMessage = recoveryMessage
            pendingEditorAssetSelectionID = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                screen = .editor
            }
        } catch {
            if let projectError = error as? ProjectStoreError, projectError == .invalidProjectPackage {
                store.removeRecentProject(at: url)
            }
            present(error)
        }
    }

    private func suggestedProjectName(from urls: [URL]) -> String {
        guard let firstURL = urls.first else {
            return "Untitled Project"
        }

        return firstURL.deletingPathExtension().lastPathComponent.capitalized
    }

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

enum AppScreen {
    case home
    case recording
    case editor
}

struct ProjectRecoveryPrompt: Identifiable, Hashable {
    let id = UUID()
    let projectURL: URL
    let message: String
}
