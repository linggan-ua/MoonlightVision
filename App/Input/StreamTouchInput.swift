//
//  StreamTouchInput.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation
import UIKit

/// Handles gaze + pinch / direct touches on the picture. visionOS delivers a
/// pinch as a direct `UITouch`; forwarding it with `LiSendTouchEvent` makes the
/// host see a real touchscreen contact (the same model Steam Link exposes),
/// rather than moving the mouse.
@MainActor
protocol StreamDirectTouchDelegate: AnyObject {
    func directTouchesBegan(_ touches: Set<UITouch>, in view: UIView)
    func directTouchesMoved(_ touches: Set<UITouch>, in view: UIView)
    func directTouchesEnded(_ touches: Set<UITouch>, in view: UIView)
    func directTouchesCancelled(_ touches: Set<UITouch>, in view: UIView)
}

@MainActor
final class StreamTouchInput: StreamDirectTouchDelegate {
    private var touchIDs: [ObjectIdentifier: UInt32] = [:]
    private var nextID: UInt32 = 1
    /// While the mouse has hidden the controls, the first gaze tap only
    /// restores them. Suppress that whole contact so it cannot click the host.
    private var chromeHidden = false
    private var suppressRestoreTap = false
    private var suppressedTouches = Set<ObjectIdentifier>()
    private var streamWidth: Int32 = 1920
    private var streamHeight: Int32 = 1080

    private struct TouchpadContact {
        var last: CGPoint
    }

    private var touchpadContacts: [ObjectIdentifier: TouchpadContact] = [:]
    private var touchpadCentroid: CGPoint?
    private var touchpadTapStartedAt: TimeInterval = 0
    private var touchpadMoved = false
    private var touchpadTwoFinger = false

    private var touchpadMode: Bool {
        StreamSettingsStore.shared.touchpadMode
    }

    /// Fallback used when the host does not advertise touch/pen support.
    private weak var fallbackTouch: UITouch?
    private var fallbackPressed = false

    func updateStreamSize(width: Int32, height: Int32) {
        streamWidth = max(width, 1)
        streamHeight = max(height, 1)
    }

