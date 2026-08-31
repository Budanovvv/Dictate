import AppKit
import SwiftUI

/// The design tokens — the few values that used to be many.
///
/// Deliberately small. The 2026 audit of this window found eight corner radii,
/// three hover fills for one gesture, two monospace treatments for one kind of
/// timestamp and three selection languages — not because anyone chose them,
/// but because nobody had a place to look one up. This is that place.
///
/// What is deliberately NOT here: a spacing scale. The best-regarded shipping
/// Mac UIs tokenize color, type, radius and motion and leave padding to
/// optical judgment — a grid would repaint every hand-tuned inset in this
/// window for no visible gain. Hierarchy rule of the type system: emphasis
/// goes color role → weight → size, in that order; reach for a bigger size
/// last.
enum DS {

    // MARK: - Radii

    /// Fields, cards, row highlights, hover fills — every small container.
    /// One value, continuous curvature, everywhere.
    static let radius: CGFloat = 6
    /// Micro-chips (speaker chips): a 16pt-tall control at radius 6 reads as
    /// a pill that isn't one.
    static let radiusChip: CGFloat = 4
    /// Floating panels over other apps (the pill, the HUD).
    static let radiusPanel: CGFloat = 16

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
    static var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radiusChip, style: .continuous)
    }

    // MARK: - Fills

    /// The one hover value. A hover is a whisper; it is the same whisper on a
    /// turn, a section link, a chip and a source card.
    static let hoverFill = Color.primary.opacity(0.06)
    /// Resting fill for interactive cards that must read as present before
    /// hover (source rows, the contents block).
    static let restingFill = Color.primary.opacity(0.04)
    /// Custom selection tint, for the few places the system's list selection
    /// cannot reach (the pinned ask entry, ⌘A in the transcript). Everything
    /// inside a List keeps the system's own selection — never painted here.
    static let selectionFill = Color.accentColor.opacity(0.12)

    // MARK: - Motion

    /// Hover and selection feedback: in instantly, out in this. (The pattern
    /// every fast-feeling list ships: appear 0s, disappear ~150ms — arrowing
    /// through rows must never strobe.)
    static let fade: TimeInterval = 0.15
    /// Panel and disclosure reveals.
    static let reveal: TimeInterval = 0.25

    // MARK: - Type

    /// Every clock time, duration, count and percentage. `monospacedDigit`,
    /// not `monospaced`: digits align without the letterforms going
    /// typewriter (measured: proportional digits swing 38% in width).
    static let timestamp = Font.caption.monospacedDigit()

    // MARK: - The 13a specification (design handoff, 2026-08-27)

    /// One appearance-aware colour from two sRGB values.
    private static func paired(light: (Double, Double, Double),
                               dark: (Double, Double, Double),
                               alpha: (light: Double, dark: Double) = (1, 1)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: v.0 / 255, green: v.1 / 255, blue: v.2 / 255,
                           alpha: isDark ? alpha.dark : alpha.light)
        })
    }

    // Colour — one job each.
    /// Interaction: fills, selection, the caret. #0a6cff / #3d82e0 (dark
    /// redesign 2026-08-29: the vivid dark values read as glare — every dark
    /// pair is now the design's muted one; light is untouched).
    static let accent = paired(light: (10, 108, 255), dark: (61, 130, 224))
    /// Accent as SMALL TEXT (links, chips) — darker so 11 px clears 4.5:1.
    static let accentText = paired(light: (10, 92, 216), dark: (143, 184, 236))
    /// Your microphone's side of a call. Teal — a speaker name must not look
    /// tappable, so speakers left the accent hue entirely.
    static let you = paired(light: (15, 123, 108), dark: (87, 179, 162))
    /// The call's side. Violet.
    static let them = paired(light: (122, 68, 184), dark: (180, 154, 217))
    /// Translate mode's own hue (the second key), distinct from both.
    static let translate = paired(light: (138, 69, 200), dark: (180, 154, 217))
    /// Needs attention. Amber text that clears contrast on its own tint.
    static let warn = paired(light: (138, 83, 0), dark: (224, 165, 90))
    /// "Granted" and friends.
    static let good = paired(light: (20, 112, 47), dark: (48, 209, 88))
    /// Recording — red means this and nothing else (never a button fill).
    static let record = paired(light: (255, 69, 58), dark: (232, 117, 108))

    // Selection: a 12% accent tint with a 3 px accent edge — never a filled
    // row, so the list is not the loudest thing on screen.
    static let selectionTint = paired(light: (10, 108, 255), dark: (61, 130, 224),
                                      alpha: (0.12, 0.22))
    static let selectionEdge: CGFloat = 3

    // Type roles (spec: emphasis = colour role → weight → size, size last).
    /// Transcripts and answers: content larger than the chrome around it.
    /// The model's reading voice, at the global text scale — the size
    /// preference applies to the agent's answers as much as to transcripts
    /// (design turn 19: one preference, every reading surface).
    static var readingBody: Font { Font.system(size: TextScale.current.body) }
    static var readingLineSpacing: CGFloat { TextScale.current.extraLeading }
    /// The 72-character measure reading columns cap at.
    /// The reading column at the CURRENT text scale: the measure stays a
    /// constant ~70ch, so the column widens with the type and lines never
    /// get longer (design turn 19).
    static var readingMeasure: CGFloat { 620 * TextScale.current.body / 15 }
    static let windowTitle = Font.system(size: 13.5, weight: .semibold)
    static let helpText = Font.system(size: 11.5)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)

    /// The transcript's reading scale (design MeetingOutline: textSize).
    ///
    /// One knob, five numbers moving together: the reading text, its leading,
    /// the outline leaves, the speaker labels and the air between turns —
    /// everything that IS the reading. The chrome around it (title, meta,
    /// eyebrows, timestamps, tags) never moves: the design scales the words,
    /// not the window.
    enum TextScale: String, CaseIterable {
        case small, medium, large

        /// Reading text: transcript turns and the summary. Small sits well
        /// under the design's 13.5 — the owner wanted a real spread between
        /// the ends, with large staying put (2026-08-29).
        var body: CGFloat { raw(12.5, 15, 17.5) }

        /// Steps are RELATIVE to the system's resolved base size, so a
        /// macOS Accessibility text setting compounds with the choice here
        /// instead of being overridden by it (design turn 19).
        private static var systemFactor: CGFloat {
            NSFont.preferredFont(forTextStyle: .body).pointSize / 13
        }
        private func raw(_ s: CGFloat, _ m: CGFloat, _ l: CGFloat) -> CGFloat {
            let picked: CGFloat
            switch self { case .small: picked = s; case .medium: picked = m; case .large: picked = l }
            return (picked * Self.systemFactor).rounded()
        }
        /// The design's line-height, as the extra leading SwiftUI wants.
        /// Larger type carries a tighter ratio (1.7 / 1.65 / 1.6).
        var extraLeading: CGFloat {
            switch self {
            case .small: return body * 0.7
            case .medium: return body * 0.65
            case .large: return body * 0.6
            }
        }
        /// Outline leaf rows — the moments under the section heads.
        var leaf: CGFloat { raw(11, 13, 14.5) }
        /// The speaker's name in the gutter.
        var speaker: CGFloat { raw(10.5, 12, 13) }
        /// Vertical air between turns.
        var turnGap: CGFloat {
            switch self { case .small: return 10; case .medium: return 14; case .large: return 20 }
        }
        /// The "A" glyph in the switcher tray (11 / 12.5 / 14.5).
        var control: CGFloat {
            switch self { case .small: return 11; case .medium: return 12.5; case .large: return 14.5 }
        }

        // UserDefaults directly, not Settings.shared: inside this SwiftUI
        // file `Settings` is the framework's Settings scene. Same key the
        // Settings class owns (transcriptTextSize).
        static var current: TextScale {
            TextScale(rawValue: UserDefaults.standard.string(
                forKey: "transcriptTextSize") ?? "medium") ?? .medium
        }
    }
}

