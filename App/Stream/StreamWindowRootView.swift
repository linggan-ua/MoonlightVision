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
        Double(settings.resolution.width) / Double(settings.resolution.height)
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
        .onDisappear {
            rememberWindowSize()
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
