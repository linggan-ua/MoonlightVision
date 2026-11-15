//
//  OfficialHybridMouseStrategy.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation
import UIKit

// Behavior modeled on the vendored official moonlight-ios StreamView.m
// (GPL-3.0 with the App Store Distribution Exception).
/// The official moonlight-ios `StreamView.m` dual path, adapted to visionOS
/// windows and combined with an earlier client's click/focus gating:
/// - GCMouse raw deltas while available (relative mode).
/// - `UIPointerInteraction` over the aspect-fit video rect for absolute mode,
///   and as the fallback when no GCMouse is present.
/// - `UITouch.indirectPointer` buttons when no GCMouse is present.
/// - Continuous/discrete pan recognizers for scroll.
/// - Presses require stream focus and pointer-over-content; releases are always
///   sent for a button this strategy pressed.
@MainActor
final class OfficialHybridMouseStrategy: NSObject, StreamMouseStrategy, UIPointerInteractionDelegate {
    let scheme: MouseInputScheme = .officialHybrid

    private weak var view: StreamWindowInputView?
    private let sender = MouseEventSender()
    private let mouseHub = GCMouseHub()
    private let hover = MouseHoverRecognizer()
    private let indirect = IndirectPointerHandler()
    private let scroll = MouseScrollRecognizers()

    private var pointerInteraction: UIPointerInteraction?
    private var mode: MouseTrackingMode = .relative
    private var streamWidth: Int32 = 1920
    private var streamHeight: Int32 = 1080
    private var active = false
    private var pointerOverContent = true
    private var systemCursorHidden = false
    var onMouseActivity: (@MainActor () -> Void)?
    private var hasGCMouse = false
    private var lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
    private var pointerFallbackArmed = false
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
        lastGCMouseActivity = Date.timeIntervalSinceReferenceDate
        pointerFallbackArmed = false
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
            guard let self, self.running, !self.hasGCMouse else { return }
            if pressed, self.pointerOverContent { self.onMouseActivity?() }
            self.sender.button(button, pressed: pressed, allowed: self.active)
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
            scroll: { _, _ in
                // Scroll comes from the pan recognizers, as in StreamView.m.
            },
            presence: { [weak self] present in
                self?.handlePresence(present)
            }
        ))

        sender.setForwarding(active)
        NSLog("[Mouse] OfficialHybrid start mode=%@ size=%dx%d", mode.rawValue, streamWidth, streamHeight)
    }

    func stop() {
        guard running || view != nil else { return }
        running = false
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
        systemCursorHidden = false
    }

    func setTrackingMode(_ mode: MouseTrackingMode) {
        self.mode = mode
        resetAccumulators()
        pointerInteraction?.invalidate()
    }

    func setActive(_ active: Bool) {
        self.active = active
        sender.setForwarding(active)
        if !active {
            pointerOverContent = false
            resetAccumulators()
        }
        pointerInteraction?.invalidate()
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
        if pressed, pointerOverContent {
            onMouseActivity?()
        }
        sender.button(
            button,
            pressed: pressed,
            allowed: active && pointerOverContent
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
        }
        pointerInteraction?.invalidate()
        NSLog("[Mouse] OfficialHybrid physical mouse %@", present ? "connected" : "disconnected")
    }

    // MARK: - Absolute pointer

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
            if mode == .relative, hasGCMouse, pointerFallbackAvailable,
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
    }

    private func sendAbsolute(_ point: CGPoint) {
        guard running, let view else { return }
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

        let geometry = MouseInputGeometry(
            viewSize: view.bounds.size,
            streamWidth: streamWidth,
            streamHeight: streamHeight
        )

        if systemCursorHidden {
            let insideVideo = geometry.contains(request.location)
            pointerOverContent = insideVideo
            // While the GCMouse owns relative motion, the system pointer is
            // hidden for appearance only. Sending its absolute location too
            // would fight the GCMouse deltas and make the host cursor jitter.
            if (mode == .absolute || !hasGCMouse), insideVideo, sender.heldButtons.isEmpty {
                sendAbsolute(request.location)
            }
            return UIPointerRegion(
                rect: view.bounds.insetBy(dx: -100_000, dy: -100_000),
                identifier: nil
            )
        }

        // With a GCMouse in relative mode, official StreamView.m leaves the
        // pointer alone and lets GCMouse motion drive the host.
        if mode == .relative, hasGCMouse {
            return nil
        }

        let rect = geometry.videoRect
        guard rect.width > 0, rect.height > 0 else { return nil }

        pointerOverContent = true
        onMouseActivity?()
        if sender.heldButtons.isEmpty {
            sendAbsolute(request.location)
        }
        return UIPointerRegion(rect: rect, identifier: nil)
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        guard running else { return nil }
        if systemCursorHidden {
            return .hidden()
        }
        // Official behavior: hide the local pointer over the video when the
        // absolute path owns it. In relative mode with a GCMouse the pointer
        // stays visible.
        if mode == .absolute || !hasGCMouse {
            return .hidden()
        }
        return nil
    }

    private var pointerFallbackAvailable: Bool {
        Date.timeIntervalSinceReferenceDate - lastGCMouseActivity >= 0.15
    }

    private func resetAccumulators() {
        moveRemainderX = 0
        moveRemainderY = 0
    }
}