// MARK: - Interaction feedback (one vocabulary for hand-built controls)

/// Hover wash for hand-built rows and buttons: DS.hoverFill behind a rounded
/// shape, faded with DS.fade. One modifier so every control reacts alike —
/// a control with no reaction reads as a dead click (field report 2026-08-27).
struct HoverHighlight: ViewModifier {
    var radius: CGFloat = DS.radius
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(hovering ? DS.hoverFill : Color.clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: DS.fade), value: hovering)
    }
}

/// Hover emphasis for controls that carry their own solid fill (accent
/// capsules, keycaps) where a wash behind them would be invisible.
struct HoverEmphasis: ViewModifier {
    var scale: CGFloat = 1.04
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: DS.fade), value: hovering)
    }
}

extension View {
    func hoverHighlight(radius: CGFloat = DS.radius) -> some View {
        modifier(HoverHighlight(radius: radius))
    }
    func hoverEmphasis(scale: CGFloat = 1.04) -> some View {
        modifier(HoverEmphasis(scale: scale))
    }
}

// MARK: - Buttons and segments (the design's own controls)

/// The design's segmented control (MeetingOutline/Settings): a field-tinted
/// tray, radius 7, 2 pt padding; the active segment is a raised white card.
/// The system segmented picker draws a solid accent segment — a different
/// vocabulary, flagged by the owner (2026-08-28).
struct DSSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                DSSegment(label: option.label,
                          active: option.value == selection) {
                    withAnimation(.easeOut(duration: DS.fade)) {
                        selection = option.value
                    }
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

private struct DSSegment: View {
    let label: String
    let active: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            Text(label)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(.primary)
                                        : AnyShapeStyle(.secondary))
                .padding(.horizontal, 10)
                .frame(height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                              : hovering ? AnyShapeStyle(DS.hoverFill)
                              : AnyShapeStyle(Color.clear))
                        .shadow(color: .black.opacity(active ? 0.18 : 0),
                                radius: 1, y: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.fade), value: hovering)
    }
}

