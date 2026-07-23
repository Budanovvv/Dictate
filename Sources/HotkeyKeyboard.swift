import SwiftUI

/// A compact, spatial schematic of the keys that are SAFE to hold while talking —
/// the F-row and the bottom modifier row, where the sensible push-to-talk keys
/// live (right ⌥, right ⌘, fn…). Research-backed choice: we deliberately DON'T
/// draw a full keyboard — the alpha block is exactly where ANSI/ISO layouts
/// diverge, and character keys aren't safe anyway (our event tap is listen-only,
/// so a letter key would BOTH type and trigger). Showing only the safe zone turns
/// "which key is allowed?" from a post-hoc warning into a visible constraint.
///
/// The two current bindings light up in place (dictation = its tint, translate =
/// its tint), left/right modifiers sit on their real sides of the space bar, and
/// clicking a cap assigns it to whichever target is armed. Physical press-to-set
/// is handled by the parent via KeyCapture — this is the click half of the hybrid.
struct HotkeyKeyboard: View {
    let dictationCode: Int
    let translateCode: Int?
    let dictationTint: Color
    let translateTint: Color
    /// Called when a safe cap is clicked; hands back the keycode and its base name.
    let onPick: (Int, String) -> Void

    private struct Cap: Identifiable {
        let code: Int
        let glyph: String
        let side: String?      // "L"/"R" for modifiers, nil otherwise
        let units: CGFloat     // relative width
        let selectable: Bool
        var id: Int { code }
    }

    // F1…F12. (F13–F15 exist but are absent on most keyboards — omit.)
    private let fRow: [Cap] = [
        (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
        (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
    ].map { Cap(code: $0.0, glyph: $0.1, side: nil, units: 1, selectable: true) }

    // Bottom row, left→right as on a real MacBook: fn ⌃ ⌥ ⌘ [space] ⌘ ⌥.
    // Space is drawn for context but isn't selectable (not a safe hold key).
    private let modRow: [Cap] = [
        Cap(code: 63, glyph: "🌐", side: "fn", units: 1, selectable: true),
        Cap(code: 59, glyph: "⌃", side: "L", units: 1, selectable: true),
        Cap(code: 58, glyph: "⌥", side: "L", units: 1, selectable: true),
        Cap(code: 55, glyph: "⌘", side: "L", units: 1.2, selectable: true),
        Cap(code: 49, glyph: "space", side: nil, units: 3, selectable: false),
        Cap(code: 54, glyph: "⌘", side: "R", units: 1.2, selectable: true),
        Cap(code: 61, glyph: "⌥", side: "R", units: 1, selectable: true),
    ]

    private let unit: CGFloat = 34
    private let gap: CGFloat = 5

    var body: some View {
        VStack(spacing: gap + 2) {
            row(fRow, height: 26, fontSize: 11)
            row(modRow, height: 42, fontSize: 16)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Safe keys to hold: function row and modifiers"))
    }

    private func row(_ caps: [Cap], height: CGFloat, fontSize: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(caps) { cap in
                keycap(cap, height: height, fontSize: fontSize)
                    .frame(width: unit * cap.units + gap * (cap.units - 1))
            }
        }
    }

    @ViewBuilder
    private func keycap(_ cap: Cap, height: CGFloat, fontSize: CGFloat) -> some View {
        let boundTint = tint(for: cap.code)
        let content = VStack(spacing: 0) {
            // fn/globe as a monochrome SF Symbol so it tints with the others
            // (a colour emoji would stand out among the ⌘⌥⌃ glyphs).
            if cap.code == 63 {
                Image(systemName: "globe")
                    .font(.system(size: fontSize, weight: .semibold))
            } else {
                Text(cap.glyph)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.5).lineLimit(1)
            }
            if let side = cap.side, side != "fn" {
                Text(side).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(capBackground(bound: boundTint, selectable: cap.selectable))
        .foregroundStyle(boundTint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))

        if cap.selectable {
            Button {
                onPick(cap.code, KeyNames.baseName(forKeyCode: cap.code))
            } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel(KeyNames.displayName(KeyNames.baseName(forKeyCode: cap.code)))
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(accessibilityValue(for: cap.code))
        } else {
            content.opacity(0.5)   // space: context only
        }
    }

    private func capBackground(bound: Color?, selectable: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        return ZStack {
            if let bound {
                shape.fill(bound)
            } else {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                shape.strokeBorder(.quaternary, lineWidth: 1)
            }
        }
    }

    private func tint(for code: Int) -> Color? {
        if code == dictationCode { return dictationTint }
        if let t = translateCode, code == t { return translateTint }
        return nil
    }

    private func accessibilityValue(for code: Int) -> String {
        if code == dictationCode { return L("Dictation key") }
        if let t = translateCode, code == t { return L("Translate key") }
        return ""
    }
}
