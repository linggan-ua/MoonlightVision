//
//  EDRProbe.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Metal
import QuartzCore
import SwiftUI
import UIKit

/// Layer configuration under test.
enum EDRProbeLayerMode: String, CaseIterable, Identifiable {
    case linearEDR
    case pq10bit
    case pqP3

    var id: String { rawValue }

    var isPQ: Bool { self == .pq10bit || self == .pqP3 }

    var title: String {
        switch self {
        case .linearEDR: return "Linear EDR (P3)"
        case .pq10bit: return "PQ (BT.2020)"
        case .pqP3: return "PQ (P3)"
        }
    }
}

/// Hosting configuration under test.
enum EDRProbeHostMode: String, CaseIterable, Identifiable {
    case window
    case fullScreenCover
    case uiKitModal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: return "In Window"
        case .fullScreenCover: return "Full Screen Cover"
        case .uiKitModal: return "UIKit Full Screen"
        }
    }
}

/// A deliberately tiny renderer: four vertical bars with known values, no
/// video decode, no RealityKit, no app color pipeline.
@MainActor
final class EDRProbeRenderer {
    let layer: CAMetalLayer
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var displayLink: CADisplayLink?
    private var mode: EDRProbeLayerMode
    private var headroom: Float
    private var colorContent: Bool
    private var colorLevel: Float
    private var colorPurity: Float
    private var automaticToneMap: Bool

    init(layer: CAMetalLayer, mode: EDRProbeLayerMode, headroom: Float, colorContent: Bool, colorLevel: Float, colorPurity: Float, automaticToneMap: Bool) throws {
        self.layer = layer
        self.mode = mode
        self.headroom = headroom
        self.colorContent = colorContent
        self.colorLevel = colorLevel
        self.colorPurity = colorPurity
        self.automaticToneMap = automaticToneMap
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "EDRProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal device"])
        }
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "EDRProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "No Metal queue"])
        }
        self.device = device
        self.queue = queue
        layer.device = device
        configureLayer()
        try buildPipeline()
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func setMode(_ mode: EDRProbeLayerMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        configureLayer()
        try? buildPipeline()
    }

    func setHeadroom(_ headroom: Float) {
        guard headroom != self.headroom else { return }
        self.headroom = headroom
        configureLayer()
        try? buildPipeline()
    }

    func setColorContent(_ colorContent: Bool) {
        self.colorContent = colorContent
    }

    func setColorLevel(_ colorLevel: Float) {
        self.colorLevel = colorLevel
    }

    func setColorPurity(_ colorPurity: Float) {
        self.colorPurity = colorPurity
    }

    func setAutomaticToneMap(_ automaticToneMap: Bool) {
        guard automaticToneMap != self.automaticToneMap else { return }
        self.automaticToneMap = automaticToneMap
        configureLayer()
    }

    func drawNow() {
        draw()
    }

    @objc private func tick() {
        draw()
    }

    private func configureLayer() {
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.contentsGravity = .resizeAspect
        layer.wantsExtendedDynamicRangeContent = true
        if #available(visionOS 26.0, *) {
            layer.preferredDynamicRange = .high
            layer.contentsHeadroom = CGFloat(headroom)
        }
        switch mode {
        case .linearEDR:
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            layer.toneMapMode = automaticToneMap ? .automatic : .never
        case .pq10bit, .pqP3:
            layer.pixelFormat = MTLPixelFormat(rawValue: 94) ?? .bgra10_xr
            layer.colorspace = CGColorSpace(
                name: mode == .pqP3 ? CGColorSpace.displayP3_PQ : CGColorSpace.itur_2100_PQ
            )
            layer.toneMapMode = automaticToneMap ? .automatic : .never
        }
        NSLog(
            "[EDRProbe] layer mode=%@ toneMap=%@ range=%@ headroom=%.2f space=%@ fmt=%u",
            mode.rawValue,
            String(describing: layer.toneMapMode),
            String(describing: layer.preferredDynamicRange),
            Double(layer.contentsHeadroom),
            String(describing: layer.colorspace),
            UInt32(layer.pixelFormat.rawValue)
        )
    }

    private func buildPipeline() throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut v(uint vid [[vertex_id]]) {
            float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
            VOut o;
            o.pos = float4(p[vid], 0, 1);
            o.uv = (p[vid] + 1.0) * 0.5;
            o.uv.y = 1.0 - o.uv.y;
            return o;
        }
        float pqFromNits(float nits) {
            const float m1 = 0.1593017578125;
            const float m2 = 78.84375;
            const float c1 = 0.8359375;
            const float c2 = 18.8515625;
            const float c3 = 18.6875;
            float y = clamp(nits / 10000.0, 0.0, 1.0);
            float ym = pow(y, m1);
            return pow((c1 + c2 * ym) / (1.0 + c3 * ym), m2);
        }
        float3 pqFromNits(float3 nits) {
            return float3(pqFromNits(nits.r), pqFromNits(nits.g), pqFromNits(nits.b));
        }
        fragment half4 f(VOut in [[stage_in]],
                         constant uint &mode [[buffer(0)]],
                         constant uint &colorContent [[buffer(1)]],
                         constant float &colorLevel [[buffer(2)]],
                         constant float &colorPurity [[buffer(3)]]) {
            uint bar = min(uint(in.uv.x * 4.0), 3u);
            if (colorContent != 0u) {
                float3 rgb = bar == 0 ? float3(1,0,0)
                           : bar == 1 ? float3(0,1,0)
                           : bar == 2 ? float3(0,0,1)
                           : float3(1,1,1);
                rgb = mix(float3(1.0), rgb, colorPurity);
                if (mode == 0u) {
                    return half4(half3(rgb * colorLevel), 1.0h);
                }
                return half4(half3(pqFromNits(rgb * colorLevel * 203.0)), 1.0h);
            }
            float v;
            if (mode == 0u) {
                v = bar == 0 ? 1.0 : bar == 1 ? 2.0 : bar == 2 ? 4.0 : 8.0;
            } else {
                float nits = bar == 0 ? 203.0 : bar == 1 ? 500.0 : bar == 2 ? 1000.0 : 2000.0;
                v = pqFromNits(nits);
            }
            return half4(v, v, v, 1.0h);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "v")
        descriptor.fragmentFunction = library.makeFunction(name: "f")
        descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func draw() {
        guard let pipeline,
              layer.drawableSize.width > 0,
              layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        var modeValue: UInt32 = mode.isPQ ? 1 : 0
        encoder.setFragmentBytes(&modeValue, length: MemoryLayout<UInt32>.size, index: 0)
        var colorValue: UInt32 = colorContent ? 1 : 0
        encoder.setFragmentBytes(&colorValue, length: MemoryLayout<UInt32>.size, index: 1)
        var levelValue = colorLevel
        encoder.setFragmentBytes(&levelValue, length: MemoryLayout<Float>.size, index: 2)
        var purityValue = colorPurity
        encoder.setFragmentBytes(&purityValue, length: MemoryLayout<Float>.size, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

@MainActor
protocol EDRProbeHosting: AnyObject {
    var metalLayer: CAMetalLayer { get }
    var renderer: EDRProbeRenderer? { get set }
}

final class EDRProbeHostView: UIView, EDRProbeHosting {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var renderer: EDRProbeRenderer?

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = contentScaleFactor
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        renderer?.drawNow()
    }
}

/// Mimics the stream's flat-HDR hosting exactly: the Metal layer is a sublayer
/// of a plain UIView whose backing layer keeps the default tone-mapping
/// settings, instead of being the view's own backing layer.
final class EDRProbeSublayerHostView: UIView, EDRProbeHosting {
    let metalLayer = CAMetalLayer()
    var renderer: EDRProbeRenderer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
        let scale = contentScaleFactor
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        renderer?.drawNow()
    }
}

