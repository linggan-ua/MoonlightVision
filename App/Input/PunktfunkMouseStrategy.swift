import Foundation
import UIKit

// Behavior modeled on other clients's StreamViewIOS / PointerLock (MIT OR
// Apache-2.0). Reimplemented for stream input.
/// other clients's visionOS-window policy:
/// - The window is normally unlocked, so the mouse is an absolute pointer:
///   hover moves it, `.indirectPointer` touches deliver clicks and drags.
/// - GCMouse relative motion is used only while the scene is actually pointer
///   locked (not available in a visionOS shared-space window), and the local
///   cursor is hidden only in that state.
/// - Scroll is taken from continuous/discrete pan recognizers so UIKit applies
///   Natural Scrolling and trackpads report measured distances.
/// - Input is owned by the stream scene; no system cursor hiding while unlocked.
@MainActor
final class other clientsMouseStrategy: NSObject, StreamMouseStrategy, UIPointerInteractionDelegate {
    let scheme: MouseInputScheme = .punktfunk

    private weak var view: StreamWindowInputView?
    private let sender = MouseEventSender()
    private let hover = MouseHoverRecognizer()
    private let indirect = IndirectPointerHandler()
    private let scroll = MouseScrollRecognizers()
    private let mouseHub = GCMouseHub()

    private var pointerInteraction: UIPointerInteraction?
    private var lockObserver: NSObjectProtocol?
    private var mode: MouseTrackingMode = .absolute
    private var streamWidth: Int32 = 1920
    private var streamHeight: Int32 = 1080
    private var active = false
    private var pointerOverContent = true
    private var systemCursorHidden = false
    var onMouseActivity: (@MainActor () -> Void)?
    private var locked = false
    private var running = false
    private var moveRemainderX: Float = 0
    private var moveRemainderY: Float = 0

    private static let speedDivisor: Float = 1.25

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
        self.pointerOverContent = true
        running = true
        resetAccumulators()

        view.mouseSurfaceDelegate = self

        hover.onHover = { [weak self] point, isActive in
            self?.handleHover(point, isActive: isActive)
        }
        hover.install(on: view)

        scroll.onHighResScroll = { [weak self] x, y in
            guard let self else { return }
            if self.pointerOverContent { self.onMouseActivity?() }
            self.sender.highResScroll(y: y, x: x)
        }
        scroll.onDiscreteScroll = { [weak self] x, y in
            guard let self else { return }
            if self.pointerOverContent { self.onMouseActivity?() }
            self.sender.scroll(y: y, x: x)
        }
        scroll.install(on: view)

        indirect.onPosition = { [weak self] point in
            guard let self else { return }
            self.sendAbsolute(point)
            if self.pointerOverContent { self.onMouseActivity?() }
        }
        indirect.onButton = { [weak self] button, pressed in
            guard let self, self.running, !self.locked else { return }
            if pressed, self.pointerOverContent { self.onMouseActivity?() }
            self.sender.button(button, pressed: pressed, allowed: self.active)
        }

        let interaction = UIPointerInteraction(delegate: self)
        view.addInteraction(interaction)
        pointerInteraction = interaction

