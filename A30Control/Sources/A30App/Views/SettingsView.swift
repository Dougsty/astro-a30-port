import SwiftUI

struct SettingsView: View {
    let model: HeadsetModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Caps("Device", size: 14, color: Color(white: 0.8)).padding(.bottom, 12)
                Rectangle().fill(CC.line).frame(height: 1)
                info("Name", model.name)
                info("Firmware", model.firmware)
                info("Serial", model.serial)
                Spacer()
                CCButton(title: "Rename headset") {
                    if let n = Ask.name("Headset name (shown in Bluetooth)", initial: model.name) { model.rename(n) }
                }
                .padding(.bottom, 8)
                CCButton(title: "Turn off headset") { model.turnOff() }
                    .padding(.bottom, 8)
                CCButton(title: "Factory reset") { model.showResetAlert = true }
            }
            .frame(width: 280)

            VStack(alignment: .leading, spacing: 0) {
                Caps("Sleep mode", size: 12).padding(.bottom, 6)
                ForEach(SleepTimer.allCases, id: \.self) { t in
                    CCRow(title: t.label, selected: model.sleep == t) { model.setSleep(t) }
                }
                Caps("Tones", size: 12).padding(.top, 20).padding(.bottom, 6)
                ForEach(Tones.allCases, id: \.self) { t in
                    CCRow(title: t.label, selected: model.tones == t) { model.setTones(t) }
                }
                HStack {
                    Caps("Open at login", size: 12)
                    Spacer()
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                .padding(.top, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Factory reset the headset?",
               isPresented: Binding(get: { model.showResetAlert }, set: { model.showResetAlert = $0 })) {
            Button("Continue", role: .destructive) { model.resetText = ""; model.showResetSheet = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases all headset settings; you may need to re-pair it.")
        }
        .sheet(isPresented: Binding(get: { model.showResetSheet }, set: { model.showResetSheet = $0 })) {
            ResetSheet(model: model)
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack {
            Caps(k, size: 12)
            Spacer()
            Text(v).font(.system(size: 13)).textSelection(.enabled)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(CC.line).frame(height: 1) }
    }
}

private struct ResetSheet: View {
    let model: HeadsetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Type RESET to confirm").font(.headline)
            TextField("RESET", text: Binding(get: { model.resetText }, set: { model.resetText = $0 }))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { model.showResetSheet = false; model.resetText = "" }
                    .keyboardShortcut(.cancelAction)
                Button("Factory reset", role: .destructive) { model.factoryReset() }
                    .disabled(model.resetText != "RESET")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
