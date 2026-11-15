//
//  StreamControlBar.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

/// The stream's controls. Lives in a visionOS ornament below the window so it
/// never covers the picture.
struct StreamControlBar: View {
    let isEnded: Bool
    @Binding var volume: Double
    @Binding var showStats: Bool
    @Binding var showKeyboard: Bool
    let onDisconnect: () -> Void
    let onToggleMute: () -> Void

    @Bindable private var settings = StreamSettingsStore.shared

    private enum QuickAudioMode: String, CaseIterable, Identifiable {
        case stereo
        case spatial
        case surround

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stereo: return String(localized: "Stereo")
            case .spatial: return String(localized: "Spatial Audio")
            case .surround: return String(localized: "7.1 Surround")
            }
        }

        var symbol: String {
            switch self {
            case .stereo: return "headphones"
            case .spatial: return "person.spatialaudio.fill"
            case .surround: return "speaker.wave.3.fill"
            }
        }
    }

    private var quickAudioMode: QuickAudioMode {
        if settings.audioMode == .surround71 || settings.audioMode == .surround51 {
            return .surround
        }
        return settings.spatialAudio ? .spatial : .stereo
    }

    private func applyQuickAudio(_ mode: QuickAudioMode) {
        switch mode {
        case .stereo:
            settings.audioMode = .stereo
            settings.spatialAudio = false
        case .spatial:
            settings.audioMode = .stereo
            settings.spatialAudio = true
        case .surround:
            settings.audioMode = .surround71
            settings.spatialAudio = false
        }
        // Spatial mixing is live; a channel-layout change takes effect on the
        // next stream.
        MVSetStreamSpatialAudio(settings.spatialAudio)
    }

    private var volumeSymbol: String {
        switch volume {
        case 0: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onDisconnect) {
                Label(isEnded ? "Close" : "Disconnect", systemImage: "xmark")
            }
            .help("Disconnect. The game keeps running on the host.")

            Divider().frame(height: 26)

            BarControlToggle(
                title: "Keyboard",
                symbol: "keyboard",
                isOn: showKeyboard
            ) {
                showKeyboard.toggle()
            }

            BarControlToggle(
                title: "Stats",
                symbol: "chart.bar.xaxis",
                isOn: showStats
            ) {
                showStats.toggle()
            }

            BarControlToggle(
                title: "Touchpad Mode",
                symbol: settings.mouseInputMode == .touchpad ? "trackpad" : "hand.tap.fill",
                isOn: settings.mouseInputMode == .touchpad
            ) {
                settings.mouseInputMode = settings.mouseInputMode == .touchpad
                    ? .touchscreenGCMouse
                    : .touchpad
            }
            .help("Switch between screen touch and whole-screen touchpad.")

            Menu {
                ForEach(QuickAudioMode.allCases) { mode in
                    Button {
                        applyQuickAudio(mode)
                    } label: {
                        Label(
                            mode.title,
                            systemImage: mode == quickAudioMode ? "checkmark" : mode.symbol
                        )
                    }
                }
            } label: {
                Label(quickAudioMode.title, systemImage: quickAudioMode.symbol)
            }
            .help("Spatial Audio applies live; Stereo and 7.1 apply on the next stream.")

            Divider().frame(height: 26)

            Button(action: onToggleMute) {
                Image(systemName: volumeSymbol)
            }
            .help("Mute or unmute the stream. Other apps aren't affected.")

            Slider(value: $volume, in: 0...1)
                .frame(width: 160)
                .accessibilityLabel("Stream Volume")
        }
        .labelStyle(.iconOnly)
        .padding(12)
        .glassBackgroundEffect()
    }
}

/// A control-bar toggle with explicit contrast. The system `.button` toggle
/// style can draw a white selected pill with a white icon in the glass bar.
private struct BarControlToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 22, height: 22)
                .foregroundStyle(isOn ? Color.black : Color.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    isOn ? Color.white : Color.white.opacity(0.12),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
