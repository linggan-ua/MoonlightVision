//
//  SettingsView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = StreamSettingsStore.shared
    @ObservedObject private var realtime3D = Realtime3DSettingsStore.shared
    @State private var showResetConfirm = false

    @State private var selectedAspectRatio: String?
    @State private var isCustomFrameRate = false
    @State private var customFrameRate = 60
    @State private var isCustomBitrate = false
    @State private var customBitrate = 10

    var showsDoneButton = true

    private static let frameRatePresets = [24, 30, 60, 90, 100, 120]
    private static let bitratePresets = [5, 10, 30, 50, 75, 100, 120, 150, 200, 300, 400, 500, 600]
    private static let aspectRatios = ["16:9", "16:10", "4:3", "21:9", "43:18", "12:5", "32:9"]

    private var widthBinding: Binding<Int> {
        Binding(
            get: { Int(settings.resolution.width) },
            set: { newValue in
                let width = min(max(newValue, 160), 7680)
                settings.resolution = StreamResolution(
                    width: Int32(width),
                    height: settings.resolution.height
                )
            }
        )
    }

    private var heightBinding: Binding<Int> {
        Binding(
            get: { Int(settings.resolution.height) },
            set: { newValue in
                let height = min(max(newValue, 120), 4320)
                settings.resolution = StreamResolution(
                    width: settings.resolution.width,
                    height: Int32(height)
                )
            }
        )
    }

    private var frameRateSelection: Binding<Int> {
        Binding(
            get: { isCustomFrameRate ? -1 : settings.frameRate },
            set: { newValue in
                if newValue == -1 {
                    isCustomFrameRate = true
                    settings.frameRate = customFrameRate
                } else {
                    isCustomFrameRate = false
                    settings.frameRate = newValue
                }
            }
        )
    }

    private var customFrameRateBinding: Binding<Int> {
        Binding(
            get: { customFrameRate },
            set: { newValue in
                customFrameRate = min(max(newValue, 1), 240)
                settings.frameRate = customFrameRate
            }
        )
    }

    private var customFrameRateSlider: Binding<Double> {
        Binding(
            get: { Double(customFrameRate) },
            set: { newValue in
                customFrameRate = min(max(Int(newValue.rounded()), 1), 240)
                settings.frameRate = customFrameRate
            }
        )
    }

    private var bitrateSelection: Binding<Int> {
        Binding(
            get: { isCustomBitrate ? -1 : settings.bitrateMbps },
            set: { newValue in
                if newValue == -1 {
                    isCustomBitrate = true
                    settings.bitrateMbps = customBitrate
                } else {
                    isCustomBitrate = false
                    settings.bitrateMbps = newValue
                }
            }
        )
    }

    private var customBitrateBinding: Binding<Int> {
        Binding(
            get: { customBitrate },
            set: { newValue in
                customBitrate = min(max(newValue, 1), 1000)
                settings.bitrateMbps = customBitrate
            }
        )
    }

    private var customBitrateSlider: Binding<Double> {
        Binding(
            get: { Double(customBitrate) },
            set: { newValue in
                customBitrate = min(max(Int(newValue.rounded()), 1), 1000)
                settings.bitrateMbps = customBitrate
            }
        )
    }

    private var resolutionGroups: [(String, [StreamResolution])] {
        let order = ["16:9", "16:10", "4:3", "21:9", "43:18", "12:5", "32:9"]
        let groups = Dictionary(grouping: StreamResolution.presets, by: \.aspectDescription)
        return order.compactMap { aspect in
            groups[aspect].map { (aspect, $0) }
        }
    }

    private func configureCustomState() {
        if Self.frameRatePresets.contains(settings.frameRate) {
            isCustomFrameRate = false
            customFrameRate = settings.frameRate
        } else {
            isCustomFrameRate = true
            customFrameRate = settings.frameRate
        }

        if Self.bitratePresets.contains(settings.bitrateMbps) {
            isCustomBitrate = false
            customBitrate = settings.bitrateMbps
        } else {
            isCustomBitrate = true
            customBitrate = settings.bitrateMbps
        }

        if Self.aspectRatios.contains(settings.resolution.aspectDescription) {
            selectedAspectRatio = settings.resolution.aspectDescription
        } else {
            selectedAspectRatio = nil
        }
    }

    private func applyAspectRatio(_ text: String) {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              numerator > 0, denominator > 0 else { return }
        let height = Int((Double(settings.resolution.width) * denominator / numerator).rounded())
        settings.resolution = StreamResolution(
            width: settings.resolution.width,
            height: Int32(min(max(height, 120), 4320))
        )
    }

    private var resolutionPage: some View {
        Form {
            Picker("Resolution", selection: $settings.resolution) {
                ForEach(resolutionGroups, id: \.0) { group in
                    ForEach(group.1) { resolution in
                        Text(resolution.title)
                            .badge(group.0)
                            .tag(resolution)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Section("Custom") {
                HStack {
                    TextField("Width", value: widthBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("×")
                        .foregroundStyle(.secondary)
                    TextField("Height", value: heightBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Resolution")
    }

    private var aspectRatioPage: some View {
        Form {
            Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                ForEach(Self.aspectRatios, id: \.self) { ratio in
                    Text(ratio).tag(ratio as String?)
                }
                Text("Custom").tag(nil as String?)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            HStack {
                Spacer()
                Text(settings.resolution.aspectDescription)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Aspect Ratio")
        .onChange(of: selectedAspectRatio) { _, ratio in
            if let ratio {
                applyAspectRatio(ratio)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        resolutionPage
                    } label: {
                        HStack {
                            Label("Resolution", systemImage: "rectangle.inset.filled")
                            Spacer()
                            Text(settings.resolution.title)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        aspectRatioPage
                    } label: {
                        HStack {
                            Label("Aspect Ratio", systemImage: "aspectratio")
                            Spacer()
                            Text(settings.resolution.aspectDescription)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker(selection: frameRateSelection) {
                        ForEach(Self.frameRatePresets, id: \.self) { rate in
                            Text("\(rate)").tag(rate)
                        }
                        Text("Custom").tag(-1)
                    } label: {
                        Label("Frame Rate", systemImage: "waveform.path.ecg")
                    }

                    if isCustomFrameRate {
                        HStack {
                            Label("Custom Frame Rate", systemImage: "dial.min")
                            Spacer()
                            TextField("", value: customFrameRateBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Text("fps")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: customFrameRateSlider, in: 1...240, step: 1)
                    }

                    Picker(selection: bitrateSelection) {
                        ForEach(Self.bitratePresets, id: \.self) { rate in
                            Text("\(rate) Mbps").tag(rate)
                        }
                        Text("Custom").tag(-1)
                    } label: {
                        Label("Bitrate", systemImage: "speedometer")
                    }

                    if isCustomBitrate {
                        HStack {
                            Label("Custom Bitrate", systemImage: "dial.max")
                            Spacer()
                            TextField("", value: customBitrateBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            Text("Mbps")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: customBitrateSlider, in: 1...1000, step: 1)
                    }

                    Picker("Codec", selection: $settings.codec) {
                        ForEach(CodecPreference.allCases) { codec in
                            Text(codec.title).tag(codec)
                        }
                    }
                    Toggle("HDR (HDR10)", isOn: $settings.hdrEnabled)
                        .disabled(!settings.codec.supportsHDR)
                    Toggle("Frame Pacing", isOn: $settings.framePacing)
                    Toggle("Anti-Shimmer (Mipmaps)", isOn: $settings.antiShimmerMipmaps)
                } header: {
                    Label("Video", systemImage: "tv")
                } footer: {
                    Text("Smooths shimmer and moiré in motion with mipmaps; the picture becomes slightly less sharp. Turn off for the sharpest picture.")
                }

                Section {
                    Toggle("Stereo 3D", isOn: $settings.stereoSBS)
                    NavigationLink {
                        Stereo3DSettingsView()
                    } label: {
                        HStack {
                            Label("3D Settings", systemImage: "cube.transparent")
                            Spacer()
                            Text(
                                settings.stereoSBS
                                    ? LocalizedStringKey(realtime3D.scheme.tileTitle)
                                    : LocalizedStringKey("Off")
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("3D", systemImage: "cube.transparent")
                }

                Section {
                    LabeledContent(
                        "Window Corner Radius",
                        value: String(format: "%.1f%%", settings.windowCornerRadius)
                    )
                    Slider(value: $settings.windowCornerRadius, in: 0...3, step: 0.1)

                    LabeledContent(
                        "Screen Curvature",
                        value: String(format: "%.0f%%", settings.screenCurvature)
                    )
                    Slider(value: $settings.screenCurvature, in: 0...100, step: 1)
                } header: {
                    Label("Window", systemImage: "rectangle.roundedtop")
                } footer: {
                    Text("0% corner radius gives square corners; 0% curvature is flat. Curvature uses a fixed radius, so a larger window wraps further.")
                }

                Section("Host") {
                    Toggle("Optimize Game Settings", isOn: $settings.optimizeGameSettings)
                    Toggle("Play Audio on PC", isOn: $settings.playAudioOnPC)
                }

                Section("Audio") {
                    Picker("Audio Mode", selection: $settings.audioMode) {
                        ForEach(AudioMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Spatial Audio (Head-Tracked)", isOn: $settings.spatialAudio)
                        .onChange(of: settings.spatialAudio) { _, value in
                            MVSetStreamSpatialAudio(value)
                        }
                }

                Section("Input") {
                    Picker("Mouse Input", selection: $settings.mouseInputMode) {
                        ForEach(MouseInputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Hide Controls While Captured", isOn: $settings.hideChromeDuringMouseInput)
                    Toggle("Gaze Tap Only Releases Capture", isOn: $settings.suppressRestoreTap)
                        .disabled(!settings.hideChromeDuringMouseInput)
                    Toggle("Invert Scroll Direction", isOn: $settings.invertScroll)
                    Toggle("Show Local Cursor", isOn: $settings.showLocalCursor)
                    Picker("Mouse Mode", selection: $settings.mouseMode) {
                        ForEach(MouseTrackingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    LabeledContent(
                        "Pointer Speed",
                        value: String(format: "%.2f×", settings.mousePointerSpeed)
                    )
                    Slider(value: $settings.mousePointerSpeed, in: 0.25...3.0, step: 0.05)
                    Toggle("Swap A/B and X/Y", isOn: $settings.swapABXY)
                    Toggle("Multiple Controllers", isOn: $settings.multiController)
                }

                Section("Diagnostics") {
                    Toggle("Show Stats Overlay", isOn: $settings.showStats)
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        showResetConfirm = true
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .navigationTitle("Settings")
            .onAppear {
                configureCustomState()
            }
            .onChange(of: settings.resolution) { _, resolution in
                selectedAspectRatio = Self.aspectRatios.contains(resolution.aspectDescription)
                    ? resolution.aspectDescription
                    : nil
            }
            .onChange(of: settings.codec) { _, codec in
                if !codec.supportsHDR {
                    settings.hdrEnabled = false
                }
            }
            .confirmationDialog(
                "Reset Settings?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    settings.reset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This restores the default video, audio, and input settings.")
            }
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