struct EDRProbeView: UIViewRepresentable {
    typealias UIViewType = UIView

    let mode: EDRProbeLayerMode
    let headroom: Float
    let colorContent: Bool
    let colorLevel: Float
    let colorPurity: Float
    let automaticToneMap: Bool
    let useSublayer: Bool

    func makeUIView(context: Context) -> UIView {
        let host: UIView & EDRProbeHosting = useSublayer
            ? EDRProbeSublayerHostView()
            : EDRProbeHostView()
        host.backgroundColor = .black
        do {
            let renderer = try EDRProbeRenderer(
                layer: host.metalLayer,
                mode: mode,
                headroom: headroom,
                colorContent: colorContent,
                colorLevel: colorLevel,
                colorPurity: colorPurity,
                automaticToneMap: automaticToneMap
            )
            host.renderer = renderer
            renderer.start()
        } catch {
            NSLog("[EDRProbe] renderer failed: %@", "\(error)")
        }
        return host
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let host = view as? EDRProbeHosting else { return }
        host.renderer?.setMode(mode)
        host.renderer?.setHeadroom(headroom)
        host.renderer?.setColorContent(colorContent)
        host.renderer?.setColorLevel(colorLevel)
        host.renderer?.setColorPurity(colorPurity)
        host.renderer?.setAutomaticToneMap(automaticToneMap)
    }

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        guard let host = view as? EDRProbeHosting else { return }
        host.renderer?.stop()
        host.renderer = nil
    }
}

struct EDRProbeWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        EDRProbeSheet(onClose: { dismissWindow(id: "edr-probe") })
    }
}

