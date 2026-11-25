//
//  TouchscreenGCMouseStrategy.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation
import UIKit
/// Pointer handling in the style of a system-pointer capture client:
/// - Uncaptured (default): the system pointer is visible and moves normally
///   over the picture; nothing is forwarded to the host.
/// - A click on the picture captures the mouse: the system pointer hides and
///   GCMouse deltas, buttons and scrolling drive the host.
/// - A direct gaze touch releases capture and restores the system pointer.
/// - `UIPointerInteraction` still supplies absolute positions while captured
///   (absolute mode); `UITouch.indirectPointer` buttons work without a GCMouse.
/// - Presses require stream focus; releases are always sent for a button this
///   strategy pressed.
@MainActor
final class TouchscreenGCMouseStrategy: NSObject, StreamMouseStrategy, UIPointerInteractionDelegate {
    private weak var view: StreamWindowInputView?
    private let sender = MouseEventSender()
    private let mouseHub = GCMouseHub()
    private let hover = MouseHoverRecognizer()
    private let indirect = IndirectPointerHandler()
    private let scroll = MouseScrollRecognizers()

    private var pointerInteraction: UIPointerInteraction?
    private var mode: MouseTrackingMode = .relative
    private var size = StreamInputSize(
        hostWidth: 1920,
        hostHeight: 1080,
        displayedWidth: 1920,
        displayedHeight: 1080
    )
    private var active = false
    private var pointerOverContent = false
    private var captured = false
    private var lastHoverPoint: CGPoint?
    var onCaptureChanged: (@MainActor (Bool) -> Void)?
    private var hasGCMouse = false
    private var lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
    private var pointerFallbackArmed = false
    private var running = false
    private var moveRemainderX: Float = 0
    private var moveRemainderY: Float = 0
    private let localCursor: StreamLocalCursor

    var isCaptured: Bool { captured }

    init(localCursor: StreamLocalCursor) {
        self.localCursor = localCursor
        super.init()
    }

    func start(
        view: StreamWindowInputView,
        mode: MouseTrackingMode,
        size: StreamInputSize,
        active: Bool
    ) {
        stop()
        self.view = view
        self.mode = mode
        self.size = size
        self.active = active
        self.pointerOverContent = false
        self.captured = false
        self.localCursor.visible = false
        running = true
        lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
        pointerFallbackArmed = false
        resetAccumulators()

        view.mouseSurfaceDelegate = self

        hover.onHover = { [weak self] point, isActive in
            self?.handleHover(point, isActive: isActive)
        }
        hover.install(on: view)

        scroll.onHighResScroll = { [weak self] x, y in
            guard let self, self.captured else { return }
            let sign: Int32 = StreamSettingsStore.shared.invertScroll ? -1 : 1
            self.sender.highResScroll(y: y * sign, x: x)
        }
        scroll.onDiscreteScroll = { [weak self] x, y in
            guard let self, self.captured else { return }
            let sign: Int32 = StreamSettingsStore.shared.invertScroll ? -1 : 1
            self.sender.scroll(y: y * sign, x: x)
        }
        scroll.install(on: view)

        indirect.onPosition = { [weak self] point in
            guard let self, self.running else { return }
            self.lastHoverPoint = point
            self.updatePointerOverContent(point)
            if self.captured {
                self.sendAbsolute(point)
            }
        }
        indirect.onButton = { [weak self] button, pressed in
            guard let self, self.running, !self.hasGCMouse else { return }
            self.handlePointerButton(button, pressed: pressed, at: self.lastHoverPoint)
        }

        let interaction = UIPointerInteraction(delegate: self)
        view.addInteraction(interaction)
        pointerInteraction = interaction

        mouseHub.start(GCMouseHub.Handlers(
            moved: { [weak self] dx, dy in
                self?.handleMove(dx: dx, dy: dy)
            },
            button: { [weak self] button, pressed in
                self?.handleButton(button, pressed: pressed)
            },
            scroll: { [weak self] horizontal, vertical in
                guard let self, self.running, self.captured else { return }
                // The physical wheel is forwarded through GCMouse.scroll; the
                // pan recognizers only cover trackpads.
                let sign: Float = StreamSettingsStore.shared.invertScroll ? -1 : 1
                let y = Int32(clamping: Int((vertical * 120 * sign).rounded()))
                let x = Int32(clamping: Int((horizontal * 120).rounded()))
                guard x != 0 || y != 0 else { return }
                self.sender.highResScroll(y: y, x: x)
            },
            presence: { [weak self] present in
                self?.handlePresence(present)
            }
        ))

        sender.setForwarding(active)
        NSLog("[Mouse] Touchscreen+GCMouse start mode=%@ host=%dx%d displayed=%dx%d", mode.rawValue, size.hostWidth, size.hostHeight, size.displayedWidth, size.displayedHeight)
    }

