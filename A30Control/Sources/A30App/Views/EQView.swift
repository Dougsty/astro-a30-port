import SwiftUI

/// Command Center EQ: preset library on the left, five vertical bars with dB boxes on the right.
struct EQView: View {
    let model: HeadsetModel

    private var isCustom: Bool { model.eq?.mode == EQMode.custom.rawValue }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Caps("Preset library", size: 14, color: Color(white: 0.8)).padding(.bottom, 12)
                Rectangle().fill(CC.line).frame(height: 1)
                ForEach(model.eqModes, id: \.self) { m in
                    CCRow(title: m.label, leading: "waveform.path", selected: model.eq?.mode == m.rawValue) { model.selectEQ(m) }
                }
                if !model.savedEQs.isEmpty {
                    Caps("Saved curves", size: 11, color: CC.dim).padding(.top, 14).padding(.bottom, 6)
                    ForEach(model.savedEQs) { s in
                        CCItemRow(title: s.name, leading: "slider.vertical.3", apply: { model.applySavedEQ(s) },
                                  remove: { model.savedEQs.removeAll { $0.id == s.id } })
                    }
                }
                Spacer()
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        CCButton(title: "Revert") { model.revertEQ() }
                        CCButton(title: "Reset flat") { model.resetFlat() }
                    }
                    CCButton(title: "Save curve as") {
                        if let n = Ask.name("Save the Custom curve as") { model.saveCurrentEQ(as: n) }
                    }
                }
                .disabled(!isCustom)
                .opacity(isCustom ? 1 : 0.5)
            }
            .frame(width: 280)

            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { i in BandBar(model: model, band: i).frame(maxWidth: .infinity) }
                }
                .allowsHitTesting(isCustom)
                .opacity(isCustom ? 1 : 0.45)
                if !isCustom { Caps("Select Custom to edit the bands", color: CC.dim) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.11, green: 0.11, blue: 0.11))
        }
    }
}

/// One Command Center band: "+5 dB" box, tall dark track with a grey fill from the bottom
/// and a white marker, frequency label. −12…+12 dB; drag, ↑/↓ keys or VoiceOver adjust.
struct BandBar: View {
    let model: HeadsetModel
    let band: Int

    private let range = EQSetting.gainRange
    private var value: Int {
        guard let b = model.eq?.bands, b.indices.contains(band) else { return 0 }
        return b[band]
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(value > 0 ? "+\(value)" : "\(value)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .frame(minWidth: 26)
                    .padding(.vertical, 3)
                    .background(CC.control)
                    .overlay(Rectangle().stroke(Color(white: 0.25), lineWidth: 1))
                Text("dB").font(.system(size: 11)).foregroundStyle(CC.muted)
            }
            GeometryReader { geo in
                let h = geo.size.height
                let frac = CGFloat(value - range.lowerBound) / CGFloat(range.count - 1)
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Color(white: 0.07)).frame(width: 12)
                    Rectangle().fill(Color(white: 0.42)).frame(width: 12, height: max(2, frac * h))
                    Rectangle().fill(Color.white).frame(width: 12, height: 2).offset(y: -(frac * h) + 1)
                }
                .frame(width: geo.size.width, height: h)
                .overlay(alignment: .center) {   // 0 dB tick
                    Rectangle().fill(Color(white: 0.5)).frame(width: 8, height: 1).offset(x: -14)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = 1 - min(max(g.location.y / h, 0), 1)
                    let v = range.lowerBound + Int((f * CGFloat(range.count - 1)).rounded())
                    if v != value { model.setBand(band, v) }
                })
            }
            Text(EQSetting.bandLabels[band]).font(.system(size: 11)).foregroundStyle(CC.muted)
        }
        .focusable()
        .focusEffectDisabled()   // keep ↑/↓ but no blue system focus ring
        .onKeyPress(.upArrow) { step(1) }
        .onKeyPress(.downArrow) { step(-1) }
        .accessibilityElement()
        .accessibilityLabel(EQSetting.bandLabels[band])
        .accessibilityValue("\(value) dB")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: _ = step(1)
            case .decrement: _ = step(-1)
            default: break
            }
        }
    }

    private func step(_ d: Int) -> KeyPress.Result {
        guard model.eq?.mode == EQMode.custom.rawValue else { return .ignored }
        model.setBand(band, min(max(value + d, range.lowerBound), range.upperBound))
        return .handled
    }
}