struct EDRProbeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var layerMode: EDRProbeLayerMode = .linearEDR
    @State private var hostMode: EDRProbeHostMode = .window
    @State private var headroom: Float = 4.0
    @State private var colorContent = false
    @State private var colorLevel: Float = 4.0
    @State private var colorPurity: Float = 1.0
    @State private var automaticToneMap = false
    @State private var useSublayer = false
    @State private var showFullScreen = false
    var onClose: (() -> Void)? = nil

    private var labels: [String] {
        if colorContent {
            let suffix = layerMode.isPQ
                ? "\(Int(colorLevel * 203))"
                : "\(Int(colorLevel))×"
            let purity = colorPurity < 0.999 ? " \(Int(colorPurity * 100))%" : ""
            return ["Red\(purity) \(suffix)", "Green\(purity) \(suffix)", "Blue\(purity) \(suffix)", "White \(suffix)"]
        }
        switch layerMode {
        case .linearEDR: return ["1×", "2×", "4×", "8×"]
        case .pq10bit, .pqP3: return ["203 nit", "500 nit", "1000 nit", "2000 nit"]
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Layer", selection: $layerMode) {
                ForEach(EDRProbeLayerMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Host", selection: $hostMode) {
                ForEach(EDRProbeHostMode.allCases) { host in
                    Text(host.title).tag(host)
                }
            }
            .pickerStyle(.segmented)

            Picker("Hosting", selection: $useSublayer) {
                Text("Backing layer").tag(false)
                Text("Sublayer").tag(true)
            }
            .pickerStyle(.segmented)

            Picker("Tone map", selection: $automaticToneMap) {
                Text("Never").tag(false)
                Text("Automatic").tag(true)
            }
            .pickerStyle(.segmented)

            Picker("Content", selection: $colorContent) {
                Text("Grayscale").tag(false)
                Text("Color").tag(true)
            }
            .pickerStyle(.segmented)

            Picker("Headroom", selection: $headroom) {
                ForEach([Float(2), Float(4), Float(8), Float(16)], id: \.self) { value in
                    Text("\(Int(value))×").tag(value)
                }
            }
            .pickerStyle(.segmented)

            if colorContent {
                Picker("Color Level", selection: $colorLevel) {
                    ForEach([Float(2), Float(4), Float(8), Float(16)], id: \.self) { value in
                        Text("\(Int(value))×").tag(value)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Purity", selection: $colorPurity) {
                    Text("100%").tag(Float(1.0))
                    Text("95%").tag(Float(0.95))
                    Text("90%").tag(Float(0.90))
                }
                .pickerStyle(.segmented)
            }

            ZStack(alignment: .bottom) {
                EDRProbeView(mode: layerMode, headroom: headroom, colorContent: colorContent, colorLevel: colorLevel, colorPurity: colorPurity, automaticToneMap: automaticToneMap, useSublayer: useSublayer)
                HStack(spacing: 0) {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45))
            }
            .frame(minWidth: 640, minHeight: 360)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button("Present Full Screen") {
                switch hostMode {
                case .window:
                    break
                case .fullScreenCover:
                    showFullScreen = true
                case .uiKitModal:
                    presentUIKitFullScreen()
                }
            }
            .buttonStyle(.borderedProminent)

            Text("Tone map Never = layer tone mapping off (hard clip at the panel); Automatic = system tone maps the layer. Compare Purity 95%, Level 4×/8×/16×, and Level 2× to find the safe threshold.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Close") {
                if let onClose {
                    onClose()
                } else {
                    dismiss()
                }
            }
        }
        .padding(24)
        .fullScreenCover(isPresented: $showFullScreen) {
            ZStack(alignment: .topTrailing) {
                EDRProbeView(mode: layerMode, headroom: headroom, colorContent: colorContent, colorLevel: colorLevel, colorPurity: colorPurity, automaticToneMap: automaticToneMap, useSublayer: useSublayer)
                    .ignoresSafeArea()
                    .allowedDynamicRange(.high)
                Button("Close") { showFullScreen = false }
                    .padding(24)
            }
            .background(Color.black.ignoresSafeArea())
        }
    }

    private func presentUIKitFullScreen() {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow),
              let root = window.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        let content = AnyView(
            ZStack(alignment: .topTrailing) {
                EDRProbeView(mode: layerMode, headroom: headroom, colorContent: colorContent, colorLevel: colorLevel, colorPurity: colorPurity, automaticToneMap: automaticToneMap, useSublayer: useSublayer)
                    .ignoresSafeArea()
                    .allowedDynamicRange(.high)
                Button("Close") { top.dismiss(animated: false) }
                    .padding(24)
            }
            .background(Color.black.ignoresSafeArea())
        )
        let hosting = UIHostingController(rootView: content)
        hosting.modalPresentationStyle = .fullScreen
        hosting.view.backgroundColor = .black
        top.present(hosting, animated: false)
    }
}
