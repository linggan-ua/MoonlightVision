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
    /// resize handles, so the whole stream window scales as one piece. A
    /// remembered size is used when it still matches the stream aspect.
    func lockStreamAspect(_ aspect: Double, preferredSize: CGSize? = nil) {
        guard aspect.isFinite, aspect > 0.1 else { return }
        let bounds = effectiveGeometry.coordinateSpace.bounds
        let width: CGFloat
        if let preferredSize,
           preferredSize.width > 0,
           preferredSize.height > 0,
           abs(preferredSize.width / preferredSize.height - aspect) / aspect < 0.05 {
            width = preferredSize.width
        } else {
            width = bounds.width
        }
        guard width > 0 else { return }
        requestGeometryUpdate(.Vision(
            size: CGSize(width: width, height: width / aspect),
            minimumSize: nil,
            maximumSize: nil,
            resizingRestrictions: .uniform
        ))
    }
}

/// Remembers the last stream window size in points. Read before the window
/// content is created, so the stream starts at the size the user left it.
enum StreamWindowSizeStore {
    private static let key = "mv.streamWindowSize"

    static var savedSize: CGSize? {
        guard let values = UserDefaults.standard.array(forKey: key) as? [Double],
              values.count == 2 else { return nil }
        let size = CGSize(width: values[0], height: values[1])
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    static func save(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        UserDefaults.standard.set(
            [Double(size.width), Double(size.height)],
            forKey: key
        )
    }
}
