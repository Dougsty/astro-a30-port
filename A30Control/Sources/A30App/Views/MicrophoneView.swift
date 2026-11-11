import SwiftUI

struct MicrophoneView: View {
    let model: HeadsetModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Caps("Microphone", size: 14, color: Color(white: 0.8)).padding(.bottom, 12)
                Rectangle().fill(CC.line).frame(height: 1)
                ForEach(Mic.allCases, id: \.self) { m in
                    CCRow(title: m.label, leading: m == .boom ? "mic" : "headphones", selected: model.micTab == m) { model.micTab = m }
                }
            }
            .frame(width: 280)

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Caps("Sidetone", size: 12)
                    SidetoneSlider(model: model, mic: model.micTab)
                    Text("How much of your own voice you hear in the headset.").font(.system(size: 11)).foregroundStyle(CC.dim)
                }
                Rectangle().fill(CC.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 0) {
                    Caps("Noise gate", size: 12).padding(.bottom, 4)
                    Text("How loud you must speak before the microphone picks you up.").font(.system(size: 11)).foregroundStyle(CC.dim)
                        .padding(.bottom, 8)
                    ForEach(NoiseGate.allCases, id: \.self) { g in
                        CCRow(title: g.label, selected: model.noiseGate[model.micTab] == g) { model.setNoiseGate(model.micTab, g) }
                    }
                }
                .disabled(model.noiseGate[model.micTab] == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

