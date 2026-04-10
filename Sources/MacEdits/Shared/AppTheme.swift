import SwiftUI

enum AppTheme {
    static let windowBackground = LinearGradient(
        colors: [
            Color(red: 0.025, green: 0.025, blue: 0.035),
            Color(red: 0.04, green: 0.035, blue: 0.05),
            Color(red: 0.018, green: 0.018, blue: 0.026),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let heroWash = RadialGradient(
        colors: [
            Color(red: 0.99, green: 0.39, blue: 0.27).opacity(0.22),
            Color(red: 0.98, green: 0.24, blue: 0.62).opacity(0.18),
            .clear,
        ],
        center: .topTrailing,
        startRadius: 30,
        endRadius: 900
    )

    static let editorGlow = RadialGradient(
        colors: [
            Color(red: 0.68, green: 0.21, blue: 0.95).opacity(0.12),
            Color(red: 0.99, green: 0.45, blue: 0.18).opacity(0.08),
            .clear,
        ],
        center: .top,
        startRadius: 20,
        endRadius: 760
    )

    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.59, green: 0.24, blue: 0.96),
            Color(red: 0.97, green: 0.16, blue: 0.49),
            Color(red: 0.99, green: 0.59, blue: 0.21),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let panelBackground = Color(red: 0.105, green: 0.105, blue: 0.13).opacity(0.97)
    static let subpanelBackground = Color.white.opacity(0.04)
    static let raisedBackground = Color.white.opacity(0.065)
    static let workspaceBackground = Color.black.opacity(0.22)
    static let timelineBackground = Color.black.opacity(0.2)
    static let hairline = Color.white.opacity(0.065)
    static let accent = Color(red: 0.27, green: 0.69, blue: 1.0)
    static let recordAccent = Color(red: 0.99, green: 0.34, blue: 0.32)
    static let importAccent = Color(red: 0.99, green: 0.72, blue: 0.24)
    static let openAccent = Color(red: 0.57, green: 0.84, blue: 0.45)
    static let secondaryText = Color.white.opacity(0.72)
    static let mutedText = Color.white.opacity(0.5)
    static let tertiaryText = Color.white.opacity(0.34)

    static func panel(cornerRadius: CGFloat = 28) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(panelBackground)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            )
    }

    static func subpanel(cornerRadius: CGFloat = 22) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(subpanelBackground)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            )
    }

    static func workspaceSurface(cornerRadius: CGFloat = 28) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(workspaceBackground)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            )
    }
}

struct FeatureBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
    }
}

struct SectionChip: View {
    let title: String
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }
}

struct MetricBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.raisedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
