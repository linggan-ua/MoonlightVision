//
//  StreamWindowView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

struct StreamWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var settings = StreamSettingsStore.shared

    @State private var model: StreamSessionModel
    @State private var showKeyboard = false
    private let onExit: () -> Void

    init(model: StreamSessionModel, onExit: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onExit = onExit
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            StreamRenderViewRepresentable(view: model.renderView)
                .ignoresSafeArea()
            overlay
        }
        .task { await model.startWhenReady() }
        .onAppear { model.setBackgrounded(scenePhase != .active) }
        .onChange(of: scenePhase) { _, newPhase in
            model.setBackgrounded(newPhase != .active)
        }
        .onDisappear { model.stop() }
        .overlay(alignment: .bottom) {
            if showKeyboard {
                VirtualKeyboardView(input: model.keyboardInput) {
                    showKeyboard = false
                    _ = model.renderView.becomeFirstResponder()
                }
                .padding(24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showKeyboard)
    }

    private var overlay: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Button {
                model.stop()
                onExit()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                showKeyboard.toggle()
            } label: {
                Label(showKeyboard ? String(localized: "Hide Keyboard") : String(localized: "Keyboard"), systemImage: "keyboard")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.callout)
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { model.volume },
                        set: { model.volume = $0 }
                    ),
                    in: 0...1
                )
                .frame(width: 140)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())

            if !model.isStreaming {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(model.statusText)
                        .font(.callout)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if model.isStreaming && settings.showStats && !model.statsText.isEmpty {
                Text(model.statsText)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.leading)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }

            Spacer()
        }
        .padding(24)
    }
}
