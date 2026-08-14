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

    /// Who said it, by colour — the user is always the brand indigo, everyone
    /// else takes this list in the order they first speak.
    ///
    /// Only the first entry is a brand colour; the rest are deliberately the
    /// system's own semantic hues, which are already tuned per appearance (and
    /// follow Increase Contrast) instead of being a private set of RGB values
    /// that would have to be maintained for two themes by hand.
    ///
    /// The ORDER is the design. It used to be cyan, purple, teal, orange, pink:
    /// teal sat one step from the brand cyan and purple one step from the brand
    /// indigo, so in a six-person call the two pairs a reader most needed to
    /// tell apart were the two that looked most alike — and both pairs collapse
    /// completely under the common red-green deficiencies. This order spends the
    /// widest separations first, on the speakers a call is most likely to have:
    /// orange is the farthest thing from indigo and cyan in both hue and
    /// lightness and survives every kind of colour blindness, and each colour
    /// after it is placed as far as possible from the ones already in play.
    ///
    /// Colour is never the only cue in any case — every turn prints the
    /// speaker's name right next to the dot, so the palette has to make six
    /// people easy to scan, not to carry the identity on its own.
    static let speakerPalette: [Color] = [cyanLabel, .orange, .purple, .green, .pink, .brown]
}

/// Animated brand wave, as on the icon.
///
/// Two rules here are load-bearing, both learned the expensive way (the
/// meetings window burned 30% of a CPU core at rest because of this view).
///
/// 1. The bars are SCALED, not resized. A `repeatForever` animation on
///    `frame(height:)` is a layout animation: every display frame it
///    invalidates layout of the whole hosting view, and AppKit re-lays out the
///    entire window — a 250-turn transcript included — sixty times a second,
///    for a decorative mark. A transform animates on the render server and
///    costs the layout engine nothing.
/// 2. The animation is stopped when the view goes away. A `repeatForever`
///    animation never settles, so SwiftUI keeps asking for the next frame
///    (`NSHostingView.requestUpdate(after:)`) — and it kept doing so after this
///    view had been swapped out of the window, which is how a mark that was on
///    screen for one frame at open pinned the window's whole view graph awake
///    for as long as it stayed open.
/// 3. It moves only where the movement MEANS something. Measured on the
///    meetings window: an animating wave costs ~19% of a core for as long as
///    it is on screen — 20.3% drawn one way, 18.6% drawn another, i.e. the
///    price is animating at all in a window this size, not how the bars are
///    built. That is a fair price for "the app is listening to you" and an
///    absurd one for an ornament on an empty pane, so the decorative
///    placements ask for a still mark and no timer runs at all.
/// 4. It moves in STEPS the app itself takes, not on any animation curve and
///    not on a `TimelineView`. Measured, at the size the onboarding renders it:
///    the implicit-animation version cost 15.5% of a core (15.7% in the
///    onboarding window, 15.5% for the identical view in the meetings window —
///    the price follows the mark, not the window), and moving it onto a
///    `TimelineView(.periodic(by: 1/12))` made it WORSE, 23.3%. The same
///    experiment on the HUD's equalizer settled what is going on: a periodic
///    timeline over drawn content cost the same at 4 Hz as at 12 Hz, i.e. the
///    cadence you ask for buys you a coarse PICTURE, not coarse WORK — the
///    hosting view still wakes with the display. So the mark is redrawn only
///    when something changes: a 12 Hz timer nudges one piece of state, twelve
///    renders a second happen, and between them the app is asleep.
struct WaveMark: View {
    var height: CGFloat = 64
    /// Whether the wave moves. A still wave is the same mark and costs
    /// nothing; see rule 3.
    var animated: Bool = true
    /// Motion is what someone asks the system to reduce; the mark itself is
    /// not, so Reduce Motion gets the still logo rather than nothing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which step of the cycle is drawn. The only state here, and the only
    /// thing a beat of the timer touches.
    @State private var step = 0
    @State private var beat: Timer?
    private let profile: [CGFloat] = [0.34, 0.62, 1.0, 0.62, 0.34]
    /// One full swing of the wave.
    private static let cycle: Double = 1.6
    /// How often a moving mark is redrawn. Twelve steps a second across a
    /// 1.6 s cycle is ~19 samples per swing — smooth to the eye.
    static let tick: Double = 1.0 / 12

