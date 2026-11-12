import SwiftUI
import UIKit

/// The UIView that hosts the AVSampleBufferDisplayLayer created by the core renderer.
final class StreamRenderView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct StreamRenderViewRepresentable: UIViewRepresentable {
    let view: StreamRenderView

    func makeUIView(context: Context) -> StreamRenderView {
        view
    }

    func updateUIView(_ uiView: StreamRenderView, context: Context) {}
}
