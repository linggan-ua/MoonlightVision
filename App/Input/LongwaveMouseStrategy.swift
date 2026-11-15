import Foundation
import UIKit

// Behavior modeled on an MIT-licensed visionOS source;
// GPLv3 when built with the core). Reimplemented for this project.
/// an earlier client's visionOS mouse policy, implemented on top of GameController and
/// UIKit hover:
/// - GCMouse raw deltas in relative mode.
/// - `UIHoverGestureRecognizer` absolute position in absolute mode.
/// - GCMouse deltas continue while a button is held, because hover pauses.
/// - Presses are gated by pointer-over-content and stream focus; releases are
///   always sent for a button this strategy pressed.
/// - The system pointer is not hidden.
@MainActor
final class GCMouseMouseStrategy: NSObject, StreamMouseStrategy, UIPointerInteractionDelegate {
    let scheme: MouseInputScheme = .longwave

    private weak var view: StreamWindowInputView?
    private let sender = MouseEventSender()
    private let mouseHub = GCMouseHub()
    private let hover = MouseHoverRecognizer()
    private var pointerInteraction: UIPointerInteraction?

    private var mode: MouseTrackingMode = .relative
    private var streamWidth: Int32 = 1920
    private var streamHeight: Int32 = 1080
    private var active = false
    private var pointerOverContent = true
    private var systemCursorHidden = false
    var onMouseActivity: (@MainActor () -> Void)?
    private var lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
    private var pointerFallbackArmed = false
    private var running = false

    private var moveRemainderX: Float = 0
    private var moveRemainderY: Float = 0
    private var scrollRemainderX: Float = 0
    private var scrollRemainderY: Float = 0

    private static let speedDivisor: Float = 1.25
    private static let highResPerNotch: Int32 = 20

    func start(
        view: StreamWindowInputView,
        mode: MouseTrackingMode,
        streamWidth: Int32,
        streamHeight: Int32,
        active: Bool
    ) {
        stop()
        self.view = view
        self.mode = mode
        self.streamWidth = max(streamWidth, 1)
        self.streamHeight = max(streamHeight, 1)
        self.active = active
        running = true
        pointerOverContent = true
        lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
        pointerFallbackArmed = false
        resetAccumulators()

        view.mouseSurfaceDelegate = self
        let interaction = UIPointerInteraction(delegate: self)
        view.addInteraction(interaction)
        pointerInteraction = interaction
        hover.onHover = { [weak self] point, isActive in
            self?.handleHover(point, isActive: isActive)
        }
        hover.install(on: view)

        mouseHub.start(GCMouseHub.Handlers(
            moved: { [weak self] dx, dy in
                self?.handleMove(dx: dx, dy: dy)
            },
            button: { [weak self] button, pressed in
                self?.handleButton(button, pressed: pressed)
            },
            scroll: { [weak self] x, y in
                self?.handleScroll(x: x, y: y)
            },
            presence: { [weak self] present in
                self?.handlePresence(present)
            }
        ))

        sender.setForwarding(active)
        NSLog("[Mouse] GCMouse start mode=%@ size=%dx%d", mode.rawValue, streamWidth, streamHeight)
    }

    func stop() {
        guard running || view != nil else { return }
        running = false
        hover.onHover = nil
        hover.remove()
        mouseHub.stop()
        sender.releaseAll()
        if let pointerInteraction {
            view?.removeInteraction(pointerInteraction)
            self.pointerInteraction = nil
        }
        if view?.mouseSurfaceDelegate === self {
            view?.mouseSurfaceDelegate = nil
        }
        view = nil
    }

    func setTrackingMode(_ mode: MouseTrackingMode) {
        self.mode = mode
        resetAccumulators()
    }

    func setActive(_ active: Bool) {
        self.active = active
        sender.setForwarding(active)
        if !active {
            pointerOverContent = false
            resetAccumulators()
        }
    }

    func updateStreamSize(width: Int32, height: Int32) {
        streamWidth = max(width, 1)
        streamHeight = max(height, 1)
        pointerInteraction?.invalidate()
    }

    func setSystemCursorHidden(_ hidden: Bool) {
        systemCursorHidden = hidden
        pointerInteraction?.invalidate()
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard running, systemCursorHidden, let view else { return nil }
        // A margin much larger than the window keeps the system pointer hidden
        // even when it drifts toward the window controls.
        return UIPointerRegion(
            rect: view.bounds.insetBy(dx: -100_000, dy: -100_000),
            identifier: nil
        )
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        systemCursorHidden ? .hidden() : nil
    }

