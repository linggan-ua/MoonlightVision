//
//  StreamWindowView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import QuartzCore
import SwiftUI
import UIKit

/// The stream window: the picture fills a plain window, controls live in a
/// visionOS ornament below it, and stats float in an ornament above it.
struct StreamWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.physicalMetrics) private var physicalMetrics
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable private var settings = StreamSettingsStore.shared
    @Bindable private var presentation = StreamPresentation.shared

    let model: StreamSessionModel
    private let onExit: () -> Void

    @State private var keyboardHintVisible = false
    @State private var keyboardHintTask: Task<Void, Never>?
    @State private var showRestartPrompt = false
    @State private var showFullScreenHDR = false
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
            if model.isStreaming, model.flatHDRModeActive, !showFullScreenHDR {
                FlatHDRVideoView(layer: model.flatHDRVideoLayer)
                    .allowedDynamicRange(.high)
            } else if let texture = model.videoTexture, model.isStreaming {
                StreamVideoSurface(
                    texture: texture,
                    mailbox: model.frameMailbox,
                    videoMode: model.videoMode,
                    streamWidth: model.streamWidth,
                    streamHeight: model.streamHeight,
                    // Any side-by-side output — host-packed or converted on
                    // device — is a double-width frame that the SBS material
                    // splits per eye. The plane's aspect still follows the host
                    // frame, so "SBS Only" on a mono stream keeps its shape.
                    packedSBS: model.hasPackedFrame,
                    cornerRadiusFraction: Float(settings.windowCornerRadius / 100),
                    curvatureFraction: Float(settings.screenCurvature / 100),
                    localCursor: model.localCursor,
                    showLocalCursor: settings.showLocalCursor,
                    sbsPresentation: model.videoMode == .sideBySide3D,
                    // The card describes what turning 3D on will do. That
                    // depends on the host frame only: "SBS Only" is a choice
                    // made from this very card, so it must not change the
                    // card's own copy or hide its button.
                    localConversion: !model.hasPackedFrame,
                    showSBSConfirm: model.showSBSConfirm,
                    onEnableSBS: {
                        model.showSBSConfirm = false
                        model.videoMode = .sideBySide3D
                    },
                    onSBSOnly: {
                        // Show the host frame's halves as-is, without running
                        // the on-device 2D→3D model.
                        model.showSBSConfirm = false
                        model.sbsOnly = true
                        model.videoMode = .sideBySide3D
                    },
                    onShow3DSettings: {
                        openWindow(id: "stream-3d-settings")
                    },
                    onCancelSBS: {
                        model.showSBSConfirm = false
                    }
                )
            }

            StreamWindowInputViewRepresentable(view: model.inputView)
                .ignoresSafeArea()

            if model.isStreaming, model.flatHDRModeActive, !showFullScreenHDR {
                VStack {
                    HStack {
                        Spacer()
                        Button("Full Screen HDR") {
                            showFullScreenHDR = true
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(16)
                    }
                    Spacer()
                }
            }

            if !model.isStreaming {
                StreamGlassOverlay(isInteractive: isEnded) {
                    VStack(spacing: 14) {
                        if !isEnded {
                            ProgressView()
                        }
                        Text(model.statusText)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        if isEnded {
                            Button {
                                Task { await model.restart() }
                            } label: {
                                Label("Reconnect", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isRestarting)
                        }
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
                            openWindow(id: "stream-settings-window")
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
        .onChange(of: presentation.restartRecommended) { _, requested in
            guard requested else { return }
            presentation.clearRestartRequest()
            guard model.isStreaming else { return }
            showRestartPrompt = true
        }
        .fullScreenCover(isPresented: $showFullScreenHDR) {
            FlatHDRFullScreenView(layer: model.flatHDRVideoLayer) {
                showFullScreenHDR = false
            }
        }
        .onChange(of: model.flatHDRModeActive) { _, active in
            showFullScreenHDR = active
        }
        .alert(
            "Some settings require restarting the stream to take effect.",
            isPresented: $showRestartPrompt
        ) {
            Button("Restart") {
                // Close the settings panel first: a reconnect makes the host
                // re-send its settings, which would reopen this prompt in a
                // loop if the panel were still comparing against its baseline.
                dismissWindow(id: "stream-settings-window")
                Task { await model.restart() }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Restarting keeps this window open and reconnects to the host.")
        }
        .task { await model.startWhenReady() }
        .onAppear {
            NSLog(
                "[Stream] window content appeared view=%@ window=%@",
                mvLogPointer(model.inputView), mvLogPointer(model.inputView.window)
            )
            model.inputView.isUserInteractionEnabled = !model.showSBSConfirm
            model.setBackgrounded(scenePhase == .background)
        }
        .onChange(of: model.showSBSConfirm) { _, showing in
            // While the confirmation card floats over the picture, let its
            // buttons receive the pinch instead of forwarding it to the host.
            model.inputView.isUserInteractionEnabled = !showing
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Focus changes report .inactive and must not pause the stream.
            // Only a real background (or another immersive app) does.
            model.setBackgrounded(newPhase == .background)
            if newPhase == .active {
                model.scheduleReconnectAfterBackgroundIfNeeded()
            }
        }
        .modifier(StreamInputSettingsObserver(model: model, settings: settings))
        .modifier(StreamVideoSettingsObserver(model: model, settings: settings))
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

private struct FlatHDRFullScreenView: View {
    let layer: CAMetalLayer
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            FlatHDRVideoView(layer: layer)
                .ignoresSafeArea()
                .allowedDynamicRange(.high)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.title3)
                    .padding(12)
                    .glassBackgroundEffect(in: Circle())
            }
            .buttonStyle(.plain)
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

private final class FlatHDRHostView: UIView {
    let metalLayer: CAMetalLayer

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct FlatHDRVideoView: UIViewRepresentable {
    let layer: CAMetalLayer

    func makeUIView(context: Context) -> FlatHDRHostView {
        FlatHDRHostView(metalLayer: layer)
    }

    func updateUIView(_ view: FlatHDRHostView, context: Context) {
        view.setNeedsLayout()
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
///
/// While connecting the panel must not eat pointer events — the picture and the
/// stream window still need them. Once the session ends the panel owns the
/// Reconnect button, so it has to be hit-testable; with hit testing off the
/// button can never be clicked and gets no hover/gaze feedback.
private struct StreamGlassOverlay<Content: View>: View {
    var isInteractive: Bool = false
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(
        isInteractive: Bool = false,
        padding: CGFloat = 24,
        @ViewBuilder content: () -> Content
    ) {
        self.isInteractive = isInteractive
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
            .allowsHitTesting(isInteractive)
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

private struct StreamInputSettingsObserver: ViewModifier {
    let model: StreamSessionModel
    @Bindable var settings: StreamSettingsStore

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.hideChromeDuringMouseInput) { _, _ in model.refreshChromeVisibility() }
            .onChange(of: settings.mouseInputMode) { _, _ in model.refreshChromeVisibility() }
            .onChange(of: settings.suppressRestoreTap) { _, _ in model.refreshChromeVisibility() }
            .onChange(of: settings.mouseMode) { _, mode in model.setMouseMode(mode) }
            .onChange(of: settings.swapABXY) { _, swap in model.setSwapABXY(swap) }
    }
}

private struct StreamVideoSettingsObserver: ViewModifier {
    let model: StreamSessionModel
    @Bindable var settings: StreamSettingsStore

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.stereoSBS) { _, enabled in model.setStereoSBS(enabled) }
            .onChange(of: settings.sbsOnly) { _, _ in model.applyVideoModeAfterSBSOnlyChange() }
            .onChange(of: settings.packedSBSInput) { _, _ in model.refreshSBSLayout() }
            .onChange(of: settings.antiShimmerMipmaps) { _, enabled in model.setAntiShimmerMipmaps(enabled) }
            .onChange(of: settings.hdrSdrBrightness) { _, value in model.setHDRSdrBrightness(Float(value)) }
            .onChange(of: settings.hdrSdrWhiteNits) { _, value in model.setHDRSdrWhiteNits(Float(value)) }
            .onChange(of: settings.hdrColorTarget) { _, target in model.setHDRColorTarget(target) }
            .onChange(of: settings.hdrSaturation) { _, value in model.setHDRSaturation(Float(value)) }
            .onChange(of: settings.hdrHighlightHeadroom) { _, value in model.setHDRHighlightHeadroom(Float(value)) }
    }
}
