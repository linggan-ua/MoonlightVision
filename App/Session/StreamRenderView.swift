import SwiftUI
import UIKit

/// The UIView that hosts the AVSampleBufferDisplayLayer created by the core
/// renderer, hides the system pointer, and forwards physical keyboard presses.
final class StreamRenderView: UIView {
    private var heldKeys: [UInt16: UIKey] = [:]
    private var heldArrowPresses: [UIPress] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        super.touchesBegan(touches, with: event)
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

struct StreamRenderViewRepresentable: UIViewRepresentable {
    let view: StreamRenderView

    func makeUIView(context: Context) -> StreamRenderView {
        view
    }

    func updateUIView(_ uiView: StreamRenderView, context: Context) {}
}
