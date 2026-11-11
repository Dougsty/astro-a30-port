import SwiftUI

/// Things the official app doesn't do: EQ per app, notifications.
struct ExtrasView: View {
    let model: HeadsetModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Caps("Profiles", size: 14, color: Color(white: 0.8)).padding(.bottom, 12)
                Rectangle().fill(CC.line).frame(height: 1)
                ForEach(model.profiles) { p in
                    CCItemRow(title: p.name, leading: "person.crop.square", apply: { model.applyProfile(p) },
                              remove: { model.profiles.removeAll { $0.id == p.id } })
                }
                if model.profiles.isEmpty {
                    Text("Save EQ, sidetone, noise gate and balance together, then apply them in one click.")
                        .font(.system(size: 11)).foregroundStyle(CC.dim).padding(.vertical, 10)
                }
                CCButton(title: "Save current as profile") {
                    if let n = Ask.name("Profile name") { model.saveProfile(as: n) }
                }
                .padding(.top, 12)
                Spacer()
                Text("Mic mute changes and low battery (20%, 10%) show as macOS notifications.")
                    .font(.system(size: 11)).foregroundStyle(CC.dim)
            }
            .frame(width: 280)

            VStack(alignment: .leading, spacing: 0) {
                Caps("EQ per app", size: 12).padding(.bottom, 4)
                Text("When one of these apps comes to the front, the EQ switches; leaving it restores the previous preset.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 11)).foregroundStyle(CC.dim).padding(.bottom, 10)
                ForEach(model.appRules) { rule in
                    HStack {
                        Caps(rule.name, size: 13, color: .white)
                        Spacer()
                        Menu {
                            ForEach(EQMode.allCases, id: \.self) { m in
                                Button(m.label) { setMode(rule, m) }
                            }
                        } label: {
                            Caps(EQMode(rawValue: rule.mode)?.label ?? "?", size: 12, color: CC.accent)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button { model.appRules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "xmark").foregroundStyle(CC.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Remove")
                    }
                    .padding(.vertical, 9).padding(.horizontal, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(CC.line).frame(height: 1) }
                }
                if model.appRules.isEmpty {
                    Caps("No apps yet", color: CC.dim).padding(.vertical, 12).padding(.horizontal, 8)
                }
                CCButton(title: "Add app") { Extras.pickApp(model) }
                    .frame(width: 180)
                    .padding(.top, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setMode(_ rule: AppEQRule, _ m: EQMode) {
        guard let i = model.appRules.firstIndex(of: rule) else { return }
        model.appRules[i].mode = m.rawValue
    }
}
