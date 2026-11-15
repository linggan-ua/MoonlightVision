//
//  WindowAspectLock.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI
import UIKit

/// Hands back the `UIWindowScene` hosting a SwiftUI view. SwiftUI has no
/// visionOS modifier for "keep the aspect ratio but stay resizable"; the only
/// public API is a scene geometry update, which needs the scene.
struct WindowSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScene = onScene
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onScene = onScene
    }

    final class ReaderView: UIView {
        var onScene: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onScene?(window?.windowScene)
        }
    }
}

extension UIWindowScene {
    /// Fixes the content aspect and lets the system offer only its uniform
    /// resize handles, so the whole stream window scales as one piece.
    func lockStreamAspect(_ aspect: Double) {
        guard aspect.isFinite, aspect > 0.1 else { return }
        let bounds = effectiveGeometry.coordinateSpace.bounds
        guard bounds.width > 0 else { return }
        requestGeometryUpdate(.Vision(
            size: CGSize(width: bounds.width, height: bounds.width / aspect),
            minimumSize: nil,
            maximumSize: nil,
            resizingRestrictions: .uniform
        ))
    }
}