/// The transcript-text tray (design MeetingOutline): three "A" glyphs at
/// their own sizes, bottom-aligned in the same field tray DSSegmented wears.
/// Its own control rather than a DSSegmented because the segments differ in
/// FONT SIZE — that difference is the control's entire meaning.
struct DSTextSizeTray: View {
    @Binding var scale: DS.TextScale

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(DS.TextScale.allCases, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .help(L("Transcript text"))
    }

    private func segment(_ option: DS.TextScale) -> some View {
        DSTextSegment(option: option, active: option == scale,
                      name: accessibilityName(option)) {
            withAnimation(.easeOut(duration: DS.fade)) { scale = option }
        }
    }

    private func accessibilityName(_ option: DS.TextScale) -> String {
        switch option {
        case .small: return L("Smaller text")
        case .medium: return L("Standard text")
        case .large: return L("Larger text")
        }
    }
}

private struct DSTextSegment: View {
    let option: DS.TextScale
    let active: Bool
    let name: String
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            Text(verbatim: "A")
                .font(.system(size: option.control, weight: active ? .bold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(.primary)
                                        : AnyShapeStyle(.secondary))
                .padding(.bottom, 3)
                .frame(minWidth: 22)
                .frame(height: 21, alignment: .bottom)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                              : hovering ? AnyShapeStyle(DS.hoverFill)
                              : AnyShapeStyle(Color.clear))
                        .shadow(color: .black.opacity(active ? 0.18 : 0),
                                radius: 1, y: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: DS.fade), value: hovering)
        .accessibilityLabel(name)
    }
}

/// The design's buttons: a white card with a hairline (btnSm 23 pt / btn
/// 26 pt) or the accent primary. One style, sized by role — the system
/// bezels read as another app's chrome next to them (owner sweep 2026-08-28).
struct DSButtonStyle: ButtonStyle {
    enum Role { case small, regular, primary, wideSecondary, widePrimary }
    var role: Role = .regular
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let primary = role == .primary || role == .widePrimary
        let height: CGFloat = switch role {
        case .small: 23
        case .regular, .primary: 26
        case .wideSecondary, .widePrimary: 28
        }
        let radius: CGFloat = role == .small ? 6 : 7
        configuration.label
            .font(.system(size: role == .small ? 12 : 12.5,
                          weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, role == .small ? 11 : 14)
            .frame(height: height)
            .frame(maxWidth: (role == .wideSecondary || role == .widePrimary)
                   ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(primary ? AnyShapeStyle(DS.accent)
                                  : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                    .shadow(color: .black.opacity(primary ? 0 : 0.08),
                            radius: 0.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(primary ? 0 : 0.14),
                                  lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.75 : (hovering ? 0.92 : 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: DS.fade), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsSmall: DSButtonStyle { DSButtonStyle(role: .small) }
    static var dsRegular: DSButtonStyle { DSButtonStyle(role: .regular) }
    static var dsPrimary: DSButtonStyle { DSButtonStyle(role: .primary) }
    static var dsWide: DSButtonStyle { DSButtonStyle(role: .wideSecondary) }
    static var dsWidePrimary: DSButtonStyle { DSButtonStyle(role: .widePrimary) }
}

/// The skeleton placeholder (design: streaming rows). Deliberately STILL —
/// a repeatForever pulse costs a core share for its whole lifetime (the
/// measured house rule), and the ProgressView beside it already moves.
struct Shimmering: ViewModifier {
    func body(content: Content) -> some View { content.opacity(0.45) }
}
extension View {
    func shimmering() -> some View { modifier(Shimmering()) }
}
