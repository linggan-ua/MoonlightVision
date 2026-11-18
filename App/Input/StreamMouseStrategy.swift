//
//  StreamMouseStrategy.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation
import GameController
import UIKit

/// How physical mouse movement is translated for the host.
enum MouseTrackingMode: String, CaseIterable, Identifiable {
    case relative
    case absolute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relative: return String(localized: "Relative (FPS)")
        case .absolute: return String(localized: "Absolute")
        }
    }
}

enum MouseInputMode: String, CaseIterable, Identifiable {
    case touchscreenGCMouse
    case touchpad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .touchscreenGCMouse: return String(localized: "Touchscreen + GCMouse")
        case .touchpad: return String(localized: "Touchpad Mode")
        }
    }
}

/// The subset of stream mouse buttons used by every strategy.
enum StreamMouseButton: Int32 {
    case left = 0x01
    case middle = 0x02
    case right = 0x03
    case back = 0x04
    case forward = 0x05
}

/// Main-thread UI surface hooks a strategy can consume. `StreamWindowInputView`
/// forwards UIKit events here; strategies only act on indirect-pointer input.
@MainActor
protocol StreamMouseSurfaceDelegate: AnyObject {
    func mouseSurfaceTouchesBegan(_ touches: Set<UITouch>, event: UIEvent?)
    func mouseSurfaceTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?)
    func mouseSurfaceTouchesEnded(_ touches: Set<UITouch>, event: UIEvent?)
    func mouseSurfaceTouchesCancelled(_ touches: Set<UITouch>, event: UIEvent?)
    func mouseSurfaceDidLayout()
    func mouseSurfaceDidMoveToWindow()
}

/// The two coordinate spaces input has to bridge. The host frame is what the
/// PC renders (for example 3840×1080 in side-by-side 3D); the displayed
/// picture is what the window actually shows (one eye's 1920×1080 half).
struct StreamInputSize: Equatable {
    var hostWidth: Int32
    var hostHeight: Int32
    var displayedWidth: Int32
    var displayedHeight: Int32

    init(hostWidth: Int32, hostHeight: Int32, displayedWidth: Int32, displayedHeight: Int32) {
        self.hostWidth = max(hostWidth, 1)
        self.hostHeight = max(hostHeight, 1)
        self.displayedWidth = max(displayedWidth, 1)
        self.displayedHeight = max(displayedHeight, 1)
    }

    /// Fraction of the host frame that the displayed picture covers.
    var displayedFractionX: CGFloat {
        CGFloat(min(displayedWidth, hostWidth)) / CGFloat(hostWidth)
    }
}

/// A complete mouse-input implementation. One instance is owned by a stream
/// session and replaced on every start, so changing the setting is applied on
/// the next stream.
@MainActor
protocol StreamMouseStrategy: AnyObject, StreamMouseSurfaceDelegate {
    func start(
        view: StreamWindowInputView,
        mode: MouseTrackingMode,
        size: StreamInputSize,
        active: Bool
    )
    func stop()
    func setTrackingMode(_ mode: MouseTrackingMode)
    func setActive(_ active: Bool)
    func updateStreamSize(_ size: StreamInputSize)

    /// True while mouse input is captured and forwarded to the host. Clicking
    /// the picture captures; a direct gaze touch releases.
    var isCaptured: Bool { get }
    func setCaptured(_ captured: Bool)
    /// Called when capture changes because of a click or a direct touch.
    var onCaptureChanged: (@MainActor (Bool) -> Void)? { get set }
}

extension StreamMouseStrategy {
    func mouseSurfaceTouchesBegan(_ touches: Set<UITouch>, event: UIEvent?) {}
    func mouseSurfaceTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {}
    func mouseSurfaceTouchesEnded(_ touches: Set<UITouch>, event: UIEvent?) {}
    func mouseSurfaceTouchesCancelled(_ touches: Set<UITouch>, event: UIEvent?) {}
    func mouseSurfaceDidLayout() {}
    func mouseSurfaceDidMoveToWindow() {}
}

