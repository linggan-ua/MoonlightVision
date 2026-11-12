//
//  StreamWindowView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

struct StreamWindowView: View {
    @State private var model: StreamSessionModel
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
        .onDisappear { model.stop() }
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

            if !model.isStreaming {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(model.statusText)
                        .font(.callout)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if model.isStreaming && !model.statsText.isEmpty {
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
