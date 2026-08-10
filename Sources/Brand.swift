import SwiftUI
import AppKit

/// Brand colors from the app icon (indigo → cyan).
enum Brand {
    static let indigo = Color(red: 0.30, green: 0.35, blue: 0.95)
    static let cyan   = Color(red: 0.20, green: 0.75, blue: 1.00)

    /// Indigo as a LABEL colour. The icon indigo is tuned for a gradient on
    /// white; as small text on a near-black background it reads muddy, so
    /// the dark appearance gets a lightened variant. Use this for text and
    /// chips, and the plain `indigo` for fills and gradients.
    static let indigoLabel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.58, green: 0.62, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.30, green: 0.35, blue: 0.95, alpha: 1)
    })

    /// Same idea for cyan: the icon cyan is too pale on white for small text.
    static let cyanLabel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.80, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.06, green: 0.55, blue: 0.82, alpha: 1)
    })

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
