import AppKit
import SwiftUI

/// The mark's state family — the ONLY drawing of the five states, on every
/// surface (identity rule, turn 11). Three voice bars standing on a typed
/// line that ends in a text cursor; the cursor is the state carrier:
///
///   idle         bars + line + cursor
///   recording    bars move with the voice; the cursor disappears
///   recognizing  the bars become dots on the line; the cursor dims
///   meeting      the cursor becomes a filled record dot (+ elapsed time)
///   attention    the cursor becomes an exclamation; the rest dims
///
/// Geometry is the identity sheet's, verbatim, in a 22×16 design space —
/// scaled, never redrawn, so the menu bar, the overlay and the pill can
/// not drift apart.
enum FamilyGlyph {

    /// The 22×16 design-space rects (x, y, w, h) with radius = w/2.
    /// Y grows DOWN here, as in the SVG source; drawing flips it.
    static let line: CGRect = CGRect(x: 2, y: 10.4, width: 15, height: 1.6)
    static let bars: [CGRect] = [
        CGRect(x: 3.6, y: 6.4, width: 1.8, height: 4),
        CGRect(x: 7.1, y: 3.4, width: 1.8, height: 7),
        CGRect(x: 10.6, y: 5.4, width: 1.8, height: 5),
    ]
    static let cursor = CGRect(x: 14.8, y: 4.4, width: 1.6, height: 7.6)
    /// Recognizing: the bars' positions become dots on the line.
    static let dotCenters: [CGPoint] = [
        CGPoint(x: 4.5, y: 7.4), CGPoint(x: 8, y: 7.4), CGPoint(x: 11.5, y: 7.4),
    ]
    static let dotRadius: CGFloat = 0.9
    /// Meeting: the record dot that replaces the cursor.
    static let recordDot = (center: CGPoint(x: 15.6, y: 6), radius: CGFloat(2.4))
    /// Attention: the exclamation that replaces the cursor.
    static let exclamationBar = CGRect(x: 14.8, y: 3, width: 1.8, height: 5.4)
    static let exclamationDot = (center: CGPoint(x: 15.7, y: 10.6), radius: CGFloat(1))
    static let designSize = CGSize(width: 22, height: 16)

    enum State {
        /// `level` 0…1 moves the bars (0 = resting profile).
        case recording(level: Double)
        /// `phase` 0,1,2… — which recognizing dot is lit brightest.
        case recognizing(phase: Int)
        case idle, meeting, attention
    }

    // MARK: - Menu bar (NSImage)

