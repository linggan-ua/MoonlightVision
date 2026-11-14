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

            Toggle(isOn: $showKeyboard) {
                Label("Keyboard", systemImage: "keyboard")
            }
            .toggleStyle(.button)

            Toggle(isOn: $showStats) {
                Label("Stats", systemImage: "chart.bar.xaxis")
            }
            .toggleStyle(.button)

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
