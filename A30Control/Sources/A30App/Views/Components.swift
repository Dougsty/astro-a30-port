import SwiftUI

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThickMaterial))
        .padding(10)
    }
}

struct PowerOffOverlay: View {
    let seconds: Int
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "power").font(.system(size: 30)).foregroundStyle(Color(red: 1, green: 0.29, blue: 0.12))
            Text("Turning off in \(seconds)s").font(.title2.monospacedDigit())
            Text("Pause any audio: the headset powers down when idle.\nSleep mode goes back to Never when it reconnects.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

struct ConnectionOverlay: View {
    let error: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking for ASTRO A30…").font(.headline)
            if let why = error {
                Text(why).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text("Make sure the headset is on and connected to this Mac.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

extension View {
    /// Error banner on top, disconnected overlay while not connected.
    func headsetChrome(_ model: HeadsetModel) -> some View {
        overlay {
            if let s = model.powerOffRemaining {
                PowerOffOverlay(seconds: s) { model.cancelTurnOff() }
            } else if model.connection != .connected {
                ConnectionOverlay(error: model.lastConnectError)
            }
        }
        .overlay(alignment: .top) {
            if let b = model.banner { BannerView(text: b) { model.banner = nil } }
        }
    }
}

struct BatteryLabel: View {
    let battery: Battery?

    /// SF Symbols only has 0/25/50/75/100 battery levels: pick the nearest.
    static func symbol(_ percent: Int) -> String {
        "battery.\(min(max((percent + 12) / 25 * 25, 0), 100))"
    }

    var body: some View {
        if let b = battery {
            Label("\(b.percent)%", systemImage: b.isCharging ? "battery.100.bolt" : Self.symbol(b.percent))
                .monospacedDigit()
        } else {
            Label("—", systemImage: "battery.0")
        }
    }
}

struct SidetoneSlider: View {
    let model: HeadsetModel
    let mic: Mic

    var body: some View {
        HStack {
            Text("Sidetone")
            Slider(value: Binding(get: { Double(model.sidetone[mic] ?? 0) },
                                  set: { model.setSidetone(mic, Int($0)) }),
                   in: 0...100, step: 1)
            Text("\(model.sidetone[mic] ?? 0)%").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .disabled(model.sidetone[mic] == nil)
    }
}

/// 0…20 on the wire = game share (0 % … 100 %), like the official app.
struct BalanceSlider: View {
    let model: HeadsetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Chat")
                Slider(value: Binding(get: { Double(model.balance ?? 10) },
                                      set: { model.setBalance(Int($0)) }),
                       in: 0...20, step: 1)
                Text("Game")
            }
            .disabled(!model.dongle.connected || model.balance == nil)
            if !model.dongle.connected {
                Text("Connect the 2.4 GHz dongle to mix game and chat.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// iVolumeSet level 0…31 (same as the headset's wheel).
struct VolumeSlider: View {
    let model: HeadsetModel

    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.2")
            Slider(value: Binding(get: { Double(model.volume ?? 0) },
                                  set: { model.setVolume(Int($0)) }),
                   in: 0...31, step: 1)
            Text("\(model.volume ?? 0)").monospacedDigit().frame(width: 28, alignment: .trailing)
        }
        .disabled(model.volume == nil)
    }
}

struct LaunchAtLoginToggle: View {
    let model: HeadsetModel

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
    }
}
