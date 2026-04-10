import AVFoundation
import Foundation
import Observation
import SwiftUI

// MARK: - Shared Editor State (Task 1.3: EditorView split)
@MainActor
@Observable
final class EditorEnvironment {
    // Layout
    var isRailCollapsed: Bool = false
    var isInspectorVisible: Bool = true

    // Undo / Redo (Task 5.1)
    private var undoStack: [ProjectWorkspace] = []
    private var redoStack: [ProjectWorkspace] = []
    private let maxUndoDepth = 40

    func pushUndo(_ workspace: ProjectWorkspace) {
        undoStack.append(workspace)
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo(current: ProjectWorkspace) -> ProjectWorkspace? {
        guard !undoStack.isEmpty else { return nil }
        redoStack.append(current)
        return undoStack.removeLast()
    }

    func redo(current: ProjectWorkspace) -> ProjectWorkspace? {
        guard !redoStack.isEmpty else { return nil }
        undoStack.append(current)
        return redoStack.removeLast()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
}