/// Sends stream input and owns the held-button state. A press is forwarded
/// only when the strategy allows it; a release is forwarded only for a button
/// this sender actually pressed, so the host never gets a stuck button.
@MainActor
final class MouseEventSender {
    private(set) var heldButtons = Set<StreamMouseButton>()
    private var forwarding = true

    func setForwarding(_ forwarding: Bool) {
        self.forwarding = forwarding
        if !forwarding {
            releaseAll()
        }
    }

    func move(dx: Int32, dy: Int32) {
        guard forwarding, dx != 0 || dy != 0 else { return }
        LiSendMouseMoveEvent(
            Int16(clamping: dx),
            Int16(clamping: dy)
        )
    }

    func position(x: Int32, y: Int32, referenceWidth: Int32, referenceHeight: Int32) {
        guard forwarding, referenceWidth > 0, referenceHeight > 0 else { return }
        LiSendMousePositionEvent(
            Int16(clamping: x),
            Int16(clamping: y),
            Int16(clamping: referenceWidth),
            Int16(clamping: referenceHeight)
        )
    }

    func button(_ button: StreamMouseButton, pressed: Bool, allowed: Bool) {
        if pressed {
            guard forwarding, allowed, !heldButtons.contains(button) else { return }
            heldButtons.insert(button)
            LiSendMouseButtonEvent(0x07, button.rawValue)
        } else {
            guard heldButtons.remove(button) != nil else { return }
            LiSendMouseButtonEvent(0x08, button.rawValue)
        }
    }

    func highResScroll(y: Int32, x: Int32) {
        guard forwarding else { return }
        if y != 0 {
            LiSendHighResScrollEvent(Int16(clamping: y))
        }
        if x != 0 {
            LiSendHighResHScrollEvent(Int16(clamping: x))
        }
    }

    func scroll(y: Int32, x: Int32) {
        guard forwarding else { return }
        if y != 0 {
            LiSendScrollEvent(Int8(clamping: y))
        }
        if x != 0 {
            LiSendHScrollEvent(Int8(clamping: x))
        }
    }

    func releaseAll() {
        for button in heldButtons {
            LiSendMouseButtonEvent(0x08, button.rawValue)
        }
        heldButtons.removeAll()
    }
}

/// Aspect-fit geometry matching `AVLayerVideoGravityResizeAspect`, which is what
/// the renderer uses. Absolute pointer positions are mapped through this rect.
struct MouseInputGeometry {
    let viewSize: CGSize
    let streamWidth: Int32
    let streamHeight: Int32

    var videoRect: CGRect {
        guard viewSize.width > 0, viewSize.height > 0,
              streamWidth > 0, streamHeight > 0 else { return .zero }
        let scale = min(
            viewSize.width / CGFloat(streamWidth),
            viewSize.height / CGFloat(streamHeight)
        )
        let size = CGSize(
            width: CGFloat(streamWidth) * scale,
            height: CGFloat(streamHeight) * scale
        )
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func normalizedPoint(for viewPoint: CGPoint) -> CGPoint? {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let clampedX = min(max(viewPoint.x, rect.minX), rect.maxX)
        let clampedY = min(max(viewPoint.y, rect.minY), rect.maxY)
        return CGPoint(
            x: (clampedX - rect.minX) / rect.width,
            y: (clampedY - rect.minY) / rect.height
        )
    }

    func streamPoint(for viewPoint: CGPoint) -> (x: Int32, y: Int32)? {
        guard let normalized = normalizedPoint(for: viewPoint) else { return nil }
        let x = min(
            max(Int32((normalized.x * CGFloat(streamWidth)).rounded(.down)), 0),
            streamWidth - 1
        )
        let y = min(
            max(Int32((normalized.y * CGFloat(streamHeight)).rounded(.down)), 0),
            streamHeight - 1
        )
        return (x, y)
    }

    func contains(_ point: CGPoint) -> Bool {
        videoRect.contains(point)
    }
}

/// Watches one hover gesture over the render view. Hover is the only visionOS
/// source of absolute pointer position; it pauses while a mouse button is held.
@MainActor
final class MouseHoverRecognizer: NSObject {
    /// (point in the view, is active)
    var onHover: (@MainActor (CGPoint, Bool) -> Void)?

