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
                    Toggle("Frame Pacing", isOn: $settings.framePacing)
                    Picker("Frame Buffer", selection: $settings.framePacingDepth) {
                        Text("Off").tag(0)
                        Text("1 frame").tag(1)
                        Text("2 frames").tag(2)
                        Text("3 frames").tag(3)
                    }
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
                    Picker("Mouse Mode", selection: $settings.mouseMode) {
                        Text("Relative (FPS)").tag(MouseTrackingMode.relative)
                        Text("Absolute").tag(MouseTrackingMode.absolute)
                    }
                    Toggle("Swap A/B and X/Y", isOn: $settings.swapABXY)
                    Toggle("Multiple Controllers", isOn: $settings.multiController)
                }

                Section("Diagnostics") {
                    Toggle("Show Stats Overlay", isOn: $settings.showStats)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
