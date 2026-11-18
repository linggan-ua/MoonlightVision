//
//  StreamChromePreview.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

#if DEBUG
import SwiftUI

/// A DEBUG-only rendering of the stream chrome, launched with `-streamPreview`.
/// It uses the same control bar as the real stream window so the layout can be
/// checked in the simulator without a host.
struct StreamChromePreview: View {
    @State private var volume = 0.72
    @State private var showStats = true
    @State private var showKeyboard = false
    @State private var keyboardInput = StreamKeyboardInput()

    private static let stats = """
    Video stream: 1920×1080 · HEVC (HDR)
    Color: BT.2020 / PQ · 10-bit
    60 FPS · 20.0 Mbps
    Network 3 ms · Host 1.2 ms
    Dropped frames: 0 · Client 0.8 ms/frame
    """

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.16, blue: 0.30), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("STREAM")
                    .font(.system(size: 96, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Controls live below the window, never over the picture.")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(56)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if showStats {
                Text(Self.stats)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .padding(20)
            }
        }
        .background(.black)
        .clipShape(.rect(cornerRadius: 24))
        .persistentSystemOverlays(.hidden)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            VStack(spacing: 12) {
                StreamControlBar(
                    isEnded: false,
                    is3DEnabled: false,
                    canToggle3D: true,
                    volume: $volume,
                    showStats: $showStats,
                    showKeyboard: $showKeyboard,
                    onDisconnect: {},
                    onToggle3D: {},
                    onToggleMute: {
                        volume = volume > 0 ? 0 : 0.72
                    }
                )
                if showKeyboard {
                    VirtualKeyboardView(input: keyboardInput)
                }
            }
        }
    }
}
#endif
