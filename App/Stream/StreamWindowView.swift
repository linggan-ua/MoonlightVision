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
    @Environment(\.physicalMetrics) private var physicalMetrics
    @Bindable private var settings = StreamSettingsStore.shared

    let model: StreamSessionModel
    private let onExit: () -> Void

    @State private var keyboardHintVisible = false
    @State private var keyboardHintTask: Task<Void, Never>?
    @State private var showStreamSettings = false
    @State private var restartBaseline: StreamRestartSettings?
    @State private var showRestartPrompt = false

    init(model: StreamSessionModel, onExit: @escaping () -> Void) {
        self.model = model
        self.onExit = onExit
    }

    private var isEnded: Bool {
        if case .ended = model.phase { return true }
        return false
    }

    /// Extra physical gap between the window and both ornaments.
    private var ornamentGap: CGFloat {
        physicalMetrics.convert(0.5, from: .centimeters)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !model.isStreaming {
                // Before the first frame, show a native glass window instead
                // of a black rectangle; the loading panel floats in it.
                Color.clear
                    .glassBackgroundEffect()
                    .ignoresSafeArea()
            }

            // The picture is a RealityKit plane. With no opaque SwiftUI layer
            // behind it, the window's own background cannot fight with it.
            if let texture = model.videoTexture, model.isStreaming {
                StreamVideoSurface(
                    texture: texture,
                    mailbox: model.frameMailbox,
                    videoMode: model.videoMode,
                    streamWidth: model.streamWidth,
                    streamHeight: model.streamHeight,
                    packedSBS: model.isSBSStream,
                    cornerRadiusFraction: Float(settings.windowCornerRadius / 100),
                    localConversion: !model.isSBSStream,
                    showSBSConfirm: model.showSBSConfirm,
                    onEnableSBS: {
                        model.showSBSConfirm = false
                        model.videoMode = .sideBySide3D
                    },
                    onCancelSBS: {
                        model.showSBSConfirm = false
                    }
                )
            }

            StreamWindowInputViewRepresentable(view: model.inputView)
                .ignoresSafeArea()

            if !model.isStreaming {
                StreamGlassOverlay {
                    VStack(spacing: 14) {
                        if !isEnded {
                            ProgressView()
                        }
                        Text(model.statusText)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        // Do not wrap the scene content in a SwiftUI clip/mask: a masked
        // subtree is rendered offscreen, which softens video.
        .persistentSystemOverlays(model.hidesStreamChrome ? .hidden : .automatic)
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            VStack(spacing: 10) {
                if keyboardHintVisible {
                    StreamHintPanel {
                        VStack(spacing: 6) {
                            Label("Keyboard Active", systemImage: "keyboard")
                                .font(.headline)
                            Text("Use the on-screen keyboard to type.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity)
                }
                if !model.hidesStreamChrome {
                    StreamControlsView(
                        model: model,
                        onExit: onExit,
                        onOpenSettings: {
                            restartBaseline = StreamRestartSettings()
                            showStreamSettings = true
                        }
                    )
                }
            }
            .padding(.top, ornamentGap)
        }
        .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) {
            VStack(spacing: 8) {
                if model.connectionPoor, model.isStreaming {
                    Label("Poor Connection", systemImage: "wifi.exclamationmark")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassBackgroundEffect(in: Capsule())
                }
                if settings.showStats, model.isStreaming, !model.statsText.isEmpty {
                    StreamStatsPanel(text: model.statsText)
                }
            }
            .padding(.bottom, ornamentGap)
        }
        .sheet(isPresented: $showStreamSettings, onDismiss: {
            guard let baseline = restartBaseline else { return }
            restartBaseline = nil
            guard StreamRestartSettings() != baseline else { return }
            // Let the sheet's dismissal finish before presenting the dialog.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                showRestartPrompt = true
            }
        }) {
            SettingsView()
                .frame(minWidth: 720, minHeight: 760)
        }
        .alert(
            "Some settings require restarting the stream to take effect.",
            isPresented: $showRestartPrompt
        ) {
            Button("Restart") {
                Task { await model.restart() }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Restarting keeps this window open and reconnects to the host.")
        }
        .task { await model.startWhenReady() }
        .onAppear {
            model.inputView.isUserInteractionEnabled = !model.showSBSConfirm
            model.setBackgrounded(scenePhase != .active)
        }
        .onChange(of: model.showSBSConfirm) { _, showing in
            // While the confirmation card floats over the picture, let its
            // buttons receive the pinch instead of forwarding it to the host.
            model.inputView.isUserInteractionEnabled = !showing
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
        .onChange(of: settings.stereoSBS) { _, enabled in
            model.setStereoSBS(enabled)
        }
        .onChange(of: settings.packedSBSInput) { _, _ in
            model.refreshSBSLayout()
        }
        .onChange(of: settings.antiShimmerMipmaps) { _, enabled in
            model.setAntiShimmerMipmaps(enabled)
        }
        .onChange(of: settings.mouseMode) { _, mode in
            model.setMouseMode(mode)
        }
        .onChange(of: settings.swapABXY) { _, swap in
            model.setSwapABXY(swap)
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
    let onOpenSettings: () -> Void

    @Bindable private var settings = StreamSettingsStore.shared
    @Bindable private var keyboardWindow = StreamKeyboardWindowState.shared
    @State private var showKeyboard = false

    private var isEnded: Bool {
        if case .ended = model.phase { return true }
        return false
    }

    private var keyboardBinding: Binding<Bool> {
        Binding(
            get: { showKeyboard },
            set: { newValue in
                showKeyboard = newValue
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
            is3DEnabled: model.videoMode == .sideBySide3D,
            canToggle3D: model.isStreaming,
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
            onToggle3D: {
                guard model.isStreaming else { return }
                if model.videoMode == .sideBySide3D {
                    model.videoMode = .standard2D
                } else {
                    model.showSBSConfirm = true
                }
            },
            onShow3DSettings: {
                openWindow(id: "stream-3d-settings")
            },
            onOpenSettings: onOpenSettings,
            onToggleMute: {
                model.toggleMute()
            }
        )
        .onAppear {
            showKeyboard = keyboardWindow.wantsKeyboard
        }
        .onReceive(NotificationCenter.default.publisher(for: .streamKeyboardWindowDidClose)) { _ in
            showKeyboard = false
            keyboardWindow.wantsKeyboard = false
        }
        .onChange(of: keyboardWindow.wantsKeyboard) { _, wantsKeyboard in
            if showKeyboard != wantsKeyboard {
                showKeyboard = wantsKeyboard
            }
        }
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

/// The centered glass panel used by the startup status overlay.
private struct StreamGlassOverlay<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .glassBackgroundEffect(
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .allowsHitTesting(false)
    }
}

/// A compact glass panel for transient hints in the ornament layer.
private struct StreamHintPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .fixedSize()
    }
}

extension Notification.Name {
    static let streamKeyboardDidActivate = Notification.Name("mv.streamKeyboardDidActivate")
    static let streamKeyboardDidDeactivate = Notification.Name("mv.streamKeyboardDidDeactivate")
    static let streamKeyboardWindowDidClose = Notification.Name("mv.streamKeyboardWindowDidClose")
}
