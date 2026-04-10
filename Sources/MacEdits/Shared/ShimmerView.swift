import SwiftUI

struct ShimmerView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.04),
                    Color.white.opacity(0.12),
                    Color.white.opacity(0.04)
                ]),
                startPoint: .init(x: phase - 0.5, y: 0.5),
                endPoint: .init(x: phase + 0.5, y: 0.5)
            )
            .frame(width: width * 3)
            .offset(x: -width)
        }
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = 2
            }
        }
    }
}

struct ShimmerTile: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                ShimmerView()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
    }
}
