//
//  StreamWindowInputView.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import SwiftUI
import UIKit

/// The stream window's input surface. It sits above the RealityKit video
/// plane and forwards physical keyboard presses, mouse/indirect-pointer
/// events, and gaze/pinch touches to the active strategies.
final class StreamWindowInputView: UIView {
    /// The active mouse strategy. Replaced on every stream start.
    weak var mouseSurfaceDelegate: StreamMouseSurfaceDelegate?

    /// Forwards direct (gaze/pinch) touches to the host as touchscreen input.
    weak var directTouchDelegate: StreamDirectTouchDelegate?

    /// A gaze + pinch (direct touch) on the picture. Physical mouse clicks are
    /// indirect-pointer events and do not trigger this.
    var onDirectTap: (() -> Void)?
    private var appliedHeadroom: CGFloat = 2.0
    private var isHDRContent = false

    /// The first direct contact of a gaze/pinch gesture, delivered before the
    /// touch is forwarded. The session uses it to release mouse capture.
    var onDirectTouchBegan: (() -> Void)?

    private let touchpad = StreamTouchpadInput()
    private(set) var touchpadMode = false

    private var heldKeys: [UInt16: UIKey] = [:]
    private var heldArrowPresses: [UIPress] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The video is a RealityKit plane behind this view. Match the
        // core client's nearly transparent input layer so the window
        // still composites as a non-empty surface without covering the plane.
        backgroundColor = UIColor.black.withAlphaComponent(0.01)
        isOpaque = false
        isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDirectTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        touchpad.onTap = { [weak self] in
            self?.onDirectTap?()
        }
    }

    @objc private func handleDirectTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onDirectTap?()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    func setTouchpadMode(_ enabled: Bool) {
        guard touchpadMode != enabled else { return }
        touchpadMode = enabled
        if enabled {
            touchpad.install(on: self)
        } else {
            touchpad.remove()
        }
    }

    func setTouchpadChromeHidden(_ hidden: Bool) {
        touchpad.chromeHidden = hidden
    }

    func setTouchpadSuppressRestoreTap(_ value: Bool) {
        touchpad.suppressRestoreTap = value
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        mouseSurfaceDelegate?.mouseSurfaceDidMoveToWindow()
        guard window != nil else { return }
        applyLayerEDR()
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    /// Tags the window's layer tree for high dynamic range. RealityKit hosts
    /// the video in a child CAMetalLayer; walking the tree covers it as it
    /// appears. `toneMapMode = .never` keeps the compositor from tone mapping
    /// our already tone-mapped EDR image a second time.
    func applyHDRHeadroom(_ headroom: CGFloat, enabled: Bool) {
        appliedHeadroom = max(headroom, 1.0)
        isHDRContent = enabled
        applyLayerEDR()
    }

    private func applyLayerEDR() {
        guard let window else { return }
        Self.applyEDR(to: window.layer, headroom: appliedHeadroom, enabled: isHDRContent)
    }

    private static func applyEDR(to layer: CALayer, headroom: CGFloat, enabled: Bool) {
        if enabled {
            layer.toneMapMode = .never
            if #available(visionOS 26.0, *) {
                layer.preferredDynamicRange = .high
                layer.contentsHeadroom = headroom
            }
        } else {
            layer.toneMapMode = .automatic
            if #available(visionOS 26.0, *) {
                layer.preferredDynamicRange = .standard
                layer.contentsHeadroom = 0
            }
        }
        layer.sublayers?.forEach { applyEDR(to: $0, headroom: headroom, enabled: enabled) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .direct }) {
            onDirectTouchBegan?()
        }
        if !touchpadMode {
            directTouchDelegate?.directTouchesBegan(touches, in: self)
        }
        mouseSurfaceDelegate?.mouseSurfaceTouchesBegan(touches, event: event)
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !touchpadMode {
            directTouchDelegate?.directTouchesMoved(touches, in: self)
        }
        mouseSurfaceDelegate?.mouseSurfaceTouchesMoved(touches, event: event)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !touchpadMode {
            directTouchDelegate?.directTouchesEnded(touches, in: self)
        }
        mouseSurfaceDelegate?.mouseSurfaceTouchesEnded(touches, event: event)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !touchpadMode {
            directTouchDelegate?.directTouchesCancelled(touches, in: self)
        }
        mouseSurfaceDelegate?.mouseSurfaceTouchesCancelled(touches, event: event)
        super.touchesCancelled(touches, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mouseSurfaceDelegate?.mouseSurfaceDidLayout()
        applyLayerEDR()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if KeyboardSupport.sendKeyEvent(for: press, down: true) {
                handled = true
                if let key = press.key {
                    heldKeys[UInt16(key.keyCode.rawValue)] = key
                } else {
                    heldArrowPresses.append(press)
                }
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if KeyboardSupport.sendKeyEvent(for: press, down: false) {
                handled = true
                if let key = press.key {
                    heldKeys.removeValue(forKey: UInt16(key.keyCode.rawValue))
                } else {
                    heldArrowPresses.removeAll { $0 === press }
                }
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        releaseHeldKeys()
        super.pressesCancelled(presses, with: event)
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldKeys()
        return super.resignFirstResponder()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            releaseHeldKeys()
        }
        super.willMove(toWindow: newWindow)
    }

    /// Release every key still held by the host. Called on focus loss, window
    /// removal, backgrounding and input teardown so the host cannot keep a key
    /// stuck down.
    func releaseHeldKeys() {
        for key in heldKeys.values {
            _ = KeyboardSupport.sendKeyEvent(key, down: false)
        }
        for press in heldArrowPresses {
            _ = KeyboardSupport.sendKeyEvent(for: press, down: false)
        }
        heldKeys.removeAll()
        heldArrowPresses.removeAll()
    }
}

struct StreamWindowInputViewRepresentable: UIViewControllerRepresentable {
    let view: StreamWindowInputView

    func makeUIViewController(context: Context) -> StreamWindowInputViewController {
        StreamWindowInputViewController(inputView: view)
    }

    func updateUIViewController(
        _ controller: StreamWindowInputViewController,
        context: Context
    ) {}
}

/// A view controller gives the stream view the same resize behavior the old
/// UIKit client had: its root view always fills the window, and the decoder's
/// display layer follows the changing bounds.
final class StreamWindowInputViewController: UIViewController {
    private let streamView: StreamWindowInputView

    init(inputView: StreamWindowInputView) {
        self.streamView = inputView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // Never make the shared stream view this controller's root view: a
        // view can belong to only one controller, and SwiftUI can build a new
        // controller while the old one is still alive. Hosting it as a child
        // lets addSubview move it between controllers without an ownership
        // exception.
        let container = UIView()
        container.backgroundColor = .clear
        view = container

        streamView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(streamView)
        NSLayoutConstraint.activate([
            streamView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            streamView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            streamView.topAnchor.constraint(equalTo: container.topAnchor),
            streamView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
