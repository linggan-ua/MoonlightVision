//
//  StreamWindowView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI
import UIKit

/// The stream window: the picture fills a plain window, controls live in a
/// visionOS ornament below it, and stats sit in a compact HUD over the picture.
struct StreamWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var settings = StreamSettingsStore.shared

    let model: StreamSessionModel
    private let onExit: () -> Void

    @State private var windowScene: UIWindowScene?
    @State private var lockedAspect: Double?

    init(model: StreamSessionModel, onExit: @escaping () -> Void) {
        self.model = model
        self.onExit = onExit
    }

    private var isEnded: Bool {
        if case .ended = model.phase { return true }
        return false
    }

    /// The stream picture's aspect. The window can only resize uniformly at
    /// this aspect, so the whole window scales as one piece.
    private var targetAspect: Double {
        Double(settings.resolution.width) / Double(settings.resolution.height)
    }

    private func applyAspectLock(force: Bool = false) {
        guard let scene = windowScene else { return }
        let aspect = targetAspect
        if !force, let lockedAspect, abs(lockedAspect - aspect) < 0.0005 {
            return
        }
        lockedAspect = aspect
        scene.lockStreamAspect(aspect)
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
        }
        .background(.black)
        .background(WindowSceneReader { scene in
            windowScene = scene
            applyAspectLock()
        })
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
        .task { await model.startWhenReady() }
        .onAppear {
            model.inputView.onDirectTap = { [weak model] in
                model?.revealStreamControls()
            }
            model.setBackgrounded(scenePhase != .active)
            applyAspectLock()
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.setBackgrounded(newPhase != .active)
            if newPhase == .active {
                applyAspectLock(force: true)
            }
        }
        .onChange(of: targetAspect) { _, _ in
            applyAspectLock(force: true)
        }
        .onChange(of: settings.hideChromeDuringMouseInput) { _, _ in
            model.refreshChromeVisibility()
        }
        .onChange(of: settings.suppressRestoreTap) { _, _ in
            model.refreshChromeVisibility()
        }
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
            if settings.showStats, model.isStreaming, !model.statsText.isEmpty {
                StreamStatsPanel(text: model.statsText)
            }

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
                _ = model.inputView.becomeFirstResponder()
            }
            .frame(height: showKeyboard ? nil : 0)
            .opacity(showKeyboard ? 1 : 0)
            .clipped()
            .allowsHitTesting(showKeyboard)
            .accessibilityHidden(!showKeyboard)
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
