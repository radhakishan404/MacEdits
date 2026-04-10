import SwiftUI

@main
struct MacEditsApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .frame(minWidth: 980, minHeight: 700)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            SupportCommands()
        }
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            switch appModel.screen {
            case .home:
                HomeView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            case .recording:
                if let workspace = appModel.currentWorkspace {
                    RecordingStudioView(workspace: workspace)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                } else {
                    HomeView()
                }
            case .editor:
                if let workspace = appModel.currentWorkspace {
                    EditorView(workspace: workspace)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                } else {
                    HomeView()
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appModel.screen)
        .background(AppTheme.windowBackground.ignoresSafeArea())
        .onAppear {
            appModel.refreshCrashReportPrompt()
        }
        .alert("Action Failed", isPresented: errorBinding, actions: {
            Button("OK", role: .cancel) {
                appModel.dismissError()
            }
        }, message: {
            Text(appModel.errorMessage ?? "Unknown error.")
        })
        .alert(
            "Unsaved Edits Found",
            isPresented: recoveryBinding,
            presenting: appModel.pendingRecoveryPrompt
        ) { _ in
            Button("Restore Autosave") {
                appModel.resolveRecoveryPrompt(useAutosave: true)
            }
            Button("Open Last Saved") {
                appModel.resolveRecoveryPrompt(useAutosave: false)
            }
            Button("Cancel", role: .cancel) {
                appModel.dismissRecoveryPrompt()
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .alert(
            "MacEdits Found a Crash Report",
            isPresented: crashBinding,
            presenting: appModel.pendingCrashReport
        ) { _ in
            Button("Report on GitHub") {
                appModel.reportPendingCrashOnGitHub()
            }
            Button("Email Support") {
                appModel.emailSupportForPendingCrash()
            }
            Button("Dismiss", role: .cancel) {
                appModel.dismissCrashReportPrompt()
            }
        } message: { crash in
            Text("Previous session appears to have crashed (\(crash.fileName)). Share it so we can fix it faster.")
        }
        .alert("Recovered Project", isPresented: noticeBinding, actions: {
            Button("OK", role: .cancel) {
                appModel.dismissNotice()
            }
        }, message: {
            Text(appModel.noticeMessage ?? "")
        })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { appModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    appModel.dismissError()
                }
            }
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: {
                appModel.noticeMessage != nil
                    && appModel.errorMessage == nil
                    && appModel.pendingRecoveryPrompt == nil
                    && appModel.pendingCrashReport == nil
            },
            set: { newValue in
                if !newValue {
                    appModel.dismissNotice()
                }
            }
        )
    }

    private var recoveryBinding: Binding<Bool> {
        Binding(
            get: { appModel.pendingRecoveryPrompt != nil && appModel.errorMessage == nil },
            set: { newValue in
                if !newValue {
                    appModel.dismissRecoveryPrompt()
                }
            }
        )
    }

    private var crashBinding: Binding<Bool> {
        Binding(
            get: {
                appModel.pendingCrashReport != nil
                    && appModel.errorMessage == nil
                    && appModel.pendingRecoveryPrompt == nil
                    && appModel.noticeMessage == nil
            },
            set: { newValue in
                if !newValue {
                    appModel.dismissCrashReportPrompt()
                }
            }
        )
    }
}

private struct SupportCommands: Commands {
    @Environment(AppModel.self) private var appModel

    var body: some Commands {
        CommandMenu("Support") {
            Button("Contact Support Email") {
                appModel.contactSupport()
            }
            Button("Report Bug on GitHub") {
                appModel.reportBugOnGitHub()
            }
            Divider()
            Button("Report Last Crash") {
                appModel.reportPendingCrashOnGitHub()
            }
            .disabled(appModel.pendingCrashReport == nil)
        }
    }
}
