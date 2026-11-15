//
//  StreamWindowView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

/// The stream window: the picture fills a plain window, controls live in a
/// visionOS ornament below it, and stats float in an ornament above it.
struct StreamWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var settings = StreamSettingsStore.shared

    let model: StreamSessionModel
    private let onExit: () -> Void

    @State private var keyboardHintVisible = false
    @State private var keyboardHintTask: Task<Void, Never>?

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

            // One UIView for the window: it hosts the stream's display layer
            // and receives keyboard, mouse, trackpad, and direct touches.
            StreamWindowInputViewRepresentable(view: model.inputView)
                .ignoresSafeArea()

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

            if keyboardHintVisible {
                VStack(spacing: 6) {
                    Label("Keyboard Active", systemImage: "keyboard")
                        .font(.headline)
                    Text("Use the on-screen keyboard to type.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .padding(18)
                .background(
                    Color.black.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .background(.black)
        // Do not wrap the video layer in a SwiftUI clip/mask. A masked
        // subtree is rendered offscreen; with an EDR video layer that
        // offscreen pass is what turns the HDR picture soft. The window
        // itself still has the system's rounded shape.
        .persistentSystemOverlays(model.hidesStreamChrome ? .hidden : .automatic)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            if !model.hidesStreamChrome {
                StreamControlsView(model: model, onExit: onExit)
            }
        }
        .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
            if settings.showStats, model.isStreaming, !model.statsText.isEmpty {
                StreamStatsPanel(text: model.statsText)
            }
        }
        .task { await model.startWhenReady() }
        .onAppear {
            model.inputView.onDirectTap = { [weak model] in
                model?.revealStreamControls()
            }
            model.setBackgrounded(scenePhase != .active)
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.setBackgrounded(newPhase != .active)
        }
        .onChange(of: settings.hideChromeDuringMouseInput) { _, _ in
            model.refreshChromeVisibility()
        }
        .onChange(of: settings.mouseInputMode) { _, _ in
            model.refreshChromeVisibility()
        }
        .onChange(of: settings.suppressRestoreTap) { _, _ in
            model.refreshChromeVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .streamKeyboardDidActivate)) { _ in
            showKeyboardHint()
        }
        .onReceive(NotificationCenter.default.publisher(for: .streamKeyboardDidDeactivate)) { _ in
            keyboardHintTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) {
                keyboardHintVisible = false
            }
        }
    }

    private func showKeyboardHint() {
        keyboardHintTask?.cancel()
        withAnimation(.smooth(duration: 0.2)) {
            keyboardHintVisible = true
        }
        keyboardHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHintVisible = false
            }
        }
    }

}

private struct StreamControlsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    let model: StreamSessionModel
    let onExit: () -> Void

    @Bindable private var settings = StreamSettingsStore.shared
    @Bindable private var keyboardWindow = StreamKeyboardWindowState.shared

    private var isEnded: Bool {
        if case .ended = model.phase { return true }
        return false
    }

    private var keyboardBinding: Binding<Bool> {
        Binding(
            get: { keyboardWindow.wantsKeyboard },
            set: { newValue in
                keyboardWindow.wantsKeyboard = newValue
                if newValue {
                    openWindow(id: "stream-keyboard")
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, keyboardWindow.wantsKeyboard else { return }
                        NotificationCenter.default.post(
                            name: .streamKeyboardDidActivate,
                            object: nil
                        )
                    }
                } else {
                    NotificationCenter.default.post(
                        name: .streamKeyboardDidDeactivate,
                        object: nil
                    )
                    dismissWindow(id: "stream-keyboard")
                }
            }
        )
    }

    var body: some View {
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
    }
}

/// Stats live in the ornament layer, like the old UIKit client: a floating
/// panel outside the stream window that never covers the picture.
private struct StreamStatsPanel: View {
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Text(text.isEmpty ? "Collecting stats…" : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
    }
}

extension Notification.Name {
    static let streamKeyboardDidActivate = Notification.Name("mv.streamKeyboardDidActivate")
    static let streamKeyboardDidDeactivate = Notification.Name("mv.streamKeyboardDidDeactivate")
}
