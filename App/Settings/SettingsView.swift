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

    var showsDoneButton = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $settings.resolution) {
                        ForEach(StreamResolution.allCases) { resolution in
                            Text(resolution.title).tag(resolution)
                        }
                    }
                    Picker("Frame Rate", selection: $settings.frameRate) {
                        ForEach([30, 60, 90, 120], id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    Stepper("Bitrate: \(settings.bitrateMbps) Mbps", value: $settings.bitrateMbps, in: 5...150, step: 5)
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
            .navigationTitle("Settings")
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
