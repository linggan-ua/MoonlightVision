import SwiftUI
import UIKit

/// The UIView that hosts the AVSampleBufferDisplayLayer created by the core
/// renderer, hides the system pointer, and forwards physical keyboard presses.
final class StreamRenderView: UIView {
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
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }
}

struct StreamRenderViewRepresentable: UIViewRepresentable {
    let view: StreamRenderView

    func makeUIView(context: Context) -> StreamRenderView {
        view
    }

    func updateUIView(_ uiView: StreamRenderView, context: Context) {}
}
