//
//  StreamKeyboardWindowView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI

/// The virtual keyboard as its own auxiliary window. It has the system drag
/// bar, so it can be moved freely; the stream window resets it below itself
/// when the main window moves.
struct StreamKeyboardWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var presentation = StreamPresentation.shared
    @State private var windowState = StreamKeyboardWindowState.shared
    @State private var windowScene: UIWindowScene?
    @State private var appliedAspect = false

    /// Design aspect of the keyboard layout. The window is locked to it so a
    /// resize scales the whole keyboard instead of stretching the keys.
    private static let keyboardAspect: Double = 1.95
    /// Natural size of the keyboard at its 46-point key unit. The whole view
    /// is scaled to fit, so keys and row spacing shrink together and can never
    /// overlap at small window sizes.
    private static let designSize = CGSize(width: 774, height: 349)

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let session = presentation.session {
                    let scale = min(
                        proxy.size.width / Self.designSize.width,
                        proxy.size.height / Self.designSize.height
                    )
                    VirtualKeyboardView(
                        input: session.keyboardInput,
                        isActive: true,
                        showsGlassBackground: false
                    )
                    .fixedSize()
                    .scaleEffect(max(scale, 0.2), anchor: .center)
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height,
                        alignment: .center
                    )
                } else {
                    Color.clear
                        .onAppear {
                            windowState.wantsKeyboard = false
                            dismissWindow(id: "stream-keyboard")
                        }
                }
            }
        }
        .background(WindowSceneReader { scene in
            windowScene = scene
            guard !appliedAspect, let scene else { return }
            appliedAspect = true
            scene.lockStreamAspect(Self.keyboardAspect)
        })
        .onDisappear {
            windowState.wantsKeyboard = false
        }
        .onChange(of: presentation.session == nil) { _, missing in
            if missing {
                windowState.wantsKeyboard = false
                dismissWindow(id: "stream-keyboard")
            }
        }
    }
}
