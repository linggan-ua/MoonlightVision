import SwiftUI

/// Live settings for the current stream, shown as a popover from the control
/// bar. Every control writes the same stores as the app's Settings page, so
/// the two stay in sync while the stream runs.
struct StreamLiveSettingsPanel: View {
    @Bindable private var settings = StreamSettingsStore.shared

    private static let frameRatePresets = [24, 30, 60, 90, 100, 120]
    private static let bitratePresets = [5, 10, 30, 50, 75, 100, 120, 150, 200, 300, 400, 500, 600]

    private var resolutionOptions: [StreamResolution] {
        var options = StreamResolution.presets
        if !options.contains(settings.resolution) {
            options.insert(settings.resolution, at: 0)
        }
        return options
    }

    private var frameRateOptions: [Int] {
        var options = Self.frameRatePresets
        if !options.contains(settings.frameRate) {
            options.insert(settings.frameRate, at: 0)
        }
        return options
    }

    private var bitrateOptions: [Int] {
        var options = Self.bitratePresets
        if !options.contains(settings.bitrateMbps) {
            options.insert(settings.bitrateMbps, at: 0)
        }
        return options
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker(selection: $settings.resolution) {
                        ForEach(resolutionOptions) { resolution in
                            Text(resolution.title).tag(resolution)
                        }
                    } label: {
                        Label("Resolution", systemImage: "rectangle.inset.filled")
                    }

                    Picker(selection: $settings.frameRate) {
                        ForEach(frameRateOptions, id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    } label: {
                        Label("Frame Rate", systemImage: "waveform.path.ecg")
                    }

                    Picker(selection: $settings.bitrateMbps) {
                        ForEach(bitrateOptions, id: \.self) { rate in
                            Text("\(rate) Mbps").tag(rate)
                        }
                    } label: {
                        Label("Bitrate", systemImage: "speedometer")
                    }

                    Picker("Codec", selection: $settings.codec) {
                        ForEach(CodecPreference.allCases) { codec in
                            Text(codec.title).tag(codec)
                        }
                    }

                    Toggle("HDR (HDR10)", isOn: $settings.hdrEnabled)
                        .disabled(!settings.codec.supportsHDR)
                        .onChange(of: settings.codec) { _, codec in
                            if !codec.supportsHDR {
                                settings.hdrEnabled = false
                            }
                        }

                    Toggle("Frame Pacing", isOn: $settings.framePacing)
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
                    Picker("Mouse Mode", selection: $settings.mouseMode) {
                        ForEach(MouseTrackingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Realtime3DSettingsSections()

                Section("Diagnostics") {
                    Toggle("Show Stats Overlay", isOn: $settings.showStats)
                }

                Section {
                    Text("Changes apply live where possible. Video, audio layout and host options need a stream restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Stream Settings")
        }
    }
}

/// The 3D tuning controls as their own auxiliary window, opened by long-pressing
/// the 3D control. It reads the same store as the settings page.
struct Stream3DSettingsWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var presentation = StreamPresentation.shared

    var body: some View {
        Form {
            Realtime3DSettingsSections()
        }
        .formStyle(.grouped)
        .navigationTitle("3D Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Close") {
                    dismissWindow(id: "stream-3d-settings")
                }
            }
        }
        .onChange(of: presentation.session == nil) { _, missing in
            if missing {
                dismissWindow(id: "stream-3d-settings")
            }
        }
        .onAppear {
            if presentation.session == nil {
                dismissWindow(id: "stream-3d-settings")
            }
        }
    }
}
