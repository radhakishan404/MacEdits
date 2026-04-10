import SwiftUI

struct OnboardingFlowView: View {
    let onComplete: () -> Void
    let onStartRecording: () -> Void
    let onImportFootage: () -> Void

    @State private var stepIndex = 0

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            title: "Record Instantly",
            message: "Use New Recording to capture camera footage with timer and aspect guides.",
            symbol: "record.circle.fill"
        ),
        OnboardingStep(
            title: "Edit On Timeline",
            message: "Split at playhead, right-click clips, add markers, and scrub fast with keyboard shortcuts.",
            symbol: "timeline.selection"
        ),
        OnboardingStep(
            title: "Export Reel",
            message: "Pick your preset and export a reels-ready file locally from the editor.",
            symbol: "square.and.arrow.up.fill"
        ),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Quick Tour")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("Step \(stepIndex + 1) of \(steps.count)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)
                }

                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.accentGradient.opacity(0.18))
                        Image(systemName: currentStep.symbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(currentStep.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(currentStep.message)
                            .font(.system(size: 14))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if stepIndex == 0 {
                    HStack(spacing: 10) {
                        Button("Start Recording") {
                            onComplete()
                            onStartRecording()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Import Footage") {
                            onComplete()
                            onImportFootage()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                HStack {
                    Button("Skip Tour") {
                        onComplete()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityLabel("Skip onboarding tour")

                    Spacer()

                    if stepIndex > 0 {
                        Button("Back") {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                stepIndex -= 1
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Go to previous onboarding step")
                    }

                    Button(stepIndex == steps.count - 1 ? "Finish" : "Next") {
                        if stepIndex == steps.count - 1 {
                            onComplete()
                        } else {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                stepIndex += 1
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(stepIndex == steps.count - 1 ? "Finish onboarding" : "Go to next onboarding step")
                }
            }
            .padding(24)
            .frame(width: 560)
            .background(AppTheme.panel(cornerRadius: 26))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(AppTheme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Onboarding tour")
        }
    }

    private var currentStep: OnboardingStep {
        steps[stepIndex]
    }
}

private struct OnboardingStep {
    let title: String
    let message: String
    let symbol: String
}