    private weak var view: UIView?
    private var recognizer: UIHoverGestureRecognizer?

    func install(on view: UIView) {
        remove()
        self.view = view
        let recognizer = UIHoverGestureRecognizer(target: self, action: #selector(handle(_:)))
        recognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
    }

    func remove() {
        if let recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        view = nil
    }

    @objc private func handle(_ gesture: UIHoverGestureRecognizer) {
        guard let view = gesture.view else { return }
        switch gesture.state {
        case .began, .changed:
            onHover?(gesture.location(in: view), true)
        case .ended, .cancelled, .failed:
            onHover?(.zero, false)
        default:
            break
        }
    }
}

/// Forwards the indirect-pointer touch path used by visionOS mice/trackpads.
/// A touch begins with a button mask, moves while held, and ends on release.
@MainActor
final class IndirectPointerHandler {
    var onPosition: (@MainActor (CGPoint) -> Void)?
    var onButton: (@MainActor (StreamMouseButton, Bool) -> Void)?

    private var buttons: [ObjectIdentifier: StreamMouseButton] = [:]

    func began(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
        for touch in touches where touch.type == .indirectPointer {
            onPosition?(touch.location(in: view))
            let button = Self.button(for: event)
            buttons[ObjectIdentifier(touch)] = button
            onButton?(button, true)
        }
    }

    func moved(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
        for touch in touches where touch.type == .indirectPointer {
            onPosition?(touch.location(in: view))
        }
    }

    func ended(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView, cancelled: Bool) {
        for touch in touches where touch.type == .indirectPointer {
            onPosition?(touch.location(in: view))
            if let button = buttons.removeValue(forKey: ObjectIdentifier(touch)) {
                onButton?(button, false)
            }
        }
    }

    func reset() {
        for button in buttons.values {
            onButton?(button, false)
        }
        buttons.removeAll()
    }

    private static func button(for event: UIEvent?) -> StreamMouseButton {
        let mask = event?.buttonMask ?? .primary
        if mask.contains(.primary) { return .left }
        if mask.contains(.secondary) { return .right }
        if mask.contains(.button(3)) { return .middle }
        if mask.contains(.button(4)) { return .back }
        if mask.contains(.button(5)) { return .forward }
        return .left
    }
}

/// The continuous/discrete scroll recognizers used by the core client and
/// other clients. `allowedTouchTypes = []` keeps fingers out of the recognizer, and
/// the split masks let UIKit apply Natural Scrolling before we convert.
@MainActor
final class MouseScrollRecognizers: NSObject {
    /// (high-resolution horizontal, high-resolution vertical)
    var onHighResScroll: (@MainActor (Int32, Int32) -> Void)?
    /// (horizontal clicks, vertical clicks)
    var onDiscreteScroll: (@MainActor (Int32, Int32) -> Void)?

    private weak var view: UIView?
    private var continuous: UIPanGestureRecognizer?
    private var discrete: UIPanGestureRecognizer?
    private var lastTranslation = CGPoint.zero

