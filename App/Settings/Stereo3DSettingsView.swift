//
//  Stereo3DSettingsView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  Real-time 2D→3D tuning. The master on/off switch is the stream's Stereo 3D
//  control; these rows carry the conversion tuning.
//

import SwiftUI

struct Stereo3DSettingsView: View {
    @Bindable private var settings = StreamSettingsStore.shared
    @ObservedObject private var realtime3D = Realtime3DSettingsStore.shared

    /// The preset picker is a view onto the depth slider: choosing a preset
    /// writes its depth, and moving the slider off a preset shows "Custom".
    private var presetSelection: Binding<Realtime3DPreset?> {
        Binding(
            get: {
                Realtime3DPreset.matching(depth: realtime3D.depthStrength, store: realtime3D)
            },
            set: { preset in
                guard let preset else { return }
                realtime3D.applyPreset(preset)
            }
        )
    }

    var body: some View {
        Form {
            // The tuning that matters while watching sits directly under the
            // switch, so enabling 3D and adjusting it are the same place.
            Section {
                Toggle(isOn: $settings.stereoSBS) {
                    Text(settings.sbsOnly
                        ? LocalizedStringKey("SBS 3D")
                        : LocalizedStringKey("Real-time 3D"))
                }

                // Same choice the confirmation card offers. It can be flipped
                // while 3D is running: turning it on stops the on-device
                // converter and shows the frame's halves instead.
                Toggle("SBS Only", isOn: $settings.sbsOnly)
                    .disabled(!settings.stereoSBS)

                Picker("Preset", selection: presetSelection) {
                    ForEach(Realtime3DPreset.allCases) { preset in
                        Text(preset.displayTitle).tag(Optional(preset))
                    }
                    Text("Custom").tag(Realtime3DPreset?.none)
                }
                .pickerStyle(.segmented)

                sliderRow(
                    "Depth",
                    value: $realtime3D.depthStrength,
                    range: 0...1,
                    valueText: "\(Int((realtime3D.depthStrength * 100).rounded()))%",
                    reset: { realtime3D.resetDepth() }
                )

                sliderRow(
                    "Convergence",
                    value: $realtime3D.convergence,
                    range: -1...1,
                    valueText: "\(Int((realtime3D.convergence * 100).rounded()))%",
                    reset: { realtime3D.resetConvergence() }
                )
            } header: {
                Label("Parallax", systemImage: "square.stack.3d.down.right")
            } footer: {
                Text("Depth sets how far the picture separates; convergence picks where the screen plane sits inside that range.")
                    .font(.caption)
            }

            Section {
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
                if realtime3D.showsDepth {
                    Toggle("Color Depth Map", isOn: $realtime3D.colorDepth)
                }
                Toggle("Packed SBS Input", isOn: $settings.packedSBSInput)
            } header: {
                Label("Synthesis", systemImage: "cube.transparent")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .navigationTitle("3D Settings")
    }

    /// A slider with its value on the label line and its own reset button on
    /// the right, so each control can be restored without a section-wide reset.
    @ViewBuilder
    private func sliderRow(
        _ title: LocalizedStringKey,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        valueText: String,
        reset: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            Text(valueText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: 0.01)
            Button(action: reset) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Reset"))
        }
    }
}

private extension Realtime3DPreset {
    /// Matches the existing "Comfort"/"Balanced"/"Strong" localization keys.
    var displayTitle: String {
        switch self {
        case .comfort: return String(localized: "Comfort")
        case .balanced: return String(localized: "Balanced")
        case .strong: return String(localized: "Strong")
        }
    }
}
