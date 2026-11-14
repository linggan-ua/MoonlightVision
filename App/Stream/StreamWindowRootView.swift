//
//  StreamWindowRootView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

/// Root of the dedicated stream window. If the window is restored without a
/// live session, it closes itself instead of leaving an empty window behind.
struct StreamWindowRootView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var presentation = StreamPresentation.shared

    var body: some View {
        Group {
            if let model = presentation.session {
                StreamWindowView(model: model) {
                    presentation.session = nil
                    dismissWindow(id: "stream")
                }
                .id(ObjectIdentifier(model))
            } else {
                Color.black
                    .ignoresSafeArea()
                    .onAppear {
                        dismissWindow(id: "stream")
                    }
            }
        }
        .onDisappear {
            presentation.session?.stop()
            presentation.session = nil
        }
    }
}
