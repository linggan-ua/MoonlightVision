//
//  StreamWindowRootView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI
import UIKit

/// Root of the dedicated stream window. If the window is restored without a
/// live session, it closes itself instead of leaving an empty window behind.
struct StreamWindowRootView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var settings = StreamSettingsStore.shared
    @State private var presentation = StreamPresentation.shared

    @State private var windowScene: UIWindowScene?
    @State private var appliedInitialSize = false
    @State private var lastWindowSize: CGSize?

    private var streamAspect: Double {
        if let session = presentation.session {
            return session.streamAspect
        }
        return Double(settings.resolution.width) / Double(settings.resolution.height)
    }

    var body: some View {
        Group {
            if let model = presentation.session {
                if appliedInitialSize {
                    GeometryReader { proxy in
                        StreamWindowView(model: model) {
                            presentation.close()
                            dismissWindow(id: "stream")
                        }
                        .id(ObjectIdentifier(model))
                        .onAppear { lastWindowSize = proxy.size }
                        .onChange(of: proxy.size) { _, size in
                            lastWindowSize = size
                        }
                    }
                } else {
                    Color.black.ignoresSafeArea()
                }
            } else {
                Color.black
                    .ignoresSafeArea()
                    .onAppear {
                        dismissWindow(id: "stream")
                    }
            }
        }
        .background(WindowSceneReader { scene in
            windowScene = scene
            applyInitialWindowSizeIfNeeded()
        })
        .onAppear {
            applyInitialWindowSizeIfNeeded()
        }
        .onChange(of: presentation.session == nil) { _, _ in
            applyInitialWindowSizeIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                rememberWindowSize()
            }
        }
        .onChange(of: settings.resolution) { _, _ in
            // Preserve the current width when the stream aspect changes.
            windowScene?.lockStreamAspect(streamAspect, preferredSize: nil)
        }
        .onChange(of: presentation.session?.videoMode) { _, _ in
            // 3D shows one eye's half of a 32:9 frame, so the window becomes 16:9.
            windowScene?.lockStreamAspect(streamAspect, preferredSize: nil)
        }
        .onChange(of: settings.packedSBSInput) { _, _ in
            // The packed assertion changes whether a wide frame is one eye.
            windowScene?.lockStreamAspect(streamAspect, preferredSize: nil)
        }
        .onDisappear {
            rememberWindowSize()
            StreamKeyboardWindowState.shared.wantsKeyboard = false
            dismissWindow(id: "stream-keyboard")
            presentation.close()
        }
    }

    /// Apply the remembered size as soon as the scene exists and before the
    /// stream view is created. The stream therefore starts in the final
    /// window, instead of being resized after the connection succeeds.
    private func applyInitialWindowSizeIfNeeded() {
        guard !appliedInitialSize,
              presentation.session != nil,
              let scene = windowScene else { return }
        scene.lockStreamAspect(
            streamAspect,
            preferredSize: StreamWindowSizeStore.savedSize
        )
        appliedInitialSize = true
    }

    private func rememberWindowSize() {
        guard let lastWindowSize else { return }
        StreamWindowSizeStore.save(lastWindowSize)
    }
}

/// The stream's settings panel, in its own auxiliary window. It shares the
/// active stream session so the HDR calibration and probe buttons still work.
/// Nothing here can reconnect the stream, so it watches the restart-only
/// settings against a baseline and asks the stream window to offer the restart
/// — as soon as one changes, and again on close if none was offered yet.
struct StreamSettingsWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Bindable private var presentation = StreamPresentation.shared
    @State private var restartBaseline: StreamRestartSettings?
    /// One offer per panel session: the stream window owns the prompt, and
    /// asking again on every further tweak would keep re-presenting it.
    @State private var reportedRestart = false

    private var currentRestartSettings: StreamRestartSettings {
        StreamRestartSettings()
    }

    var body: some View {
        Group {
            if let model = presentation.session {
                SettingsView(
                    showsDoneButton: false,
                    onCalibrateHDRWhite: { model.calibrateHDRWhite() },
                    onShowEDRProbe: { openWindow(id: "edr-probe") }
                )
            } else {
                SettingsView(showsDoneButton: false)
            }
        }
        .onAppear {
            restartBaseline = StreamRestartSettings()
            reportedRestart = false
        }
        .onChange(of: currentRestartSettings) { _, latest in
            // Report immediately so the prompt can appear while this panel is
            // still open; the stream window closes the panel when restarting.
            guard !reportedRestart,
                  let baseline = restartBaseline,
                  latest != baseline else { return }
            reportedRestart = true
            presentation.requestRestart()
        }
        .onDisappear {
            // Read before clearing: the baseline is only consumed once.
            let baseline = restartBaseline
            restartBaseline = nil
            guard !reportedRestart,
                  let baseline,
                  presentation.session != nil,
                  StreamRestartSettings() != baseline else { return }
            // Closing without an answer still owes the user the offer.
            presentation.requestRestart()
        }
        .onChange(of: presentation.session == nil) { _, ended in
            if ended { dismissWindow(id: "stream-settings-window") }
        }
    }
}
