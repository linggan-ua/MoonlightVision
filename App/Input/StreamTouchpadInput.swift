//
//  StreamTouchpadInput.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import UIKit

/// Whole-screen touchpad mode. A one-finger drag moves the host mouse, a tap
/// clicks, and a two-finger drag scrolls. It uses UIKit gesture recognizers on
/// the stream view, so it receives gaze + pinch direct touches reliably.
@MainActor
final class StreamTouchpadInput: NSObject {
    private weak var view: UIView?
    private var pan: UIPanGestureRecognizer?
    private var tap: UITapGestureRecognizer?
    private var twoFingerTap: UITapGestureRecognizer?
    private var longPress: UILongPressGestureRecognizer?
    private var lastTranslation = CGPoint.zero
    private var moved = false

    var chromeHidden = false
    var suppressRestoreTap = false

    func install(on view: UIView) {
        remove()
        self.view = view

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        self.pan = pan

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        self.tap = tap

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        twoFingerTap.require(toFail: tap)
        view.addGestureRecognizer(twoFingerTap)
        self.twoFingerTap = twoFingerTap

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        longPress.minimumPressDuration = 0.55
        longPress.cancelsTouchesInView = false
        tap.require(toFail: longPress)
        view.addGestureRecognizer(longPress)
        self.longPress = longPress
    }

    func remove() {
        if let pan { pan.view?.removeGestureRecognizer(pan) }
        if let tap { tap.view?.removeGestureRecognizer(tap) }
        if let twoFingerTap { twoFingerTap.view?.removeGestureRecognizer(twoFingerTap) }
        if let longPress { longPress.view?.removeGestureRecognizer(longPress) }
        pan = nil
        tap = nil
        twoFingerTap = nil
        longPress = nil
        view = nil
        lastTranslation = .zero
        moved = false
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            lastTranslation = .zero
            moved = false

        case .changed:
            let dx = translation.x - lastTranslation.x
            let dy = translation.y - lastTranslation.y
            guard abs(dx) + abs(dy) > 0.5 else { return }
            moved = true

            if gesture.numberOfTouches >= 2 {
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
            } else {
                LiSendMouseMoveEvent(
                    Int16(clamping: Int32((dx * 4).rounded())),
                    Int16(clamping: Int32((dy * 4).rounded()))
                )
            }
            lastTranslation = translation

        case .ended:
            reset()

        case .cancelled, .failed:
            reset()

        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if chromeHidden && suppressRestoreTap { return }
        click(button: 0x01)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        if chromeHidden && suppressRestoreTap { return }
        click(button: 0x03)
    }

    /// Long press is the right-click gesture used by the old gaze input.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !moved else { return }
        if chromeHidden && suppressRestoreTap { return }
        click(button: 0x03)
    }

    private func click(button: Int32) {
        LiSendMouseButtonEvent(0x07, button)
        LiSendMouseButtonEvent(0x08, button)
    }

    private func reset() {
        lastTranslation = .zero
        moved = false
    }
}
