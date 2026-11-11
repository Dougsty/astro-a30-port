import SwiftUI
import AppKit

/// Command Center–style window: header (logo, battery, settings), headset row with tabs,
/// then the selected tab's panel.
struct MainWindow: View {
    let model: HeadsetModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(CC.line).frame(height: 1)
            deviceRow
            Group {
                switch model.pane {
                case .equalizer: EQView(model: model)
                case .microphone: MicrophoneView(model: model)
                case .mix: MixView(model: model)
                case .extras: ExtrasView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CC.panel)
            .padding([.horizontal, .bottom], 14)
        }
        .background(CC.bg)
        .foregroundStyle(Color.white)
        .tint(CC.accent)
        .headsetChrome(model)
        .frame(width: 980, height: 660)   // fixed size (see AppDelegate: no resize, no full screen)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = Bundle.main.image(forResource: "logo") {
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit().frame(height: 26)
            }
            Rectangle().fill(Color(white: 0.30)).frame(width: 1, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Caps("A30", size: 12)
                Caps("Control", size: 12)
            }
            Spacer()
            if let b = model.battery {
                Text("\(b.percent)%").font(.system(size: 13)).foregroundStyle(CC.muted)
                if b.isCharging { Image(systemName: "bolt.fill").foregroundStyle(CC.muted) }
            }
            BatteryBars(percent: model.battery?.percent)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)       // below the traffic lights (hidden title bar), left-aligned with the rest
        .padding(.bottom, 12)
    }

    private var deviceRow: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "headphones").font(.system(size: 40, weight: .light)).foregroundStyle(Color(white: 0.75))
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name.uppercased()).font(.system(size: 17, weight: .semibold)).foregroundStyle(CC.accent)
                Text("HEADSET FW VERSION: \(model.firmware) · SERIAL \(model.serial)").font(.system(size: 11)).foregroundStyle(Color(white: 0.85))
            }
            .fixedSize()
            Spacer()
            ForEach(Pane.allCases) { tab($0) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func tab(_ p: Pane) -> some View {
        let on = model.pane == p
        return Button { model.pane = p } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: p.icon)
                    Caps(p.rawValue, color: on ? CC.accent : Color(white: 0.85))
                }
                .lineLimit(1)
                .fixedSize()   // never wrap a tab label
                .foregroundStyle(on ? CC.accent : Color(white: 0.85))
                // caret pointing at the panel, like the Command Center
                Image(systemName: "triangle.fill").font(.system(size: 8)).foregroundStyle(on ? CC.panel : Color.clear)
                    .offset(y: 16)
            }
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MixView: View {
    let model: HeadsetModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Caps("Mix", size: 14, color: Color(white: 0.8)).padding(.bottom, 12)
                Rectangle().fill(CC.line).frame(height: 1)
                info("Volume", model.volume.map { "\($0) / 31" } ?? "—")
                info("Balance", model.balance.map { "\($0 * 5)% game" } ?? "—")
                info("Dongle", model.dongle.connected ? "Connected" : "Not connected")
            }
            .frame(width: 280)

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Caps("Volume", size: 12)
                    VolumeSlider(model: model)
                    Toggle(isOn: Binding(get: { model.audioMuted == true }, set: { model.setAudioMuted($0) })) {
                        Caps("Mute headset audio", size: 11)
                    }
                    .toggleStyle(.switch)
                    .disabled(model.audioMuted == nil)
                    Text("Same 0–31 scale as the headset's volume wheel.").font(.system(size: 11)).foregroundStyle(CC.dim)
                }
                Rectangle().fill(CC.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    Caps("Game / chat balance", size: 12)
                    BalanceSlider(model: model)
                }
                Rectangle().fill(CC.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    Caps("Base station mode", size: 12).padding(.bottom, 6)
                    CCRow(title: "PC", selected: model.dongle.connected && !model.dongle.hostType) { model.setDongleXbox(false) }
                    CCRow(title: "Xbox", selected: model.dongle.connected && model.dongle.hostType) { model.setDongleXbox(true) }
                    Text("Host type of the 2.4 GHz dongle. Needs the dongle connected.").font(.system(size: 11)).foregroundStyle(CC.dim).padding(.top, 6)
                }
                .disabled(!model.dongle.connected)
                .opacity(model.dongle.connected ? 1 : 0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack {
            Caps(k, size: 12)
            Spacer()
            Text(v).font(.system(size: 13))
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(CC.line).frame(height: 1) }
    }
}