    var body: some View {
        mark(moving: animated && !reduceMotion)
            .onAppear(perform: start)
            .onDisappear(perform: stop)
    }

    private func start() {
        guard animated, !reduceMotion, beat == nil else { return }
        // .common, so the mark does not freeze while a menu or a scroll is
        // tracking — and invalidated on the way out, so nothing survives the
        // view that started it (rule 2).
        let timer = Timer(timeInterval: Self.tick, repeats: true) { _ in step &+= 1 }
        RunLoop.main.add(timer, forMode: .common)
        beat = timer
    }

    private func stop() {
        beat?.invalidate()
        beat = nil
        step = 0
    }

    private func mark(moving: Bool) -> some View {
        let width = height * 0.14
        let spacing = height * 0.11
        // ONE shape and ONE gradient for the whole mark. Not a gradient per
        // bar (the icon's ramp runs across the wave, not restarted inside each
        // bar), and not a mask over five stacked views either: the mark is
        // redrawn twelve times a second, and what a redraw costs is the number
        // of layers it touches, not the number of curves in the path.
        return WaveShape(heights: profile.indices.map {
                             max(4, height * profile[$0] * extent(moving: moving, bar: $0))
                         },
                         barWidth: width, spacing: spacing)
            .fill(Brand.gradient)
            .frame(width: width * 5 + spacing * 4, height: height)
    }

    /// How far bar `i` is extended at this instant. A travelling wave: one
    /// sine, sampled a sixth of a cycle later for each bar to the right, so the
    /// swing runs across the mark the way it does on the icon.
    private func extent(moving: Bool, bar i: Int) -> CGFloat {
        // A still mark stands at full height: it is the logo, not a frozen
        // frame of the animation.
        guard moving else { return 1 }
        let phase = Double(step) * Self.tick / Self.cycle - Double(i) * 0.16
        return CGFloat(0.775 + 0.225 * sin(phase * 2 * .pi))
    }
}

/// Every wave in the app, as ONE path: the mark in the onboarding, the level
/// meter in the meetings window and the HUD's equalizer are the same drawing at
/// different sizes, so the brand reads as one thing wherever it appears.
///
/// Why a path rather than a row of `Capsule` views, which is what all three
/// used to be. A bar's height is what changes, and there are only three ways to
/// change it: animate `frame(height:)` — a LAYOUT animation, the mine this
/// project has now stepped on three times; scale a capsule — which flattens its
/// round end-caps into ellipses and quietly squashes the logo; or draw the bars
/// yourself. Drawing them costs no layout at all (the shape's frame never
/// moves, only the path inside it), keeps every cap perfectly round at every
/// height, and — the number that decided it — is ONE layer instead of one per
/// bar. Measured on the HUD's 23-bar strip redrawn 12 times a second: a bar per
/// view cost 10.9% of a core, the same bars in one path 0.3%.
///
/// A height of 0 draws nothing, so a strip can be split into two paths (lit and
/// unlit) that still share one set of positions.
struct WaveShape: Shape {
    /// Height of each bar, in points, laid out from the leading edge.
    var heights: [CGFloat]
    var barWidth: CGFloat
    var spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX
        for height in heights {
            defer { x += barWidth + spacing }
            guard height > 0 else { continue }
            // A capsule cannot be shorter than it is round.
            let drawn = max(barWidth, height)
            path.addRoundedRect(
                in: CGRect(x: x, y: rect.midY - drawn / 2, width: barWidth, height: drawn),
                cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return path
    }
}
