import SwiftUI

/// Brand colors from the app icon (indigo → cyan).
enum Brand {
    static let indigo = Color(red: 0.30, green: 0.35, blue: 0.95)
    static let cyan   = Color(red: 0.20, green: 0.75, blue: 1.00)

    static let gradient = LinearGradient(
        colors: [indigo, cyan], startPoint: .top, endPoint: .bottom)
    static let gradientDiagonal = LinearGradient(
        colors: [indigo, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Animated brand wave, as on the icon.
struct WaveMark: View {
    var height: CGFloat = 64
    @State private var animate = false
    private let profile: [CGFloat] = [0.34, 0.62, 1.0, 0.62, 0.34]

    var body: some View {
        HStack(spacing: height * 0.11) {
            ForEach(profile.indices, id: \.self) { i in
                Capsule()
                    .fill(Brand.gradient)
                    .frame(width: height * 0.14,
                           height: max(4, height * profile[i] * (animate ? 1.0 : 0.55)))
                    .animation(.easeInOut(duration: 0.85)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.13), value: animate)
            }
        }
        .frame(height: height)
        .onAppear { animate = true }
    }
}