    // MARK: - Events

    private func handleHover(_ point: CGPoint, isActive: Bool) {
        guard running, let view else { return }
        if isActive {
            let geometry = MouseInputGeometry(
                viewSize: view.bounds.size,
                streamWidth: streamWidth,
                streamHeight: streamHeight
            )
            pointerOverContent = geometry.contains(point)
            if pointerOverContent {
                onMouseActivity?()
            }
            let pointerFallback = mode == .relative && pointerFallbackAvailable
            if mode == .absolute || pointerFallback {
                if pointerFallback {
                    // The first hover event after idle only arms the fallback.
                    // If a GCMouse moves now, it disarms before the next event,
                    // so a mouse never gets one absolute jump before its deltas.
                    if pointerFallbackArmed, sender.heldButtons.isEmpty,
                       let position = geometry.streamPoint(for: point) {
                        sender.position(
                            x: position.x,
                            y: position.y,
                            referenceWidth: streamWidth,
                            referenceHeight: streamHeight
                        )
                    } else {
                        pointerFallbackArmed = true
                    }
                } else if sender.heldButtons.isEmpty,
                          let position = geometry.streamPoint(for: point) {
                    sender.position(
                        x: position.x,
                        y: position.y,
                        referenceWidth: streamWidth,
                        referenceHeight: streamHeight
                    )
                }
            }
        } else if sender.heldButtons.isEmpty {
            // Hover pauses while a button is held, so do not clear the gate
            // until the drag ends.
            pointerOverContent = false
            pointerFallbackArmed = false
        }
    }

    private func handleMove(dx: Float, dy: Float) {
        guard running else { return }
        lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
        pointerFallbackArmed = false
        if pointerOverContent {
            onMouseActivity?()
        }
        moveRemainderX += dx / Self.speedDivisor
        moveRemainderY -= dy / Self.speedDivisor
        let wholeX = moveRemainderX.rounded(.towardZero)
        let wholeY = moveRemainderY.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return }
        moveRemainderX -= wholeX
        moveRemainderY -= wholeY

        // Absolute mode normally gets its position from hover. While a button
        // is held visionOS pauses hover, so deltas keep the drag moving.
        guard mode == .relative || !sender.heldButtons.isEmpty else { return }
        sender.move(dx: Int32(clamping: Int(wholeX)), dy: Int32(clamping: Int(wholeY)))
    }

    private func handleButton(_ button: StreamMouseButton, pressed: Bool) {
        guard running else { return }
        lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
        pointerFallbackArmed = false
        if pressed, pointerOverContent {
            onMouseActivity?()
        }
        sender.button(
            button,
            pressed: pressed,
            allowed: active && pointerOverContent
        )
    }

    private func handleScroll(x: Float, y: Float) {
        guard running else { return }
        lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
        pointerFallbackArmed = false
        if pointerOverContent {
            onMouseActivity?()
        }
        scrollRemainderY += y
        let vertical = scrollRemainderY.rounded(.towardZero)
        if vertical != 0 {
            scrollRemainderY -= vertical
            sender.highResScroll(
                y: Int32(clamping: Int(vertical)) * Self.highResPerNotch,
                x: 0
            )
        }

        scrollRemainderX -= x
        let horizontal = scrollRemainderX.rounded(.towardZero)
        if horizontal != 0 {
            scrollRemainderX -= horizontal
            sender.highResScroll(
                y: 0,
                x: Int32(clamping: Int(horizontal)) * Self.highResPerNotch
            )
        }
    }

    private func handlePresence(_ present: Bool) {
        guard running else { return }
        if !present {
            sender.releaseAll()
            pointerOverContent = false
        }
        NSLog("[Mouse] GCMouse physical mouse %@", present ? "connected" : "disconnected")
    }

    /// A trackpad may only report hover/indirect pointer movement. If no
    /// GCMouse has moved recently, let hover drive the host cursor instead of
    /// requiring a GCMouse profile.
    private var pointerFallbackAvailable: Bool {
        Date.timeIntervalSinceReferenceDate - lastGCMouseActivity >= 0.15
    }

    private func resetAccumulators() {
        moveRemainderX = 0
        moveRemainderY = 0
        scrollRemainderX = 0
        scrollRemainderY = 0
    }
}