    func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
    }

    func setSuppressRestoreTap(_ value: Bool) {
        suppressRestoreTap = value
    }

    func directTouchesBegan(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches where touch.type == .direct {
            if chromeHidden && suppressRestoreTap {
                suppressedTouches.insert(ObjectIdentifier(touch))
                continue
            }
            if touchpadMode {
                beginTouchpadTouch(touch, in: view)
                continue
            }
            let id = nextID
            nextID &+= 1
            touchIDs[ObjectIdentifier(touch)] = id
            send(event: Self.downEvent, touch: touch, id: id, in: view)
        }
    }

    func directTouchesMoved(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches where touch.type == .direct {
            if suppressedTouches.contains(ObjectIdentifier(touch)) { continue }
            if touchpadMode {
                moveTouchpadTouch(touch, in: view)
                continue
            }
            guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
            send(event: Self.moveEvent, touch: touch, id: id, in: view)
        }
    }

    func directTouchesEnded(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches where touch.type == .direct {
            let key = ObjectIdentifier(touch)
            if suppressedTouches.remove(key) != nil { continue }
            if touchpadMode {
                endTouchpadTouch(touch, in: view)
                continue
            }
            guard let id = touchIDs.removeValue(forKey: key) else { continue }
            send(event: Self.upEvent, touch: touch, id: id, in: view)
        }
    }

    func directTouchesCancelled(_ touches: Set<UITouch>, in view: UIView) {
        for touch in touches where touch.type == .direct {
            let key = ObjectIdentifier(touch)
            if suppressedTouches.remove(key) != nil { continue }
            if touchpadMode {
                touchpadContacts.removeValue(forKey: key)
                if touchpadContacts.isEmpty {
                    touchpadCentroid = nil
                    touchpadMoved = false
                    touchpadTwoFinger = false
                }
                continue
            }
            guard let id = touchIDs.removeValue(forKey: key) else { continue }
            if hostSupportsTouch {
                _ = LiSendTouchEvent(
                    Self.cancelEvent,
                    id,
                    0, 0, 0, 0, 0,
                    Self.unknownRotation
                )
            }
        }
        if fallbackPressed, let fallbackTouch {
            fallbackRelease(fallbackTouch, in: view)
        }
        fallbackTouch = nil
    }

    private func beginTouchpadTouch(_ touch: UITouch, in view: UIView) {
        let key = ObjectIdentifier(touch)
        let point = touch.location(in: view)
        if touchpadContacts.isEmpty {
            touchpadTapStartedAt = Date.timeIntervalSinceReferenceDate
            touchpadMoved = false
            touchpadTwoFinger = false
            touchpadCentroid = nil
        }
        touchpadContacts[key] = TouchpadContact(last: point)
        if touchpadContacts.count >= 2 {
            touchpadTwoFinger = true
            touchpadCentroid = centroid(of: touchpadContacts)
        }
    }

    private func moveTouchpadTouch(_ touch: UITouch, in view: UIView) {
        let key = ObjectIdentifier(touch)
        guard var contact = touchpadContacts[key] else { return }
        let point = touch.location(in: view)

        if touchpadContacts.count >= 2 {
            contact.last = point
            touchpadContacts[key] = contact
            let centre = centroid(of: touchpadContacts)
            if let previous = touchpadCentroid {
                let dx = centre.x - previous.x
                let dy = centre.y - previous.y
                if abs(dx) + abs(dy) > 0.5 {
                    touchpadMoved = true
                    let height = max(view.bounds.height, 1)
                    let multiplier = 120.0 * 20.0 / height
                    let scrollY = Int32(clamping: Int((dy * multiplier).rounded()))
                    let scrollX = Int32(clamping: Int((-dx * multiplier).rounded()))
                    if scrollY != 0 {
                        LiSendHighResScrollEvent(Int16(clamping: scrollY))
                    }
                    if scrollX != 0 {
                        LiSendHighResHScrollEvent(Int16(clamping: scrollX))
                    }
                }
            }
            touchpadCentroid = centre
        } else {
            let dx = point.x - contact.last.x
            let dy = point.y - contact.last.y
            if abs(dx) + abs(dy) > 0.5 {
                touchpadMoved = true
                LiSendMouseMoveEvent(
                    Int16(clamping: Int32((dx * 2).rounded())),
                    Int16(clamping: Int32((dy * 2).rounded()))
                )
            }
            contact.last = point
            touchpadContacts[key] = contact
        }
    }

    private func endTouchpadTouch(_ touch: UITouch, in view: UIView) {
        let key = ObjectIdentifier(touch)
        guard touchpadContacts.removeValue(forKey: key) != nil else { return }
        guard touchpadContacts.isEmpty else {
            if touchpadContacts.count == 1 {
                touchpadCentroid = nil
                touchpadTwoFinger = false
            }
            return
        }

        let elapsed = Date.timeIntervalSinceReferenceDate - touchpadTapStartedAt
        if !touchpadMoved && elapsed < 0.45 {
            if touchpadTwoFinger {
                LiSendMouseButtonEvent(0x07, 0x03)
                LiSendMouseButtonEvent(0x08, 0x03)
            } else {
                LiSendMouseButtonEvent(0x07, 0x01)
                LiSendMouseButtonEvent(0x08, 0x01)
            }
        }

        touchpadCentroid = nil
        touchpadMoved = false
        touchpadTwoFinger = false
    }

    private func centroid(of contacts: [ObjectIdentifier: TouchpadContact]) -> CGPoint {
        guard !contacts.isEmpty else { return .zero }
        let sum = contacts.values.reduce(CGPoint.zero) { partial, contact in
            CGPoint(x: partial.x + contact.last.x, y: partial.y + contact.last.y)
        }
        return CGPoint(
            x: sum.x / CGFloat(contacts.count),
            y: sum.y / CGFloat(contacts.count)
        )
    }

    /// Cancels every active contact. Called on stream teardown/focus loss.
    func cancelAll() {
        if hostSupportsTouch {
            _ = LiSendTouchEvent(
                Self.cancelAllEvent,
                0, 0, 0, 0, 0, 0,
                Self.unknownRotation
            )
        }
        if fallbackPressed {
            LiSendMouseButtonEvent(0x08, Int32(0x01))
        }
        fallbackPressed = false
        fallbackTouch = nil
        touchIDs.removeAll()
        suppressedTouches.removeAll()
        touchpadContacts.removeAll()
        touchpadCentroid = nil
        touchpadMoved = false
        touchpadTwoFinger = false
    }

    // MARK: - Sending

    private static let hoverEvent = UInt8(LI_TOUCH_EVENT_HOVER)
    private static let downEvent = UInt8(LI_TOUCH_EVENT_DOWN)
    private static let upEvent = UInt8(LI_TOUCH_EVENT_UP)
    private static let moveEvent = UInt8(LI_TOUCH_EVENT_MOVE)
    private static let cancelEvent = UInt8(LI_TOUCH_EVENT_CANCEL)
    private static let cancelAllEvent = UInt8(LI_TOUCH_EVENT_CANCEL_ALL)
    private static let unknownRotation = UInt16(LI_ROT_UNKNOWN)

    private var hostSupportsTouch: Bool {
        (LiGetHostFeatureFlags() & UInt32(LI_FF_PEN_TOUCH_EVENTS)) != 0
    }

    private func send(
        event: UInt8,
        touch: UITouch,
        id: UInt32,
        in view: UIView
    ) {
        guard let normalized = normalizedLocation(of: touch, in: view) else { return }

        if hostSupportsTouch {
            _ = LiSendTouchEvent(
                event,
                id,
                Float(normalized.x),
                Float(normalized.y),
                1.0,
                0,
                0,
                Self.unknownRotation
            )
            return
        }

        // Sunshine hosts that don't support touch fall back to an absolute
        // mouse contact: down presses, move positions, up releases.
        switch event {
        case Self.downEvent:
            sendFallbackPosition(normalized, in: view)
            if !fallbackPressed {
                fallbackPressed = true
                fallbackTouch = touch
                LiSendMouseButtonEvent(0x07, Int32(0x01))
            }
        case Self.moveEvent:
            if fallbackTouch === touch {
                sendFallbackPosition(normalized, in: view)
            }
        case Self.upEvent:
            if fallbackTouch === touch {
                sendFallbackPosition(normalized, in: view)
                fallbackRelease(touch, in: view)
            }
        default:
            break
        }
    }

    private func sendFallbackPosition(_ normalized: CGPoint, in view: UIView) {
        let x = Int32((normalized.x * CGFloat(streamWidth)).rounded(.down))
        let y = Int32((normalized.y * CGFloat(streamHeight)).rounded(.down))
        LiSendMousePositionEvent(
            Int16(clamping: x),
            Int16(clamping: y),
            Int16(clamping: streamWidth),
            Int16(clamping: streamHeight)
        )
    }

    private func fallbackRelease(_ touch: UITouch, in view: UIView) {
        guard fallbackPressed else { return }
        fallbackPressed = false
        fallbackTouch = nil
        LiSendMouseButtonEvent(0x08, Int32(0x01))
    }

    private func normalizedLocation(of touch: UITouch, in view: UIView) -> CGPoint? {
        let geometry = MouseInputGeometry(
            viewSize: view.bounds.size,
            streamWidth: streamWidth,
            streamHeight: streamHeight
        )
        return geometry.normalizedPoint(for: touch.location(in: view))
    }
}
