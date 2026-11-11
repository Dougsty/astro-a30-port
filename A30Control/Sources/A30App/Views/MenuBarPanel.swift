import SwiftUI
import AppKit

/// Menu bar panel: rounded cards with an icon column, a label line and the control under it
/// (same layout as macOS-style mixer panels).
struct MenuBarPanel: View {
    let model: HeadsetModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.name).font(.headline)
                Spacer()
                BatteryLabel(battery: model.battery)
            }
            .padding(.horizontal, 4)

            if model.connection == .connected {
                card {
                    sliderRow("speaker.wave.2", "Volume",
                              Binding(get: { Double(model.volume ?? 0) }, set: { model.setVolume(Int($0)) }),
                              0...31, model.volume.map { "\($0)" })
                        .disabled(model.volume == nil)
                    row("slider.vertical.3", "Equalizer") { presets }
                        .disabled(model.eq == nil)
                }
                card {
                    sliderRow("mic", "Sidetone",
                              Binding(get: { Double(model.sidetone[.boom] ?? 0) }, set: { model.setSidetone(.boom, Int($0)) }),
                              0...100, model.sidetone[.boom].map { "\($0)%" })
                        .disabled(model.sidetone[.boom] == nil)
                    row("gamecontroller", "Game mix") {
                        slider(Binding(get: { Double(model.balance ?? 10) }, set: { model.setBalance(Int($0)) }),
                               0...20, model.dongle.connected ? model.balance.map { "\($0 * 5)%" } : nil)
                            .disabled(!model.dongle.connected || model.balance == nil)
                        if !model.dongle.connected {
                            Text("Connect the 2.4 GHz dongle to mix game and chat.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    turnOffRow
                }
            } else {
                card { Text("Looking for ASTRO A30…").foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            if let b = model.banner { Text(b).font(.caption).foregroundStyle(.yellow).padding(.horizontal, 4) }

            HStack(spacing: 10) {
                panelButton("macwindow", "Open window") {
                    NSApp.setActivationPolicy(.regular)   // Dock icon while the window is open
                    NSApp.activate()
                    openWindow(id: "main")
                }
                panelButton("xmark.circle", "Quit") { AppDelegate.quitForReal() }
            }
        }
        .padding(10)
        .frame(width: 330)
        .preferredColorScheme(.dark)
    }

    // MARK: rows

    private var presets: some View {
        VStack(spacing: 6) {
            ForEach(Array(stride(from: 0, to: model.eqModes.count, by: 3)), id: \.self) { i in
                HStack(spacing: 6) {
                    ForEach(model.eqModes[i..<min(i + 3, model.eqModes.count)], id: \.self) { m in
                        let on = model.eq?.mode == m.rawValue
                        Button { model.selectEQ(m) } label: {
                            Text(m.label.replacingOccurrences(of: "Astro ", with: ""))
                                .font(.system(size: 12, weight: on ? .semibold : .regular))
                                .lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(on ? CC.accent : Color.white.opacity(0.08)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private var turnOffRow: some View {
        if let s = model.powerOffRemaining {
            HStack {
                icon("power")
                Text("Turning off in \(s)s").monospacedDigit()
                Spacer()
                Button("Cancel") { model.cancelTurnOff() }
            }
        } else {
            HStack {
                icon("power")
                Text("Turn off headset")
                Spacer()
                Button("Turn off") { model.turnOff() }
            }
        }
    }

    /// Icon column + title line, content underneath aligned with the title.
    private func row<C: View>(_ symbol: String, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 8) {
            icon(symbol)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                content()
            }
        }
    }

    private func sliderRow(_ symbol: String, _ title: String, _ v: Binding<Double>,
                           _ range: ClosedRange<Double>, _ text: String?) -> some View {
        row(symbol, title) { slider(v, range, text) }
    }

    private func slider(_ v: Binding<Double>, _ range: ClosedRange<Double>, _ text: String?) -> some View {
        HStack(spacing: 8) {
            Slider(value: v, in: range, step: 1).controlSize(.small)
            Text(text ?? "—").monospacedDigit().font(.system(size: 12)).frame(width: 36, alignment: .trailing)
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
    }

    private func panelButton(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
