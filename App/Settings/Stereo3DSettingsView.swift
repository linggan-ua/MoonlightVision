//
//  Stereo3DSettingsView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  Real-time 2D→3D tuning. The master on/off switch is the stream's Stereo 3D
//  control; these rows carry the conversion tuning ported from the the 3D pipeline /
//  the 3D pipeline pipeline.
//

import SwiftUI

struct Stereo3DSettingsView: View {
    @Bindable private var settings = StreamSettingsStore.shared
    @ObservedObject private var realtime3D = Realtime3DSettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Stereo 3D", isOn: $settings.stereoSBS)

                Picker("Scheme", selection: $realtime3D.scheme) {
                    ForEach(LSRealtimeStereoScheme.allCases, id: \.self) { scheme in
                        Text(LocalizedStringKey(scheme.tileTitle)).tag(scheme)
                    }
                }

                Picker("Depth Model", selection: $realtime3D.model) {
                    Text("Scheme Default").tag(LSRealtimeDepthModel?.none)
                    ForEach(LSRealtimeDepthModel.allCases, id: \.self) { model in
                        Text(LocalizedStringKey(model.tileTitle)).tag(Optional(model))
                    }
                }

                Picker("Depth Rate", selection: $realtime3D.depthRate) {
                    Text("Scheme Default").tag(Double?.none)
                    Text("Unlimited").tag(Double?.some(0))
                    Text("60/s").tag(Double?.some(60))
                    Text("30/s").tag(Double?.some(30))
                    Text("20/s").tag(Double?.some(20))
                    Text("10/s").tag(Double?.some(10))
                }

                Toggle("Swap Eyes", isOn: $realtime3D.swapsEyes)
                Toggle("Show Depth", isOn: $realtime3D.showsDepth)
                Toggle("Packed SBS Input", isOn: $settings.packedSBSInput)
            } header: {
                Label("Synthesis", systemImage: "cube.transparent")
            }

            Section {
                LabeledContent("Depth", value: "\(Int((realtime3D.depthStrength * 100).rounded()))%")
                Slider(value: $realtime3D.depthStrength, in: 0...1, step: 0.01)

                LabeledContent("Convergence", value: "\(Int((realtime3D.convergence * 100).rounded()))%")
                Slider(value: $realtime3D.convergence, in: -1...1, step: 0.01)

                HStack(spacing: 12) {
                    ForEach(Realtime3DPreset.allCases) { preset in
                        Button(preset.title) {
                            realtime3D.applyPreset(preset)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Button {
                    realtime3D.resetTuning()
                } label: {
                    Label("Reset Tuning", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Label("Parallax", systemImage: "square.stack.3d.down.right")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .navigationTitle("Stereo 3D")
    }
}

private extension Realtime3DPreset {
    var title: String {
        switch self {
        case .comfort: return String(localized: "Comfort")
        case .balanced: return String(localized: "Balanced")
        case .strong: return String(localized: "Strong")
        }
    }
}