        let center = NotificationCenter.default
        lockObserver = center.addObserver(
            forName: UIPointerLockState.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncLockState() }
        }

        sender.setForwarding(active)
        syncLockState()
        NSLog("[Mouse] other clients start mode=%@ size=%dx%d", mode.rawValue, streamWidth, streamHeight)
    }

    func stop() {
        guard running || view != nil else { return }
        running = false
        if let lockObserver {
            NotificationCenter.default.removeObserver(lockObserver)
            self.lockObserver = nil
        }
        hover.onHover = nil
        hover.remove()
        scroll.onHighResScroll = nil
        scroll.onDiscreteScroll = nil
        scroll.remove()
        indirect.onPosition = nil
        indirect.onButton = nil
        indirect.reset()
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
        locked = false
        systemCursorHidden = false
    }

    func setTrackingMode(_ mode: MouseTrackingMode) {
        // other clients's visionOS window path is absolute; the setting only selects
        // the preferred mode for schemes that support relative input.
        self.mode = mode
        NSLog("[Mouse] other clients tracking mode %@ ignored in the window; absolute pointer in use", mode.rawValue)
    }

    func setActive(_ active: Bool) {
        self.active = active
        sender.setForwarding(active)
        if !active {
            pointerOverContent = false
            resetAccumulators()
        } else {
            syncLockState()
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

    func mouseSurfaceDidLayout() {
        pointerInteraction?.invalidate()
    }

    func mouseSurfaceDidMoveToWindow() {
        syncLockState()
    }

    func mouseSurfaceTouchesBegan(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let view, !locked else { return }
        indirect.began(touches, event: event, in: view)
    }

    func mouseSurfaceTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let view, !locked else { return }
        indirect.moved(touches, event: event, in: view)
    }

    func mouseSurfaceTouchesEnded(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let view, !locked else { return }
        indirect.ended(touches, event: event, in: view, cancelled: false)
    }

    func mouseSurfaceTouchesCancelled(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let view, !locked else { return }
        indirect.ended(touches, event: event, in: view, cancelled: true)
        sender.releaseAll()
    }

    // MARK: - Pointer lock

    private func syncLockState() {
        guard running else { return }
        let nowLocked = view?.window?.windowScene?.pointerLockState?.isLocked == true
        guard nowLocked != locked else {
            pointerInteraction?.invalidate()
            return
        }
        locked = nowLocked
        pointerInteraction?.invalidate()
        if locked {
            startGameControllerMouse()
        } else {
            mouseHub.stop()
            sender.releaseAll()
        }
        NSLog("[Mouse] other clients pointer lock=%@", locked ? "locked" : "unlocked")
    }

    private func startGameControllerMouse() {
        mouseHub.start(GCMouseHub.Handlers(
            moved: { [weak self] dx, dy in
                self?.handleLockedMove(dx: dx, dy: dy)
            },
            button: { [weak self] button, pressed in
                guard let self, self.running, self.locked else { return }
                if pressed, self.pointerOverContent { self.onMouseActivity?() }
                self.sender.button(button, pressed: pressed, allowed: self.active)
            },
            scroll: { _, _ in
                // Scroll always comes from the pan recognizers, locked or not.
            },
            presence: { [weak self] present in
                guard let self, !present else { return }
                self.sender.releaseAll()
            }
        ))
    }

    private func handleLockedMove(dx: Float, dy: Float) {
        guard running, locked else { return }
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
        sender.move(dx: Int32(clamping: Int(wholeX)), dy: Int32(clamping: Int(wholeY)))
    }

    // MARK: - Absolute pointer

    private func handleHover(_ point: CGPoint, isActive: Bool) {
        guard running, !locked else { return }
        if isActive {
            sendAbsolute(point)
            if pointerOverContent {
                onMouseActivity?()
            }
        } else {
            pointerOverContent = false
        }
    }

    private func sendAbsolute(_ point: CGPoint) {
        guard running, !locked, let view else { return }
        let geometry = MouseInputGeometry(
            viewSize: view.bounds.size,
            streamWidth: streamWidth,
            streamHeight: streamHeight
        )
        pointerOverContent = geometry.contains(point)
        guard let position = geometry.streamPoint(for: point) else { return }
        sender.position(
            x: position.x,
            y: position.y,
            referenceWidth: streamWidth,
            referenceHeight: streamHeight
        )
    }

    // MARK: - UIPointerInteractionDelegate

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard running, let view else { return nil }
        if systemCursorHidden {
            return UIPointerRegion(
                rect: view.bounds.insetBy(dx: -100_000, dy: -100_000),
                identifier: nil
            )
        }
        guard locked else { return nil }
        return UIPointerRegion(rect: view.bounds, identifier: nil)
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        guard running else { return nil }
        return (locked || systemCursorHidden) ? .hidden() : nil
    }

    private func resetAccumulators() {
        moveRemainderX = 0
        moveRemainderY = 0
    }
}
