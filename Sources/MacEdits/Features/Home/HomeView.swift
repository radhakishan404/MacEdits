import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var searchText = ""
    @State private var hoveredProjectID: UUID?

    private let gridColumns = [
        GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 14),
    ]

    private var filteredProjects: [ProjectSummary] {
        let projects = appModel.store.recentProjects
        guard !searchText.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                mainContent
            }
            if !hasCompletedOnboarding {
                OnboardingFlowView(
                    onComplete: {
                        hasCompletedOnboarding = true
                    },
                    onStartRecording: {
                        appModel.startNewRecording()
                    },
                    onImportFootage: {
                        appModel.createProjectFromFiles()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(20)
            }
        }
        .background(
            ZStack {
                AppTheme.windowBackground
                AppTheme.heroWash
            }
            .ignoresSafeArea()
        )
    }

    // MARK: - Left Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Logo area
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.accentGradient)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "film.stack")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mac Edits")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Desktop Reel Studio")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(AppTheme.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider().overlay(AppTheme.hairline)

            // Create actions
            VStack(alignment: .leading, spacing: 4) {
                Text("CREATE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(AppTheme.tertiaryText)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)

                SidebarAction(
                    title: "New Recording",
                    icon: "record.circle.fill",
                    tint: AppTheme.recordAccent,
                    isHero: true,
                    accessibilityLabel: "Create a new recording project"
                ) {
                    appModel.startNewRecording()
                }

                SidebarAction(
                    title: "Import Footage",
                    icon: "square.and.arrow.down.on.square.fill",
                    tint: AppTheme.importAccent,
                    accessibilityLabel: "Create project by importing media"
                ) {
                    appModel.createProjectFromFiles()
                }

                SidebarAction(
                    title: "Open Project",
                    icon: "folder.fill",
                    tint: AppTheme.openAccent,
                    accessibilityLabel: "Open existing project"
                ) {
                    appModel.openExistingProject()
                }
            }
            .padding(.bottom, 12)

            Divider().overlay(AppTheme.hairline)

            // Stats
            VStack(alignment: .leading, spacing: 8) {
                Text("OVERVIEW")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(AppTheme.tertiaryText)
                    .padding(.top, 14)

                StatRow(label: "Projects", value: "\(appModel.store.recentProjects.count)")
                StatRow(label: "Format", value: "9:16 Reels")
                StatRow(label: "Engine", value: "Local-First")
            }
            .padding(.horizontal, 20)

            Spacer()

            // Version
            Text("v1.0 Beta")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(width: 220)
        .background(
            AppTheme.panelBackground
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(AppTheme.hairline)
                        .frame(width: 1)
                }
        )
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.tertiaryText)
                    TextField("Search projects...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.hairline, lineWidth: 1)
                )
                .accessibilityLabel("Search projects")

                Spacer()

                Text("\(filteredProjects.count) project\(filteredProjects.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Projects grid
            if filteredProjects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        ForEach(filteredProjects) { project in
                            Button {
                                appModel.openRecentProject(project)
                            } label: {
                                ProjectCard(
                                    project: project,
                                    isHovered: hoveredProjectID == project.id
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovered in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    hoveredProjectID = isHovered ? project.id : nil
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(AppTheme.accentGradient.opacity(0.15))
                        .frame(width: 100, height: 100)
                    Image(systemName: "film.stack")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                }

                VStack(spacing: 8) {
                    Text("Welcome to Mac Edits")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Create your first reel by recording or importing footage")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }

                Button {
                    appModel.startNewRecording()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill")
                        Text("Start Recording")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(AppTheme.accentGradient)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start recording")

                Button {
                    appModel.createProjectFromFiles()
                } label: {
                    Text("or Import Footage")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Import footage")
            }
            .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar Action Button

private struct SidebarAction: View {
    let title: String
    let icon: String
    let tint: Color
    var isHero: Bool = false
    var accessibilityLabel: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(isHero ? 0.18 : 0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.horizontal, 4)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

// MARK: - Stat Row

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Project Card

private struct ProjectCard: View {
    let project: ProjectSummary
    let isHovered: Bool
    private var thumbnailService: ThumbnailService { ThumbnailService.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail area
            ZStack(alignment: .topLeading) {
                if let thumb = thumbnailService.thumbnail(for: project.projectURL) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 160)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.3)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        )
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accentColor.opacity(0.25),
                                    accentColor.opacity(0.08),
                                    Color.black.opacity(0.3),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 160)
                }

                // Origin badge
                HStack(spacing: 5) {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                    Text(project.origin.rawValue.capitalized)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial.opacity(0.6))
                .clipShape(Capsule())
                .padding(10)

                // Play icon overlay
                if thumbnailService.thumbnail(for: project.projectURL) != nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(isHovered ? 0.9 : 0.5))
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                            Spacer()
                        }
                        Spacer()
                    }
                } else {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.white.opacity(0.2))
                            Spacer()
                        }
                        Spacer()
                    }
                }
            }
            .frame(height: 160)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(project.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    Text("~")
                    Text(project.projectURL.lastPathComponent)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.06 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isHovered ? AppTheme.accent.opacity(0.3) : AppTheme.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(isHovered ? 1.02 : 1)
        .shadow(color: isHovered ? AppTheme.accent.opacity(0.1) : .clear, radius: 12, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.name), \(project.origin.rawValue), updated \(project.updatedAt.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityHint("Opens project in editor")
    }

    private var accentColor: Color {
        switch project.origin {
        case .recording: return AppTheme.recordAccent
        case .importedFiles: return AppTheme.importAccent
        case .mixed: return AppTheme.openAccent
        }
    }
}
