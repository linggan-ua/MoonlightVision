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
/// Nothing here can reconnect the stream, so it compares a baseline of the
/// restart-only settings when it closes and asks the stream window to offer the
/// restart.
struct StreamSettingsWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Bindable private var presentation = StreamPresentation.shared
    @State private var restartBaseline: StreamRestartSettings?

    /// Restart-only settings that changed since this window opened. Reading the
    /// store here is what makes the banner update as the user drags a slider.
    private var needsRestart: Bool {
        guard let restartBaseline else { return false }
        return StreamRestartSettings() != restartBaseline
    }

    var body: some View {
        VStack(spacing: 0) {
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
            if needsRestart, let model = presentation.session {
                HStack(spacing: 12) {
                    Text("Some settings take effect after the stream restarts")
                        .font(.callout)
                    Spacer()
                    Button("Restart") {
                        restartBaseline = StreamRestartSettings()
                        Task { await model.restart() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.thinMaterial)
            }
        }
        .onAppear {
            restartBaseline = StreamRestartSettings()
        }
        .onDisappear {
            // Read before clearing: the baseline is only consumed once.
            let baseline = restartBaseline
            restartBaseline = nil
            guard baseline != nil, presentation.session != nil else { return }
            guard let baseline, StreamRestartSettings() != baseline else { return }
            presentation.requestRestart()
        }
        .onChange(of: presentation.session == nil) { _, ended in
            if ended { dismissWindow(id: "stream-settings-window") }
        }
    }
}