    func install(on view: UIView) {
        remove()
        self.view = view

        let continuous = UIPanGestureRecognizer(target: self, action: #selector(handleContinuous(_:)))
        continuous.allowedScrollTypesMask = .continuous
        continuous.allowedTouchTypes = []
        continuous.cancelsTouchesInView = false
        view.addGestureRecognizer(continuous)
        self.continuous = continuous

        let discrete = UIPanGestureRecognizer(target: self, action: #selector(handleDiscrete(_:)))
        discrete.allowedScrollTypesMask = .discrete
        discrete.allowedTouchTypes = []
        discrete.cancelsTouchesInView = false
        view.addGestureRecognizer(discrete)
        self.discrete = discrete
    }

    func remove() {
        for recognizer in [continuous, discrete].compactMap({ $0 }) {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        continuous = nil
        discrete = nil
        view = nil
        lastTranslation = .zero
    }

    @objc private func handleContinuous(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        switch gesture.state {
        case .began, .changed:
            break
        default:
            lastTranslation = .zero
            return
        }
        let translation = gesture.translation(in: view)
        let height = max(view.bounds.height, 1)
        let width = max(view.bounds.width, 1)
        // Match the core client: one full view height of travel is
        // WHEEL_DELTA * 20 high-resolution units.
        let multiplier: CGFloat = 120 * 20
        let dy = Int32(clamping: Int(((translation.y - lastTranslation.y) / height) * multiplier))
        let dx = Int32(clamping: Int(((translation.x - lastTranslation.x) / width) * multiplier))
        if dy != 0 || dx != 0 {
            onHighResScroll?(dx == 0 ? 0 : -dx, dy)
            lastTranslation = translation
        }
    }

    @objc private func handleDiscrete(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        switch gesture.state {
        case .began, .changed:
            break
        default:
            lastTranslation = .zero
            return
        }
        let translation = gesture.translation(in: view)
        let dy = translation.y - lastTranslation.y
        let dx = translation.x - lastTranslation.x
        let vertical: Int32 = dy > 0 ? 1 : (dy < 0 ? -1 : 0)
        let horizontal: Int32 = dx > 0 ? -1 : (dx < 0 ? 1 : 0)
        if vertical != 0 || horizontal != 0 {
            onDiscreteScroll?(horizontal, vertical)
        }
        lastTranslation = translation
    }
}

/// Watches every GCMouse profile. visionOS may expose several profiles for one
/// physical device; the first profile that produces an event becomes the
/// source, so movement is never forwarded twice.
@MainActor
final class GCMouseHub {
    struct Handlers {
        var moved: @MainActor (Float, Float) -> Void
        var button: @MainActor (StreamMouseButton, Bool) -> Void
        var scroll: @MainActor (Float, Float) -> Void
        var presence: @MainActor (Bool) -> Void
    }

    private var handlers: Handlers?
    private var profiles: [GCMouse] = []
    private var activeProfile: GCMouse?
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var attachRetry: DispatchWorkItem?
    private var attachRetries = 0
    private var reportedPresence = false
    private var lastActivityTime = Date.timeIntervalSinceReferenceDate

    var isConnected: Bool { !profiles.isEmpty }

    func start(_ handlers: Handlers) {
        stop()
        self.handlers = handlers
        running = true
        lastActivityTime = Date.timeIntervalSinceReferenceDate
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshProfiles() }
            },
            center.addObserver(forName: .GCMouseDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshProfiles() }
            },
            center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshProfiles() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.repairHandlers() }
            }
        ]
        refreshProfiles()
    }

    func stop() {
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        attachRetry?.cancel()
        attachRetry = nil
        attachRetries = 0
        profiles.removeAll()
        activeProfile = nil
        handlers = nil
        reportedPresence = false
        lastActivityTime = Date.timeIntervalSinceReferenceDate
    }

    private func refreshProfiles() {
        guard running else { return }
        let current = GCMouse.mice().filter { $0.mouseInput != nil }
        let previousCount = profiles.count
        let attached = profiles
        for mouse in attached where !current.contains(where: { $0 === mouse }) {
            detach(mouse)
        }
        for mouse in current where !profiles.contains(where: { $0 === mouse }) {
            attach(mouse)
        }
        if profiles.isEmpty {
            scheduleAttachRetry()
        } else {
            attachRetry?.cancel()
            attachRetry = nil
            attachRetries = 0
        }
        if profiles.count != previousCount {
            NSLog("[Mouse] GCMouse profiles: %d -> %d (mice=%d)", previousCount, profiles.count, current.count)
        }
        reportPresence()
    }

    /// While no profile is attached, keep looking for one for a few seconds.
    /// (Profiles that are present but whose handlers were dropped are repaired
    /// by the connect/current and app-activation events instead of a poll.)
    private func scheduleAttachRetry() {
        guard attachRetries < 20 else { return }
        attachRetries += 1
        attachRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.profiles.isEmpty else { return }
            self.refreshProfiles()
        }
        attachRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Re-installs handlers on the current profiles. Called by connect/current
    /// notifications and when the app becomes active again, which is when the
    /// system may have reset them (for example after a window is re-opened).
    func repairHandlers() {
        guard running else { return }
        refreshProfiles()
        for mouse in profiles {
            installHandlers(on: mouse)
        }
    }

    private func attach(_ mouse: GCMouse) {
        guard mouse.mouseInput != nil else { return }
        profiles.append(mouse)
        installHandlers(on: mouse)
    }

    private func installHandlers(on mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }

        input.mouseMovedHandler = { [weak self, weak mouse] _, dx, dy in
            MainActor.assumeIsolated {
                guard let self, let mouse else { return }
                self.handleMove(from: mouse, dx: dx, dy: dy)
            }
        }
        input.leftButton.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self, let mouse else { return }
                self.handleButton(from: mouse, button: .left, pressed: pressed)
            }
        }
        input.rightButton?.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self, let mouse else { return }
                self.handleButton(from: mouse, button: .right, pressed: pressed)
            }
        }
        input.middleButton?.pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self, let mouse else { return }
                self.handleButton(from: mouse, button: .middle, pressed: pressed)
            }
        }
        if let auxiliary = input.auxiliaryButtons {
            if auxiliary.count >= 1 {
                auxiliary[0].pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
                    MainActor.assumeIsolated {
                        guard let self, let mouse else { return }
                        self.handleButton(from: mouse, button: .back, pressed: pressed)
                    }
                }
            }
            if auxiliary.count >= 2 {
                auxiliary[1].pressedChangedHandler = { [weak self, weak mouse] _, _, pressed in
                    MainActor.assumeIsolated {
                        guard let self, let mouse else { return }
                        self.handleButton(from: mouse, button: .forward, pressed: pressed)
                    }
                }
            }
        }
        input.scroll.yAxis.valueChangedHandler = { [weak self, weak mouse] _, value in
            MainActor.assumeIsolated {
                guard let self, let mouse else { return }
                self.handleScroll(from: mouse, vertical: value)
            }
        }
        input.scroll.xAxis.valueChangedHandler = { [weak self, weak mouse] _, value in
            MainActor.assumeIsolated {
                guard let self, let mouse else { return }
                self.handleScroll(from: mouse, horizontal: value)
            }
        }
    }

    private func detach(_ mouse: GCMouse) {
        if activeProfile === mouse {
            activeProfile = nil
        }
        // Handlers are left installed on purpose: they capture this hub weakly
        // and no-op once it is stopped, and clearing them here used to race a
        // newer session that had just attached its own handlers to the same
        // GCMouse, leaving the app without mouse input until relaunch.
        profiles.removeAll { $0 === mouse }
    }

    private func isSource(_ mouse: GCMouse) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        if activeProfile == nil {
            activeProfile = mouse
            lastActivityTime = now
            NSLog("[Mouse] input source -> %@", mouse.vendorName ?? "unknown")
            return true
        }
        if activeProfile === mouse {
            lastActivityTime = now
            return true
        }
        // visionOS can expose one profile for the mouse and another for the
        // trackpad. A profile that reports while the current source has been
        // idle takes over; profiles that report at the same instant are most
        // likely duplicate profiles of the same physical device.
        guard now - lastActivityTime >= 0.2 else { return false }
        activeProfile = mouse
        lastActivityTime = now
        NSLog("[Mouse] input source -> %@", mouse.vendorName ?? "unknown")
        return true
    }

    private func handleMove(from mouse: GCMouse, dx: Float, dy: Float) {
        guard running, isSource(mouse) else { return }
        handlers?.moved(dx, dy)
    }

    private func handleButton(from mouse: GCMouse, button: StreamMouseButton, pressed: Bool) {
        guard running, isSource(mouse) else { return }
        handlers?.button(button, pressed)
    }

    private func handleScroll(from mouse: GCMouse, vertical: Float? = nil, horizontal: Float? = nil) {
        guard running, isSource(mouse) else { return }
        handlers?.scroll(horizontal ?? 0, vertical ?? 0)
    }

    private func reportPresence() {
        let present = !profiles.isEmpty
        guard present != reportedPresence else { return }
        reportedPresence = present
        handlers?.presence(present)
    }
}
