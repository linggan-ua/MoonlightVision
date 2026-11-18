//
//  Stream3DSettingsWindowView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  The long-press helper window from the control bar's 3D button. It hosts the
//  same 3D settings page as Settings → 3D, bound to the same stores, so tuning
//  changes stay in sync between this window and the main settings sheet.
//

import SwiftUI

struct Stream3DSettingsWindowView: View {
    @State private var presentation = StreamPresentation.shared

    var body: some View {
        NavigationStack {
            Stereo3DSettingsView()
        }
        .frame(minWidth: 500, minHeight: 620)
        .onChange(of: presentation.session == nil) { _, missing in
            if missing {
                dismissIfNoSession()
            }
        }
        .onAppear {
            if presentation.session == nil {
                dismissIfNoSession()
            }
        }
    }

    @Environment(\.dismissWindow) private var dismissWindow

    private func dismissIfNoSession() {
        dismissWindow(id: "stream-3d-settings")
    }
}
