//
//  StreamWindowView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

/// The stream window: the picture fills a plain window, controls live in a
/// visionOS ornament below it, and stats sit in a compact HUD over the picture.
struct StreamWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var settings = StreamSettingsStore.shared

    let model: StreamSessionModel
    private let onExit: () -> Void

    init(model: StreamSessionModel, onExit: @escaping () -> Void) {
        self.model = model
        self.onExit = onExit
    }

    private var isEnded: Bool {
        if case .ended = model.phase { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            StreamRenderViewRepresentable(view: model.renderView)
                .ignoresSafeArea()

            if settings.showStats, model.isStreaming, !model.statsText.isEmpty {
                Text(model.statsText)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .padding(20)
            }

            if model.connectionPoor, model.isStreaming {
                Label("Poor Connection", systemImage: "wifi.exclamationmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 20)
            }

            if !model.isStreaming {
                VStack(spacing: 14) {
                    if !isEnded {
                        ProgressView()
                    }
                    Text(model.statusText)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }
        }
        .background(.black)
        .clipShape(.rect(cornerRadius: 24))
        .persistentSystemOverlays(.hidden)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            StreamControlsView(model: model, onExit: onExit)
        }
        .task { await model.startWhenReady() }
        .onAppear { model.setBackgrounded(scenePhase != .active) }
        .onChange(of: scenePhase) { _, newPhase in
            model.setBackgrounded(newPhase != .active)
        }
        .onDisappear { model.stop() }
    }

}

private struct StreamControlsView: View {
    let model: StreamSessionModel
    let onExit: () -> Void

    @Bindable private var settings = StreamSettingsStore.shared
    @State private var showKeyboard = false

    private var isEnded: Bool {
        if case .ended = model.phase { return true }
        return false
    }

    private var keyboardBinding: Binding<Bool> {
        Binding(
            get: { showKeyboard },
            set: { newValue in
                withAnimation(.smooth(duration: 0.22)) {
                    showKeyboard = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            StreamControlBar(
                isEnded: isEnded,
                volume: Binding(
                    get: { model.volume },
                    set: { model.volume = $0 }
                ),
                showStats: $settings.showStats,
                showKeyboard: keyboardBinding,
                onDisconnect: {
                    model.stop()
                    onExit()
                },
                onToggleMute: {
                    model.toggleMute()
                }
            )

            // Keep the keyboard mounted so the first toggle does not have to
            // build ~60 buttons and their glass backgrounds on the main thread.
            VirtualKeyboardView(input: model.keyboardInput, isActive: showKeyboard) {
                withAnimation(.smooth(duration: 0.22)) {
                    showKeyboard = false
                }
                _ = model.renderView.becomeFirstResponder()
            }
            .frame(height: showKeyboard ? nil : 0)
            .opacity(showKeyboard ? 1 : 0)
            .clipped()
            .allowsHitTesting(showKeyboard)
            .accessibilityHidden(!showKeyboard)
        }
    }
}
