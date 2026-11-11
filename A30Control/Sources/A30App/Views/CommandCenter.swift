// Look of the ASTRO Command Center: near-black canvas, #151515 panels, hairline rows,
// orange-red accent, uppercase labels with wide tracking.
import SwiftUI

enum CC {
    static let bg = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let panel = Color(red: 0.083, green: 0.083, blue: 0.083)
    static let control = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let line = Color.white.opacity(0.10)
    static let muted = Color(white: 0.60)
    static let dim = Color(white: 0.40)
    static let accent = Color(red: 1.0, green: 0.294, blue: 0.122)   // #ff4b1f
}

struct Caps: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = CC.muted
    init(_ text: String, size: CGFloat = 11, color: Color = CC.muted) { self.text = text; self.size = size; self.color = color }

    var body: some View {
        Text(text.uppercased()).font(.system(size: size, weight: .medium)).kerning(1.6).foregroundStyle(color)
    }
}

/// Flat grey uppercase button (REVERT / SAVE in the Command Center).
struct CCButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Caps(title, color: Color(white: 0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(CC.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Four slanted segments, filled by battery level.
struct BatteryBars: View {
    let percent: Int?

    var body: some View {
        let lit = percent.map { Int((Double($0) / 25).rounded(.up)) } ?? 0
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                Rectangle()
                    .fill(i < lit ? Color(white: 0.85) : Color(white: 0.30))
                    .frame(width: 6, height: 12)
                    .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.35, d: 1, tx: 4, ty: 0))
            }
        }
        .frame(width: 34, height: 12)
    }
}

/// Selectable list row with a hairline underneath (preset library, noise gate, …).
struct CCRow: View {
    let title: String
    var leading: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let leading { Image(systemName: leading).foregroundStyle(selected ? Color.white : CC.dim) }
                Caps(title, size: 13, color: selected ? .white : CC.muted)
                Spacer()
                if selected { Rectangle().fill(CC.accent).frame(width: 3, height: 14) }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 8)
            .background(selected ? CC.control : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(CC.line).frame(height: 1) }
    }
}

/// Row that applies something on click and has a remove (×) button.
struct CCItemRow: View {
    let title: String
    var leading: String? = nil
    let apply: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: apply) {
                HStack(spacing: 10) {
                    if let leading { Image(systemName: leading).foregroundStyle(CC.dim) }
                    Caps(title, size: 13, color: Color(white: 0.85))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: remove) { Image(systemName: "xmark").foregroundStyle(CC.dim) }
                .buttonStyle(.plain)
                .help("Remove")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(CC.line).frame(height: 1) }
    }
}