    /// The status-item image. Template (monochrome alpha) unless `color` is
    /// given — and the menu bar never gives one: template is what lets macOS
    /// invert it for dark menu bars and the open-menu highlight.
    static func menuBarImage(_ state: State, pointSize: CGFloat = 18,
                             color: NSColor? = nil) -> NSImage {
        let scale = pointSize / designSize.width
        let size = NSSize(width: designSize.width * scale,
                          height: designSize.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        let ink = color ?? .black
        draw(state, ink: ink, scale: scale, flipHeight: size.height)
        image.unlockFocus()
        image.isTemplate = color == nil
        return image
    }

    private static func fill(_ rect: CGRect, alpha: CGFloat, ink: NSColor,
                             scale: CGFloat, flipHeight: CGFloat) {
        ink.withAlphaComponent(alpha).setFill()
        let r = CGRect(x: rect.minX * scale,
                       y: flipHeight - (rect.maxY * scale),
                       width: rect.width * scale, height: rect.height * scale)
        let radius = min(r.width, r.height) / 2
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    private static func dot(_ center: CGPoint, radius: CGFloat, alpha: CGFloat,
                            ink: NSColor, scale: CGFloat, flipHeight: CGFloat) {
        ink.withAlphaComponent(alpha).setFill()
        let r = radius * scale
        NSBezierPath(ovalIn: CGRect(x: center.x * scale - r,
                                    y: flipHeight - center.y * scale - r,
                                    width: r * 2, height: r * 2)).fill()
    }

    private static func draw(_ state: State, ink: NSColor, scale: CGFloat,
                             flipHeight: CGFloat) {
        let dimmed: CGFloat = state.isAttention ? 0.45 : 1
        fill(line, alpha: dimmed, ink: ink, scale: scale, flipHeight: flipHeight)

        switch state {
        case .recognizing(let phase):
            // Bars become dots; the brightest one walks left to right.
            for (i, center) in dotCenters.enumerated() {
                let lit = (phase % dotCenters.count) == i
                dot(center, radius: dotRadius, alpha: lit ? 1 : 0.35,
                    ink: ink, scale: scale, flipHeight: flipHeight)
            }
            fill(cursor, alpha: 0.35, ink: ink, scale: scale, flipHeight: flipHeight)

        case .recording(let level):
            // The mark's own bars carry the voice: rest at 55/50/70% of their
            // height, full at level 1 — bottoms pinned to the line, exactly
            // the scaleY the identity sheet animates.
            let rest: [CGFloat] = [0.55, 0.5, 0.7]
            for (i, bar) in bars.enumerated() {
                let extent = rest[i] + (1 - rest[i]) * CGFloat(min(max(level, 0), 1))
                let h = bar.height * extent
                let scaled = CGRect(x: bar.minX, y: bar.maxY - h,
                                    width: bar.width, height: h)
                fill(scaled, alpha: 1, ink: ink, scale: scale, flipHeight: flipHeight)
            }
            // No cursor while recording — the bars ARE the state.

        case .idle:
            for bar in bars { fill(bar, alpha: 1, ink: ink, scale: scale, flipHeight: flipHeight) }
            fill(cursor, alpha: 1, ink: ink, scale: scale, flipHeight: flipHeight)

        case .meeting:
            for bar in bars { fill(bar, alpha: 1, ink: ink, scale: scale, flipHeight: flipHeight) }
            dot(recordDot.center, radius: recordDot.radius, alpha: 1,
                ink: ink, scale: scale, flipHeight: flipHeight)

        case .attention:
            for bar in bars { fill(bar, alpha: dimmed, ink: ink, scale: scale, flipHeight: flipHeight) }
            fill(exclamationBar, alpha: 1, ink: ink, scale: scale, flipHeight: flipHeight)
            dot(exclamationDot.center, radius: exclamationDot.radius, alpha: 1,
                ink: ink, scale: scale, flipHeight: flipHeight)
        }
    }
}

private extension FamilyGlyph.State {
    var isAttention: Bool { if case .attention = self { return true }; return false }
}

/// The same mark for SwiftUI surfaces (overlay header, pill). One Canvas, no
/// layout animation — redraws only when its inputs change (the house rule).
struct GlyphMark: View {
    var state: FamilyGlyph.State
    var color: Color
    var width: CGFloat = 18

    var body: some View {
        let scale = width / FamilyGlyph.designSize.width
        Canvas { context, _ in
            func fill(_ rect: CGRect, _ alpha: Double) {
                let r = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale)
                context.fill(Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2),
                             with: .color(color.opacity(alpha)))
            }
            func dot(_ center: CGPoint, _ radius: CGFloat, _ alpha: Double) {
                let r = radius * scale
                context.fill(Path(ellipseIn: CGRect(x: center.x * scale - r,
                                                    y: center.y * scale - r,
                                                    width: r * 2, height: r * 2)),
                             with: .color(color.opacity(alpha)))
            }
            let dimmed = { if case .attention = state { return 0.45 }; return 1.0 }()
            fill(FamilyGlyph.line, dimmed)
            switch state {
            case .recognizing(let phase):
                for (i, center) in FamilyGlyph.dotCenters.enumerated() {
                    dot(center, FamilyGlyph.dotRadius,
                        phase % FamilyGlyph.dotCenters.count == i ? 1 : 0.35)
                }
                fill(FamilyGlyph.cursor, 0.35)
            case .recording(let level):
                let rest: [CGFloat] = [0.55, 0.5, 0.7]
                for (i, bar) in FamilyGlyph.bars.enumerated() {
                    let extent = rest[i] + (1 - rest[i]) * CGFloat(min(max(level, 0), 1))
                    let h = bar.height * extent
                    fill(CGRect(x: bar.minX, y: bar.maxY - h, width: bar.width, height: h), 1)
                }
            case .idle:
                for bar in FamilyGlyph.bars { fill(bar, 1) }
                fill(FamilyGlyph.cursor, 1)
            case .meeting:
                for bar in FamilyGlyph.bars { fill(bar, 1) }
                dot(FamilyGlyph.recordDot.center, FamilyGlyph.recordDot.radius, 1)
            case .attention:
                for bar in FamilyGlyph.bars { fill(bar, dimmed) }
                fill(FamilyGlyph.exclamationBar, 1)
                dot(FamilyGlyph.exclamationDot.center, FamilyGlyph.exclamationDot.radius, 1)
            }
        }
        .frame(width: width,
               height: width * FamilyGlyph.designSize.height / FamilyGlyph.designSize.width)
    }
}