    func stop() {
        guard running || view != nil else { return }
        running = false
        captured = false
        localCursor.visible = false
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
        hasGCMouse = false
        lastHoverPoint = nil
    }

    func setTrackingMode(_ mode: MouseTrackingMode) {
        self.mode = mode
        setCaptured(false)
        resetAccumulators()
        pointerInteraction?.invalidate()
    }

    func setActive(_ active: Bool) {
        self.active = active
        sender.setForwarding(active)
        if !active {
            setCaptured(false)
            pointerOverContent = false
            localCursor.visible = false
            resetAccumulators()
        }
        pointerInteraction?.invalidate()
    }

    func updateStreamSize(_ size: StreamInputSize) {
        self.size = size
        pointerInteraction?.invalidate()
    }

    func setCaptured(_ value: Bool) {
        guard captured != value else { return }
        captured = value
        localCursor.visible = value
        if !value {
            sender.releaseAll()
            resetAccumulators()
            pointerFallbackArmed = false
        }
        pointerInteraction?.invalidate()
        onCaptureChanged?(value)
        NSLog("[Mouse] capture %@", value ? "on" : "off")
    }

    func mouseSurfaceDidLayout() {
        pointerInteraction?.invalidate()
    }

    /// The SwiftUI host rebuilds its view controller whenever the stream window
    /// changes, which re-parents the shared input view. UIKit drops pointer
    /// interactions and stops delivering hover when that happens, so both the
    /// capture region and `pointerOverContent` die — and a click can never take
    /// capture again because capture requires the pointer to be over content.
    /// Re-installing here is the event the re-parent actually emits; no poll.
    func mouseSurfaceDidMoveToWindow() {
        guard running, let view, view.window != nil else { return }

        hover.remove()
        hover.onHover = { [weak self] point, isActive in
            self?.handleHover(point, isActive: isActive)
        }
        hover.install(on: view)

        scroll.remove()
        scroll.install(on: view)

        if let pointerInteraction {
            view.removeInteraction(pointerInteraction)
            self.pointerInteraction = nil
        }
        let interaction = UIPointerInteraction(delegate: self)
        view.addInteraction(interaction)
        pointerInteraction = interaction

        // A new window may come with fresh GCMouse profiles; re-attach and
        // re-install their handlers instead of relying on a later connect event
        // that never fires for a device that stayed plugged in.
        mouseHub.repairHandlers()
        lastHoverPoint = nil
        pointerOverContent = false
        setCaptured(false)
        NSLog("[Mouse] input view re-parented; pointer interactions reinstalled")
    }

    func mouseSurfaceTouchesBegan(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let view, !hasGCMouse else { return }
        indirect.began(touches, event: event, in: view)
    }

