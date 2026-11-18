import SwiftUI

/// Tuning for the on-device 2D→3D conversion. The stream window's 3D control
/// turns the conversion on for a normal 2D stream; this page chooses how it
/// looks.
struct Realtime3DSettingsPage: View {
    var body: some View {
        Form {
            Realtime3DSettingsSections()
        }
        .formStyle(.grouped)
        .navigationTitle("Real-time 3D")
    }
}

/// The 3D tuning controls, shared by the app settings page, the in-stream live
/// settings panel and the auxiliary 3D window. All three read the same store,
/// so a change in one is visible everywhere immediately.
struct Realtime3DSettingsSections: View {
    @ObservedObject private var store = Realtime3DSettingsStore.shared

    private var depthBinding: Binding<Double> {
        Binding(
            get: { Double(store.depthStrength) },
            set: { store.depthStrength = Float($0) }
        )
    }

    private var convergenceBinding: Binding<Double> {
        Binding(
            get: { Double(store.convergence) },
            set: { store.convergence = Float($0) }
        )
    }

    private var presetBinding: Binding<Int> {
        Binding(
            get: {
                if abs(store.depthStrength - store.comfortDepth) < 0.001 { return 0 }
                if abs(store.depthStrength - store.strongDepth) < 0.001 { return 2 }
                return 1
            },
            set: { index in
                switch index {
                case 0: store.applyPreset(.comfort)
                case 2: store.applyPreset(.strong)
                default: store.applyPreset(.balanced)
                }
            }
        )
    }

    private var modelBinding: Binding<LSRealtimeDepthModel?> {
        Binding(
            get: { store.model },
            set: { store.model = $0 }
        )
    }

    private var rateBinding: Binding<Double?> {
        Binding(
            get: { store.depthRate },
            set: { store.depthRate = $0 }
        )
    }

    var body: some View {
        Section {
            Picker("Scheme", selection: $store.scheme) {
                    ForEach(LSRealtimeStereoScheme.allCases, id: \.self) { scheme in
                        Text(LocalizedStringKey(scheme.tileTitle)).tag(scheme)
                    }
                }

                Picker("Preset", selection: presetBinding) {
                    Text("Comfort").tag(0)
                    Text("Balanced").tag(1)
                    Text("Strong").tag(2)
                }
                .pickerStyle(.segmented)

                HStack {
                    Label("Depth Strength", systemImage: "cube.transparent")
                    Slider(value: depthBinding, in: 0...1)
                    Text("\(Int((store.depthStrength * 100).rounded()))%")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                HStack {
                    Label("Convergence", systemImage: "arrow.left.and.right")
                    Slider(value: convergenceBinding, in: -1...1)
                    Text("\(Int((store.convergence * 100).rounded()))%")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                if store.exceedsComfortDefault {
                    Label(
                        "Above the model default is harder on the eyes",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Label("Real-time 3D", systemImage: "cube.transparent")
            } footer: {
                Text("The 3D control in the stream window turns this on for a normal 2D stream.")
            }

            Section {
                Picker("Model", selection: modelBinding) {
                    Text("Auto (scheme default)").tag(LSRealtimeDepthModel?.none)
                    ForEach(LSRealtimeDepthModel.allCases, id: \.self) { model in
                        Text(LocalizedStringKey(model.tileTitle)).tag(Optional(model))
                    }
                }

                Picker("Depth Rate", selection: rateBinding) {
                    Text("Default").tag(Double?.none)
                    Text("60/s").tag(Optional(60.0))
                    Text("30/s").tag(Optional(30.0))
                    Text("20/s").tag(Optional(20.0))
                    Text("10/s").tag(Optional(10.0))
                    Text("Unlimited").tag(Optional(0.0))
                }

                Toggle("Swap Eyes", isOn: $store.swapsEyes)
                Toggle("Show Depth Map", isOn: $store.showsDepth)
            } header: {
                Label("Depth", systemImage: "brain")
        } footer: {
            Text("ZipDepth is the fast model. Depth Anything V2 is sharper but needs more power. The depth rate caps how often the model runs.")
        }

        Section {
            Button("Reset 3D Tuning") {
                store.resetTuning()
            }
        }
    }
}
