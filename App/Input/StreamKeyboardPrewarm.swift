import SwiftUI
import UIKit

/// Builds the virtual keyboard once offscreen so the first auxiliary-window
/// open does not pay the full SwiftUI construction cost.
@MainActor
enum StreamKeyboardPrewarm {
    private static var warmedInput: ObjectIdentifier?

    static func warm(input: StreamKeyboardInput) {
        let identifier = ObjectIdentifier(input)
        guard warmedInput != identifier else { return }
        warmedInput = identifier

        let controller = UIHostingController(
            rootView: VirtualKeyboardView(
                input: input,
                isActive: false,
                showsGlassBackground: false
            )
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 800, height: 410)
        controller.view.layoutIfNeeded()

        // Let SwiftUI finish its first layout pass while the stream is still
        // preparing, then release the offscreen hierarchy.
        DispatchQueue.main.async {
            controller.view.layoutIfNeeded()
        }
    }
}