    func mouseSurfaceTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let view, !hasGCMouse else { return }
        indirect.moved(touches, event: event, in: view)
    }

    func mouseSurfaceTouchesEnded(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let view, !hasGCMouse else { return }
        indirect.ended(touches, event: event, in: view, cancelled: false)
    }

    func mouseSurfaceTouchesCancelled(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let view, !hasGCMouse else { return }
        indirect.ended(touches, event: event, in: view, cancelled: true)
        sender.releaseAll()
    }

    // MARK: - GCMouse

    private func handleMove(dx: Float, dy: Float) {
        guard running, hasGCMouse else { return }
        lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
        pointerFallbackArmed = false
        guard captured else { return }

        let pointerSpeed = Float(StreamSettingsStore.shared.mousePointerSpeed)
        moveRemainderX += dx * pointerSpeed
        moveRemainderY -= dy * pointerSpeed
        let wholeX = moveRemainderX.rounded(.towardZero)
        let wholeY = moveRemainderY.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return }
        moveRemainderX -= wholeX
        moveRemainderY -= wholeY

        let hostWidth = CGFloat(max(size.hostWidth, 1))
        let hostHeight = CGFloat(max(size.hostHeight, 1))
        localCursor.position.x = min(
            max(localCursor.position.x + CGFloat(wholeX) / hostWidth, 0),
            1
        )
        localCursor.position.y = min(
            max(localCursor.position.y + CGFloat(wholeY) / hostHeight, 0),
            1
        )

        // In absolute mode the pointer interaction supplies position. While a
        // button is held hover/region updates pause, so use deltas to keep the
        // drag alive, exactly like the core client's indirect-pointer path.
        guard mode == .relative || !sender.heldButtons.isEmpty else { return }
        sender.move(dx: Int32(clamping: Int(wholeX)), dy: Int32(clamping: Int(wholeY)))
    }

    private func handleButton(_ button: StreamMouseButton, pressed: Bool) {
        guard running, hasGCMouse else { return }
        lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
        pointerFallbackArmed = false
        if pressed, !captured, active, pointerOverContent {
            if mode == .absolute, let point = lastHoverPoint {
                sendAbsolute(point)
            }
            setCaptured(true)
        }
        sender.button(
            button,
            pressed: pressed,
            allowed: active && (captured || pointerOverContent)
        )
    }

    private func handlePointerButton(
        _ button: StreamMouseButton,
        pressed: Bool,
        at point: CGPoint?
    ) {
        if pressed, !captured, active, pointerOverContent {
            if let point {
                sendAbsolute(point)
            }
            setCaptured(true)
        }
        sender.button(
            button,
            pressed: pressed,
            allowed: active && (captured || pointerOverContent)
        )
    }

    private func handlePresence(_ present: Bool) {
        guard running else { return }
        hasGCMouse = present
        lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
        pointerFallbackArmed = false
        if !present {
            sender.releaseAll()
            pointerOverContent = false
            setCaptured(false)
        }
        pointerInteraction?.invalidate()
        NSLog("[Mouse] Touchscreen+GCMouse physical mouse %@", present ? "connected" : "disconnected")
    }

    // MARK: - Pointer position

    private func handleHover(_ point: CGPoint, isActive: Bool) {
        guard running, let view else { return }
        if isActive {
            lastHoverPoint = point
            updatePointerOverContent(point)
            updateLocalCursorPosition(point)
            if captured, mode == .relative, hasGCMouse, pointerFallbackAvailable,
               pointerOverContent, sender.heldButtons.isEmpty {
                // A trackpad may only report hover while a mouse GCMouse is
                // also present. Arm on the first hover event and move on the
                // next one, so a real mouse never gets an absolute jump before
                // its GCMouse deltas arrive.
                if pointerFallbackArmed {
                    sendAbsolute(point)
                } else {
                    pointerFallbackArmed = true
                }
            }
        } else if sender.heldButtons.isEmpty {
            pointerOverContent = false
        }
        _ = view
    }

    private func updateLocalCursorPosition(_ point: CGPoint) {
        guard let view else { return }
        let geometry = MouseInputGeometry(
            viewSize: view.bounds.size,
            streamWidth: size.displayedWidth,
            streamHeight: size.displayedHeight
        )
        if let normalized = geometry.normalizedPoint(for: point) {
            localCursor.position = normalized
        }
    }

    private func updatePointerOverContent(_ point: CGPoint) {
        guard let view else {
            pointerOverContent = false
            return
        }
        let geometry = MouseInputGeometry(
            viewSize: view.bounds.size,
            streamWidth: size.displayedWidth,
            streamHeight: size.displayedHeight
        )
        pointerOverContent = geometry.contains(point)
    }

    private func sendAbsolute(_ point: CGPoint) {
        guard running, let view else { return }
        let geometry = MouseInputGeometry(
            viewSize: view.bounds.size,
            streamWidth: size.displayedWidth,
            streamHeight: size.displayedHeight
        )
        pointerOverContent = geometry.contains(point)
        if let normalized = geometry.normalizedPoint(for: point) {
            localCursor.position = normalized
        }
        guard let position = geometry.streamPoint(for: point) else { return }
        sender.position(
            x: position.x,
            y: position.y,
            referenceWidth: size.hostWidth,
            referenceHeight: size.hostHeight
        )
    }

    // MARK: - UIPointerInteractionDelegate

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard running, let view else { return nil }

        let geometry = MouseInputGeometry(
            viewSize: view.bounds.size,
            streamWidth: size.displayedWidth,
            streamHeight: size.displayedHeight
        )
        lastHoverPoint = request.location
        updateLocalCursorPosition(request.location)
        let insideVideo = geometry.contains(request.location)
        pointerOverContent = insideVideo

        if captured {
            // While captured the system pointer is hidden and must not leave
            // the picture; feed absolute positions in absolute mode only.
            if (mode == .absolute || !hasGCMouse), insideVideo, sender.heldButtons.isEmpty {
                sendAbsolute(request.location)
            }
            return UIPointerRegion(
                rect: view.bounds.insetBy(dx: -100_000, dy: -100_000),
                identifier: nil
            )
        }

        // Uncaptured: the pointer stays visible with its normal style over the
        // picture; a click here captures.
        let rect = geometry.videoRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return UIPointerRegion(rect: rect, identifier: nil)
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        guard running else { return nil }
        return captured ? .hidden() : nil
    }

    private var pointerFallbackAvailable: Bool {
        Date.timeIntervalSinceReferenceDate - lastGCMouseActivity >= 0.15
    }

    private func resetAccumulators() {
        moveRemainderX = 0
        moveRemainderY = 0
    }
}
