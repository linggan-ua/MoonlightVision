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
    @State private var showResetConfirm = false
    @State private var aspectText = ""

    var showsDoneButton = true

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

    private var frameRateBinding: Binding<Int> {
        Binding(
            get: { settings.frameRate },
            set: { settings.frameRate = min(max($0, 1), 240) }
        )
    }

    private var frameRateSlider: Binding<Double> {
        Binding(
            get: { Double(settings.frameRate) },
            set: { settings.frameRate = min(max(Int($0.rounded()), 1), 240) }
        )
    }

    private var bitrateBinding: Binding<Int> {
        Binding(
            get: { settings.bitrateMbps },
            set: { settings.bitrateMbps = min(max($0, 1), 1000) }
        )
    }

    private var bitrateSlider: Binding<Double> {
        Binding(
            get: { Double(settings.bitrateMbps) },
            set: { settings.bitrateMbps = min(max(Int($0.rounded()), 1), 1000) }
        )
    }

    private func applyAspectRatio() {
        let parts = aspectText
            .replacingOccurrences(of: "x", with: ":")
            .replacingOccurrences(of: "X", with: ":")
            .split(separator: ":")
        guard parts.count == 2,
              let numerator = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let denominator = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              numerator > 0, denominator > 0 else {
            aspectText = settings.resolution.aspectDescription
            return
        }
        let height = Int((Double(settings.resolution.width) * denominator / numerator).rounded())
        settings.resolution = StreamResolution(
            width: settings.resolution.width,
            height: Int32(min(max(height, 120), 4320))
        )
        aspectText = settings.resolution.aspectDescription
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Resolution") {
                        HStack(spacing: 6) {
                            TextField("Width", value: widthBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                            Text("×")
                                .foregroundStyle(.secondary)
                            TextField("Height", value: heightBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                            Menu {
                                ForEach(StreamResolution.presets) { preset in
                                    Button(preset.title) {
                                        settings.resolution = preset
                                    }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    LabeledContent("Aspect Ratio") {
                        HStack(spacing: 6) {
                            TextField("16:9", text: $aspectText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 76)
                                .multilineTextAlignment(.trailing)
                                .onSubmit(applyAspectRatio)
                            Button("Apply", action: applyAspectRatio)
                                .buttonStyle(.borderless)
                        }
                    }

                    LabeledContent("Frame Rate") {
                        HStack(spacing: 8) {
                            TextField("60", value: frameRateBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 62)
                                .multilineTextAlignment(.trailing)
                            Text("fps")
                                .foregroundStyle(.secondary)
                            Slider(value: frameRateSlider, in: 1...240, step: 1)
                                .frame(maxWidth: 200)
                        }
                    }

                    LabeledContent("Bitrate") {
                        HStack(spacing: 8) {
                            TextField("10", value: bitrateBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 62)
                                .multilineTextAlignment(.trailing)
                            Text("Mbps")
                                .foregroundStyle(.secondary)
                            Slider(value: bitrateSlider, in: 1...500, step: 1)
                                .frame(maxWidth: 200)
                        }
                    }

                    Text("Video settings apply when the next stream starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Codec", selection: $settings.codec) {
                        ForEach(CodecPreference.allCases) { codec in
                            Text(codec.title).tag(codec)
                        }
                    }
                    Toggle("HDR (HDR10)", isOn: $settings.hdrEnabled)
                        .disabled(!settings.codec.supportsHDR)
                    if !settings.codec.supportsHDR {
                        Text("HDR requires HEVC or AV1.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if settings.hdrEnabled && settings.codec == .av1 {
                        Text("HDR uses HEVC on visionOS; AV1 HDR is not offered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Frame Pacing", isOn: $settings.framePacing)
                } header: {
                    Label("Video", systemImage: "tv")
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
                    Text("This device supports up to \(StreamSettingsStore.maximumOutputChannels) output channels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Input") {
                    Picker("Mouse Input", selection: $settings.mouseInputScheme) {
                        ForEach(MouseInputScheme.allCases) { scheme in
                            Text(scheme.title).tag(scheme)
                        }
                    }
                    Text(settings.mouseInputScheme.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Mouse Input changes apply when you restart the stream.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Hide Controls With Mouse", isOn: $settings.hideChromeDuringMouseInput)
                    Text("Hides the control bar, system cursor, and window resizing while a physical mouse is connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("First Tap Only Restores Controls", isOn: $settings.suppressRestoreTap)
                        .disabled(!settings.hideChromeDuringMouseInput)
                    Text("While mouse capture hides the controls, the first gaze tap restores them without sending a touch to the host. Later taps are sent normally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Mouse Mode", selection: $settings.mouseMode) {
                        ForEach(MouseTrackingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .disabled(settings.mouseInputScheme.ignoresTrackingMode)
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
                aspectText = settings.resolution.aspectDescription
            }
            .onChange(of: settings.resolution) { _, resolution in
                aspectText = resolution.aspectDescription
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
