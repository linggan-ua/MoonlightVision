import UIKit

/// Keeps the system pointer hidden over the stream surface (and a large margin
/// around it, since the visionOS pointer is a ray that leaves the view quickly).
final class StreamPointerHider: NSObject, UIPointerInteractionDelegate {
    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard let view = interaction.view else { return defaultRegion }
        let margin: CGFloat = 100_000
        return UIPointerRegion(
            rect: view.bounds.insetBy(dx: -margin, dy: -margin),
            identifier: nil
        )
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        .hidden()
    }
}
