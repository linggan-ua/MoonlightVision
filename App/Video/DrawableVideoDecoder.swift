//
//  DrawableVideoDecoder.swift
//  MoonlightVision
//
//  Copyright © 2025 Moonlight Game Streaming Project. All rights reserved.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore
import RealityKit
import SwiftUI
import UIKit
import VideoToolbox
import CoreFoundation
import simd

// Add these constants after your existing constants
let kCVPixelBufferYCbCrMatrixKey = "YCbCrMatrix" as CFString
let kCVPixelBufferColorPrimariesKey = "ColorPrimaries" as CFString
let kCVPixelBufferTransferFunctionKey = "TransferFunction" as CFString

struct HDRParams {
    var boost: Float
    var contrast: Float
    var saturation: Float
    var brightness: Float
    var pqExposure: Float  // PQ-only exposure trim; 1.0 = neutral
    var mode: Int32
    /// Bit 0 (`1`): Reference HDR — minimal client grading (PQ + gamut + tone map only). See `Shaders.metal` `FullHDRParams.hdrGradeFlags`.
    var hdrGradeFlags: UInt32 = 0
    /// HDR-mode SDR white level; 1.0 = neutral, lower dims SDR content.
    var sdrBrightness: Float = 1.0
    /// Tone-map peak in EDR units (1.0 = SDR white). 2.0 matches the old
    /// visionOS hardcode; higher values let HDR highlights go brighter.
    var edrHeadroom: Float = 2.0
    /// Host SDR white point in nits. PQ is normalised by this so the host's
    /// desktop white maps to EDR 1.0 (the window's SDR white), not 1.48x/2.36x.
    var sdrWhiteNits: Float = 203.0
    /// 0 = Display P3, 1 = BT.709. Selects the presentation gamut.
    var outputGamut: UInt32 = 0
}

/// ChromaHalo / Chromosphere: halo drawable / RealityKit texture size is full frame `>> mipShift`.
/// Rim pass samples **mip 0**; a **separable 13-tap blur** on the halo buffer spreads that into a smooth wash (GPU-heavy, quality-first).
enum ChromaHaloDownsample {
    /// `1` → half resolution per axis (vs stream). Pairs with separable blur for Hue-like gradients.
    static let mipShift: Int = 1
}

private let chromaHaloSourceMipLevel = 0

/// Multiplies halo texel step in separable blur (wider bleed ≈ Ambilight wall wash).
private let chromaHaloAmbilightBlurSpread: Float = 1.45

private struct ColorEnhancementUniforms {
    var saturation: Float
    var contrast: Float
    var warmth: Float
    var padding1: Float
}

// Must match ShaderHDRParams in Shaders.metal exactly (field order + alignment).
// Metal float3x3 is stored as 3 × float4 columns (48 bytes); float3 is 16 bytes (padded).
private struct ShaderHDRParams {
    var isPQ:           UInt32         // 1 = PQ/HDR path, 0 = SDR / extended
    var primariesType: UInt32         // 0=709/P3, 1=2020, 2=SMPTE-C (gamut selector)
    var extendedScene: UInt32        // 1 = HDR + non-PQ (matches `Shaders.metal` ShaderHDRParams.extendedScene)
    var reserved0:      UInt32 = 0
    var edrHeadroom:    Float          // Tone map ceiling (2.0 on visionOS)
    var pad:            Float = 0
    var alignPad:       SIMD2<Float> = .zero
    /// Sunshine maxCLL / maxFALL (nits); 0 = omit CLL-driven shoulder (see `Shaders.metal` hdrUchimuraShoulderP).
    var maxContentNits: Float = 0
    var maxFrameAvgNits: Float = 0
    var padHdrMeta:     SIMD2<Float> = .zero
    var yuvMatrix:      simd_float3x3  // Precomputed YUV→RGB matrix (CPU-selected)
    var yuvOffset:      simd_float3    // Subtract before matrix multiply
}

// Build the YUV→RGB matrix and offset for the given format on the CPU.
// Shared by every decoder path that converts YUV frames to RGB.
// Eliminates all if/else branching in the fragment shader.
// Coefficients from ITU-R BT.709-6, BT.2020-2, BT.601-7.
func buildYUVMatrix(matrixType: UInt32, isFullRange: Bool, is10Bit: Bool) -> (simd_float3x3, simd_float3) {
    let yBlack:  Float = isFullRange ? 0.0        : (is10Bit ? 64.0  / 1023.0 : 16.0  / 255.0)
    let uvCenter: Float =               is10Bit ? 512.0 / 1023.0 : 128.0 / 255.0
    let yScale:  Float = isFullRange ? 1.0        : (is10Bit ? 1023.0 / 876.0  : 255.0 / 219.0)

    let offset = simd_float3(yBlack, uvCenter, uvCenter)

    let m: simd_float3x3
    switch matrixType {
    case 1: // BT.2020
        if isFullRange {
            m = simd_float3x3(columns: (
                simd_float3( 1.0,      1.0,      1.0     ),
                simd_float3( 0.0,     -0.164553, 1.8814  ),
                simd_float3( 1.4746,  -0.571353, 0.0     )
            ))
        } else {
            let s = yScale
            m = simd_float3x3(columns: (
                simd_float3( s,        s,        s       ),
                simd_float3( 0.0,     -0.18732610 * s, 2.14177232 * s ),
                simd_float3( 1.67867411 * s, -0.65042432 * s, 0.0 )
            ))
        }
    case 2: // BT.601 / SMPTE-C
        if isFullRange {
            m = simd_float3x3(columns: (
                simd_float3( 1.0,      1.0,      1.0     ),
                simd_float3( 0.0,     -0.344136, 1.77200 ),
                simd_float3( 1.40200, -0.714136, 0.0     )
            ))
        } else {
            let s = yScale
            m = simd_float3x3(columns: (
                simd_float3( s,        s,        s       ),
                simd_float3( 0.0,     -0.391762 * s, 2.017232 * s ),
                simd_float3( 1.596027 * s, -0.812968 * s, 0.0 )
            ))
        }
    default: // BT.709
        if isFullRange {
            m = simd_float3x3(columns: (
                simd_float3( 1.0,      1.0,      1.0     ),
                simd_float3( 0.0,     -0.187324, 1.8556  ),
                simd_float3( 1.5748,  -0.468124, 0.0     )
            ))
        } else {
            let s = yScale
            m = simd_float3x3(columns: (
                simd_float3( s,        s,        s       ),
                simd_float3( 0.0,     -0.21324861 * s, 2.11240179 * s ),
                simd_float3( 1.79274107 * s, -0.53290933 * s, 0.0 )
            ))
        }
    }
    return (m, offset)
}

// Must match FullHDRParams in Shaders.metal exactly.
private struct ShaderFullHDRParams {
    var boost:       Float
    var contrast:    Float
    var saturation:  Float
    var brightness:  Float
    var pqExposure:  Float
    var mode:        Int32
    var hdrGradeFlags: UInt32
    var sdrBrightness: Float
    var sdrWhiteNits: Float
    var outputGamut: UInt32
}

/// Buffer 0 for TestFlight SDR fragments (`copyFragmentShaderHDR_EDR` / `_HEVC_EDR`) — matches `LegacySDRFrameParams` in Shaders.metal.
private struct LegacySDRFrameParams {
    var presetIndex: UInt32 = 0
    var isPQ: UInt32
    var isBT2020Matrix: UInt32
    var isBT2020Primaries: UInt32
}

/// Buffer 1 for legacy SDR fragments — matches `LegacySDRFullParams` in Shaders.metal (no pqExposure).
private struct LegacySDRFullParams {
    var boost: Float
    var contrast: Float
    var saturation: Float
    var brightness: Float
    var mode: Int32
}

let kCVImageBufferYCbCrMatrix_ITU_R_2020 = "ITU_R_2020" as CFString
let kCVImageBufferColorPrimaries_ITU_R_2020 = "ITU_R_2020" as CFString
let kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ = "SMPTE_ST_2084_PQ" as CFString

let kCVImageBufferColorPrimaries_ITU_R_709_2 = "ITU_R_709_2" as CFString
let kCVImageBufferYCbCrMatrix_ITU_R_709_2 = "ITU_R_709_2" as CFString

// MARK: - VideoDecoderRenderer

@objc
class DrawableVideoDecoder: NSObject, AnyVideoDecoderRenderer {
    // MARK: - Properties

    private var callbacks: ConnectionCallbacks
    private var streamAspectRatio: Float

    let callbackToRender: @MainActor (TextureResource.DrawableQueue, TextureResource.DrawableQueue?, (Int, Int)?) -> Void
    private var hdrSettingsProvider: (() -> HDRParams)? = nil

    /// Format and frame info
    private var videoFormat: Int32 = 0
    private var frameRate: Int32 = 0
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0

    private var metalFormat: MTLPixelFormat
    private var decodingFormat: OSType

    /// If true, we'll do pacing logic in displayLink
    private var framePacing: Bool = false

    /// Store parameter set data for H.264 / HEVC
    private var parameterSetBuffers: [[UInt8]] = []

    /// HDR metadata
    private var masteringDisplayColorVolume: Data?
    private var contentLightLevelInfo: Data?

    /// Cached stats summary; the format description lives on the decode side.
    private let colorDescriptionLock = NSLock()
    private var cachedColorDescription: String?

    /// Video format description, used when creating sample buffers
    private var formatDesc: CMVideoFormatDescription?

    /// Display link for pacing decode submissions
    private var displayLink: CADisplayLink?

    private let texture: TextureResource
    private var outTexture: MTLTexture?
    private var region = MTLRegionMake2D(0, 0, 1000, 1000)
    var textureCache: CVMetalTextureCache?
    var drawableQueue: TextureResource.DrawableQueue?

    var session: VTDecompressionSession?
    /// Format the current session was created for. Used to skip the blocking
    /// teardown when a keyframe repeats the same format.
    private var appliedFormatDesc: CMVideoFormatDescription?
    private var appliedFormatIsHDR = false
    /// Color description parsed from the stream's parameter sets. A decoded
    /// buffer does not always keep its own color attachments (a conversion to
    /// BGRA drops them), so the per-frame classification falls back to these
    /// instead of assuming BT.709 SDR.
    private var streamPrimariesType: UInt32 = 0
    private var streamMatrixType: UInt32 = 0
    /// Last HDR/SDR classification reported for the stream, so a host toggle
    /// is logged once instead of on every keyframe.
    private var lastFormatIsHDR: Bool?
    /// `videoContentShown` means "the first picture arrived", not "a keyframe
    /// arrived"; it used to fire on every IDR.
    private var reportedContentShown = false
    var decoderCallback: VTDecompressionOutputCallbackRecord

    // Limits GPU command buffer depth to 3 in-flight frames.
    // Prevents memory pressure and watchdog kills when the decoder runs faster than the GPU.
    private let inflightSemaphore = DispatchSemaphore(value: 3)

    /// Upper bound on frames submitted per display-link tick, so a backlog
    /// cannot monopolise the main thread for a whole frame interval.
    private static let maxFramesPerTick = 8

    /// Width of the drawable queue currently in use. The multiplier alone is
    /// not enough: a failed rebuild leaves the old queue in place, and then
    /// the renderer would keep painting a double-width drawable.
    private var queueOutputWidth = 0

    lazy var mtlDevice: MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError()
        }
        return device
    }()

    private lazy var commandQueue: MTLCommandQueue? = mtlDevice.makeCommandQueue()

    private var imagePlaneVertexBuffer: MTLBuffer?

    private var hdrEnabled: Bool
    private var hdrMetadata: SS_HDR_METADATA = SS_HDR_METADATA()

    private var enhancementsProvider: (() -> (Float, Float, Float))? = nil

    // Real-time 2D→3D.
    // While active the drawable is double width and each eye is rendered into
    // one half; the screen keeps using the SBS material.
    private let realtime3DSettingsProvider: (() -> LSRealtime3DSettings)?
    private var realtime3DConverter: Realtime3DConverter?
    private var realtime3DConverterAttempted = false
    private var stereoOutputMultiplier = 1
    /// When on, the video drawable carries a mipmap chain and the frame path
    /// regenerates it, so minified motion is filtered instead of shimmering.
    private var mipmappedVideoOutput = false
    private var depthPreviewPipeline: MTLRenderPipelineState?
    private var lastPresentationTimeSeconds: Double?
    private let renderFrameLock = NSLock()
    private let hdrReportLock = NSLock()
    private var hdrReport = ""
    private let whiteSampleLock = NSLock()
    private var whiteSampleRequested = false
    /// Called on the main queue with the host SDR white point measured from a
    /// full-screen SDR white frame.
    var onHDRWhiteSample: ((Float) -> Void)?
    /// GPU submission is forbidden once the app is in the background. The
    /// decoder keeps its VideoToolbox session but drops frames until resumed.
    private let renderStateLock = NSLock()
    private var renderingPaused = false

    /// Flat HDR validation target: a CAMetalLayer with an EDR colorspace,
    /// bypassing RealityKit's texture/material clamp.
    private let flatLayerLock = NSLock()
    private var flatHDRLayer: CAMetalLayer?
    private var flatHDRLayerEnabled = false
    private var flatDrawableFailureLogged = false
    /// BGR10A2Unorm; the visionOS SDK does not tag this case, so use its raw value.
    private static let flatPQPixelFormat: MTLPixelFormat =
        MTLPixelFormat(rawValue: 94) ?? .bgra10_xr

    private var copyPipelineState: MTLRenderPipelineState?
    private var copyPipelineFormat: MTLPixelFormat?
    private var copyPipelineStateYUV: MTLRenderPipelineState?
    private var copyPipelineStateFlatPQ: MTLRenderPipelineState?
    private var copyPipelineStateFlatPQYUV: MTLRenderPipelineState?
    private var lastCopyFragment: String?

    // ChromaHalo: downsampled drawable queue for the edge bloom layer
    var chromaHaloQueue: TextureResource.DrawableQueue?
    private var chromaHaloRimPipelineState: MTLRenderPipelineState?
    private var chromaHaloBlurHPipelineState: MTLRenderPipelineState?
    private var chromaHaloBlurVPipelineState: MTLRenderPipelineState?
    /// Ping-pong scratch: rim → A, horizontal blur → B, vertical blur (+ temporal) → drawable.
    private var chromaHaloScratchA: MTLTexture?
    private var chromaHaloScratchB: MTLTexture?
    private var prevChromaHaloTexture: MTLTexture?

    private var firstFrameEmitted = false

    private var lastPresentTime: CFAbsoluteTime = 0
    private var lastStallRecoveryTime: CFAbsoluteTime = 0
    private var stallWatchdogSource: DispatchSourceTimer?
    private let stallPresentThreshold: CFAbsoluteTime = 0.45
    private let stallRecoveryCooldown: CFAbsoluteTime = 2.0
    private let presentTimeLock = NSLock()

    // ChromaHalo intensity for edge bloom (0.0 = off, 1.0 = normal)
    var chromaHaloIntensity: Float = 0.0
    // ChromaHalo scale (how much larger than video the halo mesh is)
    /// Geometric margin for bloom vs display — keep equal to `_CurvedDisplayStreamView.chromosphereDiameterScale`.
    var chromaHaloScale: Float = 1.55
    /// Reactive 2: wider rim + stronger emission in `chromaHaloRimFragment`.
    var chromaHaloCoronaMode: UInt32 = 0

    // MARK: - Initialization

    init(
        texture: TextureResource,
        callbacks: ConnectionCallbacks,
        aspectRatio: Float,
        useFramePacing: Bool,
        enableHDR: Bool = false,
        hdrSettingsProvider: (() -> HDRParams)? = nil,
        enhancementsProvider: (() -> (Float, Float, Float))? = nil,
        realtime3DSettingsProvider: (() -> LSRealtime3DSettings)? = nil,
        mipmappedOutput: Bool = false,
        callbackToRender: @MainActor @escaping (TextureResource.DrawableQueue, TextureResource.DrawableQueue?, (Int, Int)?) -> Void
    ) {
        metalFormat = .rgba16Float

        // The decode target never depends on the client switch: the pipeline
        // always presents with HDR capability, and only the request sent to
        // the host changes. A fixed float target also keeps SDR streams on the
        // same path no matter what the switch is set to — the BGRA fallback
        // produced a visibly different picture for the same SDR stream.
        decodingFormat = kCVPixelFormatType_64RGBAHalf

        self.texture = texture
        self.callbacks = callbacks
        streamAspectRatio = aspectRatio
        framePacing = useFramePacing
        hdrEnabled = enableHDR
        self.hdrSettingsProvider = hdrSettingsProvider
        self.enhancementsProvider = enhancementsProvider
        self.realtime3DSettingsProvider = realtime3DSettingsProvider
        self.mipmappedVideoOutput = mipmappedOutput
        self.callbackToRender = callbackToRender

        decoderCallback = VTDecompressionOutputCallbackRecord()
        decoderCallback.decompressionOutputCallback = { decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            let mySelf = Unmanaged<DrawableVideoDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
            mySelf.decompressionOutputCallback(
                decompressionOutputRefCon: decompressionOutputRefCon,
                sourceFrameRefCon: sourceFrameRefCon,
                status: status,
                infoFlags: infoFlags,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                presentationDuration: presentationDuration
            )
        }

        super.init()
        decoderCallback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()
    }

    /// Pauses or resumes Metal submission without tearing down the decoder.
    /// Call with true when the app/window leaves the foreground; VideoToolbox
    /// may keep delivering frames, which are dropped instead of submitted.
    func setRenderingPaused(_ paused: Bool) {
        renderStateLock.lock()
        renderingPaused = paused
        renderStateLock.unlock()
    }

    private var isRenderingPaused: Bool {
        renderStateLock.lock()
        defer { renderStateLock.unlock() }
        return renderingPaused
    }

    /// Switches the output between the RealityKit drawable queue and a flat
    /// CAMetalLayer used to validate true EDR output.
    func setFlatHDRLayer(_ layer: CAMetalLayer?, enabled: Bool) {
        flatLayerLock.lock()
        flatHDRLayer = layer
        flatHDRLayerEnabled = enabled
        flatLayerLock.unlock()

        guard let layer else { return }
        layer.device = mtlDevice
        layer.pixelFormat = Self.flatPQPixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.contentsGravity = .resizeAspect
        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        layer.wantsExtendedDynamicRangeContent = true
        layer.toneMapMode = .never
        if #available(visionOS 26.0, *) {
            layer.preferredDynamicRange = .high
            layer.contentsHeadroom = 8.0
        }
        if videoWidth > 0, videoHeight > 0 {
            layer.drawableSize = CGSize(width: videoWidth, height: videoHeight)
        }
        NSLog(
            "[DrawableVideoDecoder] Flat HDR %@ (drawable %.0fx%.0f, colorspace=%@, headroom=%.1f)",
            enabled ? "enabled" : "disabled",
            layer.drawableSize.width,
            layer.drawableSize.height,
            String(describing: layer.colorspace),
            layer.contentsHeadroom
        )
    }

    private func flatLayerSnapshot() -> (layer: CAMetalLayer, enabled: Bool)? {
        flatLayerLock.lock()
        defer { flatLayerLock.unlock() }
        guard let layer = flatHDRLayer else { return nil }
        return (layer, flatHDRLayerEnabled)
    }

    func decompressionOutputCallback(
        decompressionOutputRefCon _: UnsafeMutableRawPointer?,
        sourceFrameRefCon _: UnsafeMutableRawPointer?,
        status _: OSStatus,
        infoFlags _: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        presentationDuration: CMTime?
    ) {
        guard let imageBuffer = imageBuffer else { return }
        // Never submit GPU work from the background; drop the frame.
        guard !isRenderingPaused else { return }

        // Back-pressure: drop the frame silently if 3 frames are already queued on the GPU.
        if inflightSemaphore.wait(timeout: .now()) != .success { return }

        autoreleasepool {
            renderFrame(
                imageBuffer: imageBuffer,
                presentationTime: presentationTimeStamp,
                duration: presentationDuration
            )
        }
    }

    private func renderFrame(
        imageBuffer: CVImageBuffer,
        presentationTime: CMTime,
        duration: CMTime?
    ) {
        // VideoToolbox may deliver callbacks concurrently; the converter and its
        // texture cache are queue-confined, so serialize frame conversion.
        renderFrameLock.lock()
        defer { renderFrameLock.unlock() }
        if isRenderingPaused {
            inflightSemaphore.signal()
            return
        }

        let realtimeSettings = realtime3DSettingsProvider?() ?? .disabled
        let wantStereo = realtimeSettings.isEnabled && stereoOutputMultiplier == 2
        if wantStereo, !realtime3DConverterAttempted {
            realtime3DConverterAttempted = true
            realtime3DConverter = Realtime3DConverter()
        }
        let converter = wantStereo ? realtime3DConverter : nil

        // Convert while the drawable is not needed; the eye copy below is
        // submitted on the converter's queue so it runs after synthesis.
        var stereoConversion: Realtime3DConverter.Conversion?
        if let converter {
            let nowSeconds = CMTimeGetSeconds(presentationTime)
            var isStill = false
            if let previous = lastPresentationTimeSeconds, nowSeconds.isFinite {
                let delta = nowSeconds - previous
                if delta == 0 {
                    isStill = true
                } else if delta < 0 || delta > 1.0 {
                    converter.reset()
                }
            }
            if nowSeconds.isFinite {
                lastPresentationTimeSeconds = nowSeconds
            }
            stereoConversion = converter.convert(
                source: imageBuffer,
                settings: realtimeSettings,
                presentationTime: presentationTime,
                duration: duration ?? .invalid,
                isStill: isStill
            )
        }

        let frameQueue = converter?.commandQueue ?? commandQueue
        guard
            let commandBuffer = frameQueue?.makeCommandBuffer(),
            let textureCache  = textureCache
        else {
            inflightSemaphore.signal()
            return
        }

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }

        let pf         = CVPixelBufferGetPixelFormatType(imageBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(imageBuffer)

        // --- PQ detection (ST.2084) ---
        // 1) Prefer attachment on the decoded pixel buffer.
        // 2) Else use transfer from CMVideoFormatDescription (must match AV1 sequence header — see AV1Parser tcMap).
        //    VideoToolbox often omits kCVImageBufferTransferFunctionKey on the buffer even when the format desc is correct.
        var isPQ = false
        if let tfVal = CVBufferGetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, nil)?.takeUnretainedValue(),
           CFGetTypeID(tfVal) == CFStringGetTypeID() {
            isPQ = CFEqual(tfVal as! CFString, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        }
        if !isPQ, let fd = formatDesc,
           let tfAny = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) {
            if CFGetTypeID(tfAny) == CFStringGetTypeID() {
                isPQ = CFEqual(tfAny as! CFString, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
            }
        }

        // --- Primaries Detection ---
        var primariesType: UInt32 = 0  // 0=709, 1=2020, 2=SMPTE-C
        if let primVal = CVBufferGetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, nil)?.takeUnretainedValue(),
           CFGetTypeID(primVal) == CFStringGetTypeID() {
            let prim = primVal as! CFString
            if      CFEqual(prim, kCVImageBufferColorPrimaries_ITU_R_2020)  { primariesType = 1 }
            else if CFEqual(prim, "SMPTE_C" as CFString)                    { primariesType = 2 }
            // else stays 0 (BT.709)
        } else if streamPrimariesType != 0 {
            // The buffer carries no attachment of its own (a BGRA conversion
            // drops them). Use what the stream's parameter sets declared, so
            // the render path still follows the stream.
            primariesType = streamPrimariesType
        } else {
            // PQ implies BT.2020; a 10-bit SDR 709 stream stays 709 so it is
            // not mistaken for an extended HDR signal.
            primariesType = isPQ ? 1 : 0
        }

        // --- Matrix Detection ---
        var matrixType: UInt32 = 0  // 0=709, 1=2020, 2=601
        if let mtxVal = CVBufferGetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue(),
           CFGetTypeID(mtxVal) == CFStringGetTypeID() {
            let mtx = mtxVal as! CFString
            if      CFEqual(mtx, kCVImageBufferYCbCrMatrix_ITU_R_2020)  { matrixType = 1 }
            else if CFEqual(mtx, "ITU_R_601_4" as CFString)             { matrixType = 2 }
            // else stays 0 (BT.709)
        } else if streamMatrixType != 0 {
            matrixType = streamMatrixType
        } else {
            matrixType = isPQ ? 1 : 0
        }

        let is10Bit    = pixelFormatIs10Bit(pf)    ? UInt32(1) : 0
        let isFullRange = pixelFormatIsFullRange(pf) ? UInt32(1) : 0
        // The render path follows the stream's own signaling. The client
        // toggle only decides what this app asks the host for; it must not
        // reclassify a stream that already arrived as HDR. Letting it do so
        // turned the same PQ/2020 stream into an SDR decode whenever HDR was
        // switched off, which crushes every shadow to black.
        let streamIsHDR = isPQ || (is10Bit == 1 && primariesType == 1)

        let hdrKind = !streamIsHDR ? "SDR" : (isPQ ? "PQ" : "extended/non-PQ")
        let primariesName = primariesType == 1 ? "BT.2020" : (primariesType == 2 ? "SMPTE-C" : "BT.709")
        let bitsName = is10Bit == 1 ? "10-bit" : "8-bit"
        let rangeName = isFullRange == 1 ? "full" : "limited"
        let transferName: String = {
            guard let fd = formatDesc,
                  let tfAny = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
            else { return "tf=?" }
            if CFGetTypeID(tfAny) == CFStringGetTypeID() {
                return (tfAny as! CFString) as String
            }
            return "tf=?"
        }()
        let report = "HDR: \(hdrKind) · \(primariesName) · \(bitsName) · \(rangeName) · \(transferName)"
        hdrReportLock.lock()
        let reportChanged = hdrReport != report
        hdrReport = report
        hdrReportLock.unlock()
        if reportChanged {
            NSLog("[DrawableVideoDecoder] %@", report)
        }

        if streamIsHDR { updateHDRMetadata() }

        // One-shot white-point calibration: sample the next PQ frame while the
        // host shows a full-screen SDR white image.
        if isPQ, is10Bit == 1 {
            sampleHDRWhiteIfRequested(imageBuffer: imageBuffer, fullRange: isFullRange == 1)
        }

        // --- Texture Format Selection ---
        // When HDR is off, 10-bit SDR stays on r16/rg16 (or packed YCbCr), not r8/rg8.
        var isBiPlanar  = false
        var yFormat:    MTLPixelFormat = .invalid
        var cbcrFormat: MTLPixelFormat = .invalid

        if planeCount >= 2 {
            let srcMetalFormats = CVMetalHelpers.getTextureTypesForFormat(pf)
            if srcMetalFormats.count > 0 { yFormat = srcMetalFormats[0] }
            if srcMetalFormats.count > 1 { cbcrFormat = srcMetalFormats[1] }
            isBiPlanar = (cbcrFormat != .invalid)

            if is10Bit == 1 {
                yFormat = .r16Unorm
                cbcrFormat = .rg16Unorm
                isBiPlanar = true
            }
        }

        if !firstFrameEmitted {
            let fmtStr = CVMetalHelpers.coreVideoPixelFormatToStr[pf] ?? "\(pf)"
            let tfDesc: String = {
                guard let fd = formatDesc,
                      let tfAny = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
                else { return "-" }
                if let s = tfAny as? String { return s }
                if CFGetTypeID(tfAny) == CFStringGetTypeID() { return (tfAny as! CFString) as String }
                return "-"
            }()
            let cllLog = streamIsHDR ? " maxCLL=\(hdrMetadata.maxContentLightLevel) maxFALL=\(hdrMetadata.maxFrameAverageLightLevel)" : ""
            print("[DrawableVideoDecoder] PF=\(fmtStr), planes=\(planeCount), hdr=\(streamIsHDR), isPQ=\(isPQ), tfDesc=\(tfDesc), fullRange=\(isFullRange==1), 10bit=\(is10Bit==1), matrix=\(matrixType), primaries=\(primariesType)\(cllLog)")
        }

        let flatTarget = flatLayerSnapshot()
        let isFlatTarget = flatTarget?.enabled == true
        let targetTexture: MTLTexture
        var metalDrawable: CAMetalDrawable?
        var presentReality: (() -> Void)?

        if isFlatTarget, let layer = flatTarget?.layer {
            guard let drawable = layer.nextDrawable() else {
                if !flatDrawableFailureLogged {
                    flatDrawableFailureLogged = true
                    NSLog(
                        "[DrawableVideoDecoder] Flat HDR: nextDrawable nil (drawable %.0fx%.0f)",
                        layer.drawableSize.width,
                        layer.drawableSize.height
                    )
                }
                commandBuffer.commit()
                return
            }
            flatDrawableFailureLogged = false
            targetTexture = drawable.texture
            metalDrawable = drawable
        } else {
            guard let drawable = try? drawableQueue?.nextDrawable() else {
                commandBuffer.commit()
                return
            }
            targetTexture = drawable.texture
            presentReality = { drawable.present() }
        }

        let outputWidth = targetTexture.width
        let outputHeight = targetTexture.height
        let targetFormat = isFlatTarget
            ? (flatTarget?.layer.pixelFormat ?? metalFormat)
            : metalFormat
        let isFlatPQ = isFlatTarget && targetFormat == Self.flatPQPixelFormat
        // The drawable is double width whenever 3D is enabled, even if this
        // frame could not be converted; keeping per-eye halves in that case
        // shows a mono picture instead of a stretched side-by-side one.
        // Decide from the requested mode, not from the drawable size: a stale
        // double-width queue must not make a mono frame render twice.
        let outputIsStereoWidth = stereoOutputMultiplier == 2
            && outputWidth >= CVPixelBufferGetWidth(imageBuffer) * 2
        let eyeWidth = outputIsStereoWidth ? outputWidth / 2 : outputWidth

        let depthPreviewTexture: MTLTexture? = {
            guard realtimeSettings.isEnabled, realtimeSettings.showsDepth,
                  let converter = realtime3DConverter else { return nil }
            let textures = converter.debugTextures()
            return textures.normalized ?? textures.working
        }()

        // One EDR-capable fragment path handles both PQ HDR and SDR: the
        // shader linearises SDR and gamut-maps it to the float drawable.
        let fragment = isBiPlanar
            ? "copyFragmentShaderHDR_HDRUnified"
            : "copyFragmentShaderHEVC_HDRUnified"

        if isBiPlanar {
            if isFlatPQ {
                if copyPipelineStateFlatPQYUV == nil || lastCopyFragment != fragment {
                    copyPipelineStateFlatPQYUV = buildCopyPipeline(fragment: fragment, format: targetFormat)
                    lastCopyFragment = fragment
                    guard copyPipelineStateFlatPQYUV != nil else {
                        print("DrawableVideoDecoder: Failed to build flat PQ YUV pipeline")
                        commandBuffer.commit()
                        return
                    }
                }
            } else if copyPipelineStateYUV == nil || lastCopyFragment != fragment {
                copyPipelineStateYUV = buildCopyPipeline(fragment: fragment)
                lastCopyFragment = fragment
                guard copyPipelineStateYUV != nil else {
                    print("DrawableVideoDecoder: Failed to build YUV pipeline")
                    commandBuffer.commit()
                    return
                }
            }
        } else {
            if isFlatPQ {
                if copyPipelineStateFlatPQ == nil || lastCopyFragment != fragment {
                    copyPipelineStateFlatPQ = buildCopyPipeline(fragment: fragment, format: targetFormat)
                    lastCopyFragment = fragment
                    guard copyPipelineStateFlatPQ != nil else {
                        print("DrawableVideoDecoder: Failed to build flat PQ single-plane pipeline")
                        commandBuffer.commit()
                        return
                    }
                }
            } else if copyPipelineState == nil || lastCopyFragment != fragment {
                copyPipelineState = buildCopyPipeline(fragment: fragment)
                lastCopyFragment = fragment
                guard copyPipelineState != nil else {
                    print("DrawableVideoDecoder: Failed to build single-plane pipeline")
                    commandBuffer.commit()
                    return
                }
            }
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture    = targetTexture
        renderPassDescriptor.colorAttachments[0].loadAction  = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        let pipeline: MTLRenderPipelineState
        if isFlatPQ {
            pipeline = isBiPlanar ? copyPipelineStateFlatPQYUV! : copyPipelineStateFlatPQ!
        } else {
            pipeline = isBiPlanar ? copyPipelineStateYUV! : copyPipelineState!
        }
        renderEncoder.setRenderPipelineState(pipeline)

        // Buffer 0: ShaderHDRParams — frame signal description.
        // The stream's actual format, not the client toggle, decides whether
        // the HDR trims apply; SDR always uses neutral trims and 1.0 SDR white.
        let neutralParams = HDRParams(
            boost: 1.0, contrast: 1.0, saturation: 1.0, brightness: 0.0,
            pqExposure: 1.0, mode: 0, sdrBrightness: 1.0, edrHeadroom: 2.0,
            sdrWhiteNits: 203.0, outputGamut: 0
        )
        let userParams: HDRParams = streamIsHDR
            ? (hdrSettingsProvider?() ?? neutralParams)
            : neutralParams

        // visionOS has no public numeric EDR headroom; default to 2.0 and let
        // the user trim within it.
        let edrHeadroom: Float = {
            guard streamIsHDR, let params = hdrSettingsProvider?(), params.edrHeadroom > 0 else {
                return 2.0
            }
            return params.edrHeadroom
        }()

        let is10BitBool = is10Bit == 1
        let isFullRangeBool = isFullRange == 1
        let (yuvMatrix, yuvOffset) = buildYUVMatrix(matrixType: matrixType, isFullRange: isFullRangeBool, is10Bit: is10BitBool)
        let extendedScene: UInt32 = (streamIsHDR && !isPQ) ? 1 : 0
        var shaderHDR = ShaderHDRParams(
            isPQ:              isPQ ? 1 : 0,
            primariesType:     primariesType,
            extendedScene:     extendedScene,
            reserved0:         0,
            edrHeadroom:       edrHeadroom,
            pad:               0,
            alignPad:          .zero,
            maxContentNits:    streamIsHDR ? Float(hdrMetadata.maxContentLightLevel) : 0,
            maxFrameAvgNits:   streamIsHDR ? Float(hdrMetadata.maxFrameAverageLightLevel) : 0,
            padHdrMeta:        .zero,
            yuvMatrix:         yuvMatrix,
            yuvOffset:         yuvOffset
        )
        renderEncoder.setFragmentBytes(&shaderHDR, length: MemoryLayout<ShaderHDRParams>.size, index: 0)

        var fullParams = ShaderFullHDRParams(
            boost:      userParams.boost,
            contrast:   userParams.contrast,
            saturation: userParams.saturation,
            brightness: userParams.brightness,
            pqExposure: userParams.pqExposure,
            mode:       userParams.mode,
            hdrGradeFlags: userParams.hdrGradeFlags,
            sdrBrightness: streamIsHDR ? userParams.sdrBrightness : 1.0,
            sdrWhiteNits: max(userParams.sdrWhiteNits, 80.0),
            outputGamut: isFlatTarget ? 2 : userParams.outputGamut
        )
        renderEncoder.setFragmentBytes(&fullParams, length: MemoryLayout<ShaderFullHDRParams>.size, index: 1)

        // Buffer 2: ColorEnhancementUniforms — warmth / per-renderer adjustments
        let satConWarm = enhancementsProvider?() ?? (1.0, 1.0, 0.0)
        var enh = ColorEnhancementUniforms(saturation: satConWarm.0, contrast: satConWarm.1, warmth: satConWarm.2, padding1: 0)
        renderEncoder.setFragmentBytes(&enh, length: MemoryLayout<ColorEnhancementUniforms>.size, index: 2)

        func encodeEye(_ buffer: CVImageBuffer, originX: Int, width: Int) {
            if isBiPlanar {
                let w0 = CVPixelBufferGetWidthOfPlane(buffer, 0)
                let h0 = CVPixelBufferGetHeightOfPlane(buffer, 0)
                let w1 = CVPixelBufferGetWidthOfPlane(buffer, 1)
                let h1 = CVPixelBufferGetHeightOfPlane(buffer, 1)

                var yRef: CVMetalTexture?
                var cbcrRef: CVMetalTexture?
                let r0 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, yFormat, w0, h0, 0, &yRef)
                let r1 = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, cbcrFormat, w1, h1, 1, &cbcrRef)
                guard r0 == 0, r1 == 0,
                      let yTex = yRef.flatMap(CVMetalTextureGetTexture),
                      let uvTex = cbcrRef.flatMap(CVMetalTextureGetTexture) else { return }
                renderEncoder.setFragmentTexture(yTex, index: 0)
                renderEncoder.setFragmentTexture(uvTex, index: 1)
            } else {
                var imgRef: CVMetalTexture?
                let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
                let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
                let bufferFormat = CVPixelBufferGetPixelFormatType(buffer)
                let formats = CVMetalHelpers.getTextureTypesForFormat(bufferFormat)
                guard let srcFmt = formats.first, srcFmt != .invalid else { return }
                let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, srcFmt, w, h, 0, &imgRef)
                guard result == 0, let srcTex = imgRef.flatMap(CVMetalTextureGetTexture) else { return }
                renderEncoder.setFragmentTexture(srcTex, index: 0)
            }
            renderEncoder.setViewport(MTLViewport(
                originX: Double(originX),
                originY: 0,
                width: Double(width),
                height: Double(outputHeight),
                znear: 0,
                zfar: 1
            ))
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if let depthPreviewTexture {
            if depthPreviewPipeline == nil {
                depthPreviewPipeline = buildCopyPipeline(fragment: "realtimeDepthPreviewFragment")
            }
            if let pipeline = depthPreviewPipeline {
                renderEncoder.setRenderPipelineState(pipeline)
                renderEncoder.setFragmentTexture(depthPreviewTexture, index: 0)
                var depthColorMode: UInt32 = realtimeSettings.colorDepth ? 1 : 0
                renderEncoder.setFragmentBytes(
                    &depthColorMode,
                    length: MemoryLayout<UInt32>.size,
                    index: 0
                )
                for originX in stride(from: 0, to: outputWidth, by: max(eyeWidth, 1)) {
                    renderEncoder.setViewport(MTLViewport(
                        originX: Double(originX),
                        originY: 0,
                        width: Double(eyeWidth),
                        height: Double(outputHeight),
                        znear: 0,
                        zfar: 1
                    ))
                    renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
        } else if let conversion = stereoConversion {
            encodeEye(conversion.left, originX: 0, width: eyeWidth)
            encodeEye(conversion.right, originX: eyeWidth, width: eyeWidth)
        } else if outputIsStereoWidth {
            // A failed conversion keeps the frame visible as mono in both eyes.
            encodeEye(imageBuffer, originX: 0, width: eyeWidth)
            encodeEye(imageBuffer, originX: eyeWidth, width: eyeWidth)
        } else {
            encodeEye(imageBuffer, originX: 0, width: eyeWidth)
        }
        renderEncoder.endEncoding()

        // Mipmap generation — used by both ChromaHalo bloom and ambient zone sampling
        if targetTexture.mipmapLevelCount > 1,
           let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.generateMipmaps(for: targetTexture)
            blitEncoder.endEncoding()
        }

        // ChromaHalo: rim (mip 0) → two rounds separable blur (Ambilight diffusion) → temporal on final V-pass.
        if !isFlatTarget,
           chromaHaloIntensity > 0.0,
           let haloQueue = chromaHaloQueue,
           let haloDrawable = try? haloQueue.nextDrawable() {

            let sampleMip = min(chromaHaloSourceMipLevel, targetTexture.mipmapLevelCount - 1)

            if chromaHaloRimPipelineState == nil {
                chromaHaloRimPipelineState = buildCopyPipeline(fragment: "chromaHaloRimFragment")
            }
            if chromaHaloBlurHPipelineState == nil {
                chromaHaloBlurHPipelineState = buildCopyPipeline(fragment: "chromaHaloBlurHFragment")
            }
            if chromaHaloBlurVPipelineState == nil {
                chromaHaloBlurVPipelineState = buildCopyPipeline(fragment: "chromaHaloBlurVFragment")
            }

            var didAllocatePrevChroma = false
            if prevChromaHaloTexture == nil
                || prevChromaHaloTexture!.width != haloDrawable.texture.width
                || prevChromaHaloTexture!.height != haloDrawable.texture.height {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: haloDrawable.texture.pixelFormat,
                    width: haloDrawable.texture.width,
                    height: haloDrawable.texture.height,
                    mipmapped: false)
                desc.usage = [.shaderRead, .renderTarget]
                prevChromaHaloTexture = mtlDevice.makeTexture(descriptor: desc)
                didAllocatePrevChroma = prevChromaHaloTexture != nil
            }

            if didAllocatePrevChroma, let freshPrev = prevChromaHaloTexture {
                let clearDesc = MTLRenderPassDescriptor()
                clearDesc.colorAttachments[0].texture = freshPrev
                clearDesc.colorAttachments[0].loadAction = .clear
                clearDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                clearDesc.colorAttachments[0].storeAction = .store
                if let clearEnc = commandBuffer.makeRenderCommandEncoder(descriptor: clearDesc) {
                    clearEnc.endEncoding()
                }
            }

            ensureChromaHaloBlurScratchMatches(haloDrawable.texture)

            if let mipView = targetTexture.makeTextureView(
                pixelFormat: targetTexture.pixelFormat,
                textureType: .type2D,
                levels: sampleMip..<(sampleMip + 1),
                slices: 0..<1),
               let rimPS = chromaHaloRimPipelineState,
               let blurHPS = chromaHaloBlurHPipelineState,
               let blurVPS = chromaHaloBlurVPipelineState,
               let scratchA = chromaHaloScratchA,
               let scratchB = chromaHaloScratchB,
               let prevTex = prevChromaHaloTexture {

                let w = Float(scratchA.width)
                let h = Float(scratchA.height)
                var texelUV = simd_float2(
                    chromaHaloAmbilightBlurSpread / max(w, 1),
                    chromaHaloAmbilightBlurSpread / max(h, 1))

                // Pass 1 — rim → scratch A
                let passRim = MTLRenderPassDescriptor()
                passRim.colorAttachments[0].texture = scratchA
                passRim.colorAttachments[0].loadAction = .clear
                passRim.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                passRim.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passRim) {
                    enc.setRenderPipelineState(rimPS)
                    enc.setFragmentTexture(mipView, index: 0)
                    var scale = chromaHaloScale
                    var intensity = chromaHaloIntensity
                    var coronaMode = chromaHaloCoronaMode
                    enc.setFragmentBytes(&scale, length: MemoryLayout<Float>.size, index: 1)
                    enc.setFragmentBytes(&intensity, length: MemoryLayout<Float>.size, index: 2)
                    enc.setFragmentBytes(&coronaMode, length: MemoryLayout<UInt32>.size, index: 3)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }

                // Pass 2 — horizontal blur A → B
                let passH = MTLRenderPassDescriptor()
                passH.colorAttachments[0].texture = scratchB
                passH.colorAttachments[0].loadAction = .clear
                passH.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                passH.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passH) {
                    enc.setRenderPipelineState(blurHPS)
                    enc.setFragmentTexture(scratchA, index: 0)
                    enc.setFragmentBytes(&texelUV, length: MemoryLayout<simd_float2>.size, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }

                // Pass 3 — first vertical blur → scratch A (Ambilight diffusion pass 2/4)
                let passV1 = MTLRenderPassDescriptor()
                passV1.colorAttachments[0].texture = scratchA
                passV1.colorAttachments[0].loadAction = .clear
                passV1.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                passV1.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passV1) {
                    enc.setRenderPipelineState(blurVPS)
                    enc.setFragmentTexture(scratchB, index: 0)
                    enc.setFragmentTexture(prevTex, index: 1)
                    enc.setFragmentBytes(&texelUV, length: MemoryLayout<simd_float2>.size, index: 0)
                    var vTemporalOff: UInt32 = 0
                    enc.setFragmentBytes(&vTemporalOff, length: MemoryLayout<UInt32>.size, index: 1)
                    var mixPlaceholder: Float = 0
                    enc.setFragmentBytes(&mixPlaceholder, length: MemoryLayout<Float>.size, index: 2)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }

                // Pass 4 — horizontal blur scratch A → B
                let passH2 = MTLRenderPassDescriptor()
                passH2.colorAttachments[0].texture = scratchB
                passH2.colorAttachments[0].loadAction = .clear
                passH2.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                passH2.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passH2) {
                    enc.setRenderPipelineState(blurHPS)
                    enc.setFragmentTexture(scratchA, index: 0)
                    enc.setFragmentBytes(&texelUV, length: MemoryLayout<simd_float2>.size, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }

                // Pass 5 — vertical blur + temporal → halo drawable
                let passV2 = MTLRenderPassDescriptor()
                passV2.colorAttachments[0].texture = haloDrawable.texture
                passV2.colorAttachments[0].loadAction = .clear
                passV2.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                passV2.colorAttachments[0].storeAction = .store
                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passV2) {
                    enc.setRenderPipelineState(blurVPS)
                    enc.setFragmentTexture(scratchB, index: 0)
                    enc.setFragmentTexture(prevTex, index: 1)
                    enc.setFragmentBytes(&texelUV, length: MemoryLayout<simd_float2>.size, index: 0)
                    var vTemporalOn: UInt32 = 1
                    enc.setFragmentBytes(&vTemporalOn, length: MemoryLayout<UInt32>.size, index: 1)
                    var mix = chromaHaloTemporalFrameMix()
                    enc.setFragmentBytes(&mix, length: MemoryLayout<Float>.size, index: 2)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }

                if let blitEnc = commandBuffer.makeBlitCommandEncoder() {
                    blitEnc.copy(from: haloDrawable.texture, to: prevTex)
                    blitEnc.endEncoding()
                }
            }

            haloDrawable.present()
        }

        if let metalDrawable {
            commandBuffer.present(metalDrawable)
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            presentReality?()
            self?.noteFramePresented()
        }
        commandBuffer.commit()

        if !firstFrameEmitted {
            firstFrameEmitted = true
            DispatchQueue.main.async {
                self.callbacks.videoContentShown()
                print("DrawableVideoDecoder: First frame presented (PQ=\(isPQ), primaries=\(primariesType), matrix=\(matrixType), edrHeadroom=\(edrHeadroom))")
            }
        }
    }

    // MARK: - Pixel Format Helpers

    private func pixelFormatIs10Bit(_ pf: OSType) -> Bool {
        switch pf {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange:
            return true
        default:
            return false
        }
    }

    private func pixelFormatIsFullRange(_ pf: OSType) -> Bool {
        switch pf {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange:
            return true
        // Studio (limited) range is fixed by the OSType. Some streams incorrectly set FullRangeVideo on the
        // CMFormatDescription; trusting that here used full-range YUV offsets on limited buffers → lifted blacks
        // and the milky HDR desktop look (PQ path and extended path both start from the same decode).
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange:
            return false
        default:
            // Unknown layouts default to studio (limited) range.
            // Relying on CMFormatDescription FullRangeVideo has produced false positives for HDR streams
            // (washed desktop); only OSTypes in the explicit `true` branch above are treated as full range.
            return false
        }
    }

    /// Turns the video drawable's mipmap chain on or off while streaming.
    /// Rebuilding the queues rebinds them through the normal mailbox path.
    func setMipmappedOutput(_ enabled: Bool) {
        renderFrameLock.lock()
        defer { renderFrameLock.unlock() }
        guard mipmappedVideoOutput != enabled else { return }
        mipmappedVideoOutput = enabled
        runOnMainSync { self.rebuildDrawableQueues() }
    }

    func setupLowLevelTexture() {
        runOnMainSync { self.rebuildDrawableQueues() }
    }

    /// Enables/disables the double-width (SBS) output used by real-time 3D.
    /// The caller must resize the screen texture to match before calling this
    /// (2x width for stereo, 1x for mono), then rebind the material.
    func setStereoOutputEnabled(_ enabled: Bool, forceReattach: Bool = false) {
        // Serialize with the VideoToolbox frame path: this swaps the drawable
        // queues and resets the depth renderer while frames may be in flight.
        renderFrameLock.lock()
        defer { renderFrameLock.unlock() }
        let multiplier = enabled ? 2 : 1
        let changed = multiplier != stereoOutputMultiplier
        stereoOutputMultiplier = multiplier
        let expectedWidth = Int(videoWidth) * multiplier
        let queueMismatch = queueOutputWidth != 0 && queueOutputWidth != expectedWidth
        if queueMismatch {
            NSLog(
                "[Video] drawable queue %dw does not match 3D=%@ (%dw); rebuilding",
                queueOutputWidth, enabled ? "on" : "off", expectedWidth
            )
        }
        if !changed && !forceReattach && !queueMismatch { return }
        if multiplier == 1 {
            realtime3DConverter?.reset()
            lastPresentationTimeSeconds = nil
        }
        runOnMainSync { self.rebuildDrawableQueues() }
    }

    private func runOnMainSync(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { body() }
            }
        }
    }

    @MainActor
    private func rebuildDrawableQueues() {
        if videoWidth == 0 || videoHeight == 0 {
            print("Tried to set up client texture without defined dimensions (\(videoWidth), \(videoHeight)) - skipping")
            return
        }
        let outputWidth = Int(videoWidth) * stereoOutputMultiplier
        let outputHeight = Int(videoHeight)

        if let flat = flatLayerSnapshot() {
            flat.layer.drawableSize = CGSize(width: outputWidth, height: outputHeight)
        }

        NSLog(
            "[Video] rebuild drawable queues %dx%d multiplier=%d",
            outputWidth, outputHeight, stereoOutputMultiplier
        )
        let newQueue: TextureResource.DrawableQueue
        do {
            let descriptor = TextureResource.DrawableQueue.Descriptor(
                pixelFormat: metalFormat,
                width: outputWidth,
                height: outputHeight,
                usage: [.renderTarget, .shaderRead],
                // Anti-shimmer option: a mip chain lets the plane material
                // filter minified motion; off samples level 0 for the sharpest
                // picture. Both 2D and 3D follow the same choice so the two
                // modes keep the same look.
                mipmapsMode: mipmappedVideoOutput ? .allocateAll : .none
            )
            let queue = try TextureResource.DrawableQueue(descriptor)
            queue.allowsNextDrawableTimeout = true
            queueOutputWidth = outputWidth
            newQueue = queue
        } catch {
            // Keep the previous queue rather than killing the app under memory
            // pressure; the caller can turn 3D off to fall back to mono.
            NSLog("%@", "DrawableVideoDecoder: Could not create DrawableQueue (\(outputWidth)x\(outputHeight)): \(error)")
            return
        }
        self.drawableQueue = newQueue

        // The bloom layer samples the whole texture, which would mix both eyes;
        // keep it off while the output is stereo.
        self.chromaHaloQueue = stereoOutputMultiplier == 2 ? nil : {
            let mipShift = ChromaHaloDownsample.mipShift
            let cw = max(1, Int(videoWidth) >> mipShift)
            let ch = max(1, Int(videoHeight) >> mipShift)
            let descriptor = TextureResource.DrawableQueue.Descriptor(
                pixelFormat: metalFormat,
                width: cw,
                height: ch,
                usage: [.renderTarget, .shaderWrite, .shaderRead],
                mipmapsMode: .none
            )
            do {
                let q = try TextureResource.DrawableQueue(descriptor)
                q.allowsNextDrawableTimeout = true
                return q
            } catch {
                print("DrawableVideoDecoder: Could not create ChromaHalo queue: \(error)")
                return nil
            }
        }()

        self.chromaHaloScratchA = nil
        self.chromaHaloScratchB = nil

        region = MTLRegionMake2D(0, 0, outputWidth, outputHeight)

        self.callbackToRender(newQueue, self.chromaHaloQueue, (videoWidth, videoHeight))
    }

    /// Short description of the decoded stream's actual HDR format.
    func hdrFormatReport() -> String {
        hdrReportLock.lock()
        defer { hdrReportLock.unlock() }
        return hdrReport
    }

    /// Requests a one-shot measurement of the host's SDR white point from the
    /// next PQ frame. The caller should display a full-screen SDR white image.
    func requestHDRWhiteSample() {
        whiteSampleLock.lock()
        whiteSampleRequested = true
        whiteSampleLock.unlock()
        NSLog("[DrawableVideoDecoder] HDR white sample requested; waiting for a PQ frame")
        LiRequestIdrFrame()
    }

    private func sampleHDRWhiteIfRequested(imageBuffer: CVImageBuffer, fullRange: Bool) {
        guard pixelFormatIs10Bit(CVPixelBufferGetPixelFormatType(imageBuffer)) else {
            NSLog("[DrawableVideoDecoder] HDR white sample skipped: not a 10-bit frame")
            return
        }
        whiteSampleLock.lock()
        let requested = whiteSampleRequested
        if requested { whiteSampleRequested = false }
        whiteSampleLock.unlock()
        guard requested else { return }
        let lockStatus = CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            NSLog("[DrawableVideoDecoder] HDR white sample failed: lock status \(lockStatus)")
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(imageBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else {
            NSLog("[DrawableVideoDecoder] HDR white sample failed: no Y plane after lock")
            return
        }
        let width = CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
        let x0 = width / 4, x1 = width * 3 / 4
        let y0 = height / 4, y1 = height * 3 / 4
        var sum: Double = 0
        var count = 0
        for y in stride(from: y0, to: y1, by: 2) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for x in stride(from: x0, to: x1, by: 2) {
                sum += Double(row[x])
                count += 1
            }
        }
        guard count > 0 else { return }
        let rawAverage = sum / Double(count)
        // 10-bit bi-planar stores the 10-bit sample in the high bits of each
        // 16-bit word (P010/xf20 style): 37632 == 588 << 6.
        let average = rawAverage / 64.0
        let code = fullRange ? average / 1023.0 : (average - 64.0) / (940.0 - 64.0)
        let nits = Self.pqCodeToNits(code)
        let clamped = min(max(Float(nits), 80.0), 500.0)
        NSLog(
            "[DrawableVideoDecoder] HDR white sample: rawAvg=%.1f avgY=%.1f code=%.4f nits=%.1f clamped=%.1f",
            rawAverage, average, code, nits, clamped
        )
        DispatchQueue.main.async { [weak self] in
            self?.onHDRWhiteSample?(clamped)
        }
    }

    private static func pqCodeToNits(_ code: Double) -> Double {
        let m1 = 0.1593017578125
        let m2 = 78.84375
        let c1 = 0.8359375
        let c2 = 18.8515625
        let c3 = 18.6875
        let p = min(max(code, 0), 1)
        let n = pow(p, 1.0 / m2)
        let num = max(n - c1, 0)
        let den = max(c2 - c3 * n, 1e-4)
        return pow(num / den, 1.0 / m1) * 10000.0
    }

    /// Latest real-time 3D depth report (nil when 3D is off or no frame yet).
    func realtime3DReport() -> LSRealtimeStereoRenderer.Report? {
        realtime3DConverter?.lastReport
    }

    /// Basic setup for the decoder
    func setup(withVideoFormat videoFormat: Int32, width videoWidth: Int32, height videoHeight: Int32, frameRate: Int32) {
        self.videoFormat = videoFormat
        self.frameRate = frameRate
        self.videoWidth = Int(videoWidth)
        self.videoHeight = Int(videoHeight)
        print("DrawableVideoDecoder: setup format=\(videoFormat) \(videoWidth)x\(videoHeight)@\(frameRate)")

        // The cache itself only needs Metal compatibility; the per-frame
        // CVMetalTextureCacheCreateTextureFromImage call supplies the actual
        // plane format, which changes with the stream's colorspace.
        let cacheAttributes: [String: Any] = [
            kCVMetalTextureCacheMaximumTextureAgeKey as String: 1,
        ]
        let textureAttributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        let res = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            cacheAttributes as CFDictionary,
            mtlDevice,
            textureAttributes as CFDictionary,
            &textureCache
        )

        if res != kCVReturnSuccess {
            print("Creating texture cache failed \(res)")
        }

        setupLowLevelTexture()
    }

    private func noteFramePresented() {
        presentTimeLock.lock()
        lastPresentTime = CFAbsoluteTimeGetCurrent()
        presentTimeLock.unlock()
    }

    private func startStallWatchdog() {
        stopStallWatchdog()

        let queue = DispatchQueue(label: "com.moonlightvision.video-stall-watchdog", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            self.presentTimeLock.lock()
            let lastPresent = self.lastPresentTime
            let lastRecovery = self.lastStallRecoveryTime
            self.presentTimeLock.unlock()

            guard lastPresent > 0 else { return }

            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - lastPresent
            guard elapsed > self.stallPresentThreshold else { return }
            guard LiGetPendingVideoFrames() > 0 else { return }
            guard now - lastRecovery > self.stallRecoveryCooldown else { return }

            self.presentTimeLock.lock()
            self.lastStallRecoveryTime = now
            self.presentTimeLock.unlock()

            let pending = LiGetPendingVideoFrames()
            print("[DrawableVideoDecoder] Video stall detected (\(String(format: "%.2f", elapsed))s, pending=\(pending)) — requesting IDR")
            LiRequestIdrFrame()
        }
        timer.resume()
        stallWatchdogSource = timer
    }

    private func stopStallWatchdog() {
        stallWatchdogSource?.cancel()
        stallWatchdogSource = nil
    }

    /// Start the rendering loop (via CADisplayLink)
    func start() {
        print("DrawableVideoDecoder: start() display link")
        noteFramePresented()
        startStallWatchdog()
        reportedContentShown = false
        appliedFormatDesc = nil
        appliedFormatIsHDR = false
        lastFormatIsHDR = nil
        streamPrimariesType = 0
        streamMatrixType = 0
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkCallback(_:)))
        if #available(iOS 15.0, tvOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(frameRate),
                maximum: Float(frameRate),
                preferred: Float(frameRate)
            )
        } else {
            displayLink?.preferredFramesPerSecond = Int(frameRate)
        }

        // .default stops firing while the run loop is in a tracking or modal
        // mode, which starves the decode-unit queue and trips its overflow.
        displayLink?.add(to: .main, forMode: .common)
    }

    /// Stop the rendering loop
    func stop() {
        print("DrawableVideoDecoder: stop()")
        stopStallWatchdog()
        // Stop new submissions before touching decoder state. The display link
        // lives on the main run loop, so invalidate it there.
        stopDisplayLink()
        presentTimeLock.lock()
        lastPresentTime = 0
        lastStallRecoveryTime = 0
        presentTimeLock.unlock()

        // Drain in-flight frames before invalidating so no VideoToolbox
        // callback can run after the decoder state is cleared.
        if let session = session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        
        // Clear all decoder state
        formatDesc = nil
        parameterSetBuffers.removeAll()
        masteringDisplayColorVolume = nil
        contentLightLevelInfo = nil
        colorDescriptionLock.lock()
        cachedColorDescription = nil
        colorDescriptionLock.unlock()
        
        // Clear texture cache
        textureCache = nil
        copyPipelineState = nil
        copyPipelineFormat = nil
        chromaHaloRimPipelineState = nil
        chromaHaloBlurHPipelineState = nil
        chromaHaloBlurVPipelineState = nil
        chromaHaloScratchA = nil
        chromaHaloScratchB = nil
        prevChromaHaloTexture = nil

        print("DrawableVideoDecoder: Stopped and cleaned up all state")
    }

    private func stopDisplayLink() {
        let teardown = {
            self.displayLink?.invalidate()
            self.displayLink = nil
        }
        if Thread.isMainThread {
            teardown()
        } else {
            // Never block here. Teardown runs while the core joins its
            // threads; a synchronous hop to the main queue can deadlock
            // against a main thread that is itself waiting on the stream, and
            // that hang is what leaves the audio unit running unattended.
            DispatchQueue.main.async(execute: teardown)
        }
    }

    // MARK: - Rendering Loop

    @objc private func displayLinkCallback(_ sender: CADisplayLink) {
        var handle: VIDEO_FRAME_HANDLE?
        var du: PDECODE_UNIT?

        var submittedThisTick = 0
        while LiPollNextVideoFrame(&handle, &du) {
            // Once I a new frame from the network/stream, submit it
            guard let handle = handle, let du = du else {
                continue
            }

            // (Implementation detail) DrSubmitDecodeUnit is presumably your custom decode function
            let result = DrSubmitDecodeUnit(du)
            LiCompleteVideoFrame(handle, result)

            // Each submission copies and rewrites a whole frame on the main
            // thread. Draining an entire backlog in one tick blocks the UI for
            // that long, so leave the rest for the next tick.
            submittedThisTick += 1
            if submittedThisTick >= Self.maxFramesPerTick { break }

            // Frame pacing logic
            if framePacing {
                let displayRefreshRate = 1.0 / (sender.targetTimestamp - sender.timestamp)
                if displayRefreshRate >= Double(frameRate) * 0.9 {
                    // Keep one pending frame to smooth out network jitter
                    if LiGetPendingVideoFrames() == 1 {
                        break
                    }
                }
            }
        }
    }

    // MARK: - Decoding & Sample Buffer Handling

    /**
     *  Replaces the old `AVSampleBufferDisplayLayer` usage.
     *  Instead of enqueuing to a display layer, we create a `CMSampleBuffer`
     *  and forward it to your own rendering path (e.g., a Metal texture queue).
     */
    @discardableResult
    @objc(submitDecodeBuffer:length:bufferType:decodeUnit:)
    func submitDecodeBuffer(
        _ dataPtr: UnsafeMutablePointer<UInt8>!,
        length: Int32,
        bufferType: Int32,
        decode decodeUnit: PDECODE_UNIT!
    ) -> Int32 {
        if decodeUnit.pointee.frameType == FRAME_TYPE_IDR {
            if bufferType != BUFFER_TYPE_PICDATA {
                if bufferType == BUFFER_TYPE_VPS
                    || bufferType == BUFFER_TYPE_SPS
                    || bufferType == BUFFER_TYPE_PPS
                {
                    let startLen = (dataPtr[2] == 0x01) ? 3 : 4
                    let newData = Data(bytes: dataPtr + startLen, count: Int(length) - startLen)
                    parameterSetBuffers.append([UInt8](newData))
                }
                return DR_OK
            }

            if let formatDesc = recreateFormatDescriptionForIDR(
                dataPtr: dataPtr, length: length
            ) {
                self.formatDesc = formatDesc
                updateColorDescriptionCache()
                let decoderConfiguration: [String: Any] = [
                    kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
                ]

                // Choose the decode target from the stream's actual format,
                // not only from the client's HDR setting. A host HDR toggle
                // changes the format description; the next IDR re-keys the VT
                // session in place with the matching pixel format.
                let transfer = Self.stringExtension(
                    formatDesc,
                    key: kCMFormatDescriptionExtension_TransferFunction
                )
                let formatIsPQ = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                let formatBits = (CMFormatDescriptionGetExtension(
                    formatDesc,
                    extensionKey: kCMFormatDescriptionExtension_BitsPerComponent
                ) as? NSNumber)?.intValue ?? 0
                let formatPrimaries = Self.stringExtension(
                    formatDesc,
                    key: kCMFormatDescriptionExtension_ColorPrimaries
                )
                let formatIs2020 = formatPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
                let formatIsSMPTEC = formatPrimaries == "SMPTE_C"
                let formatMatrix = Self.stringExtension(
                    formatDesc,
                    key: kCMFormatDescriptionExtension_YCbCrMatrix
                )
                // The renderer follows the stream's own signaling. The client
                // toggle only decides what this app asks the host for; it must
                // not change how a stream that already arrived as HDR is
                // decoded. Depending on it here used to turn the same PQ/2020
                // stream into an 8-bit SDR decode when HDR was switched off,
                // which crushes every shadow to black. A BT.2020 stream whose
                // bit depth is not declared is treated as HDR-capable rather
                // than falling back to SDR.
                let formatIsHDR = formatIsPQ || (formatIs2020 && formatBits != 8)
                streamPrimariesType = formatIs2020 ? 1 : (formatIsSMPTEC ? 2 : 0)
                streamMatrixType = formatMatrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String)
                    ? 1
                    : (formatMatrix == "ITU_R_601_4" ? 2 : 0)

                var attributes: [CFString: Any] = [
                    kCVPixelBufferMetalCompatibilityKey: true,
                    kCVPixelBufferPoolMinimumBufferCountKey: 3
                ]
                if formatIsHDR {
                    attributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                } else {
                    if (self.videoFormat & VIDEO_FORMAT_MASK_AV1) != 0 {
                        attributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_Lossless_32BGRA
                    } else {
                        attributes[kCVPixelBufferPixelFormatTypeKey] = decodingFormat
                    }
                }
                if formatIsHDR != lastFormatIsHDR {
                    lastFormatIsHDR = formatIsHDR
                    print(
                        "[DrawableVideoDecoder] Stream HDR state: \(formatIsHDR ? "HDR" : "SDR")"
                        + " (client toggle=\(hdrEnabled), renderer follows the stream)"
                    )
                }

                // Most keyframes repeat the format the session already decodes.
                // Rebuilding then costs a blocking drain of in-flight frames on
                // the display-link (main) thread, once per keyframe — which is
                // what makes an IDR storm visible as UI stutter. Reuse the
                // session unless the format really changed.
                let formatUnchanged = session != nil
                    && appliedFormatIsHDR == formatIsHDR
                    && appliedFormatDesc.map { CMFormatDescriptionEqual($0, otherFormatDescription: formatDesc) } == true

                if !formatUnchanged {
                    // Drain and retire the previous session before overwriting
                    // it; otherwise every keyframe leaks a VT session and an
                    // in-flight callback can outlive the decoder.
                    if let oldSession = session {
                        VTDecompressionSessionWaitForAsynchronousFrames(oldSession)
                        VTDecompressionSessionInvalidate(oldSession)
                        session = nil
                    }

                    let createStatus = VTDecompressionSessionCreate(
                        allocator: kCFAllocatorDefault,
                        formatDescription: formatDesc,
                        decoderSpecification: decoderConfiguration as CFDictionary,
                        imageBufferAttributes: attributes as CFDictionary,
                        outputCallback: &decoderCallback,
                        decompressionSessionOut: &session
                    )
                    if createStatus != noErr {
                        NSLog("%@", "[Video] VTDecompressionSessionCreate failed: \(createStatus)")
                        session = nil
                        free(dataPtr)
                        return DR_NEED_IDR
                    }
                    appliedFormatDesc = formatDesc
                    appliedFormatIsHDR = formatIsHDR
                }

            } else {
                free(dataPtr)
                return DR_NEED_IDR
            }
        }

        guard let formatDesc = formatDesc else {
            free(dataPtr)
            return DR_NEED_IDR
        }

        guard let session = session else {
            free(dataPtr)
            return DR_NEED_IDR
        }

        guard let sampleBuffer = createSampleBuffer(
            dataPtr: dataPtr,
            length: Int(length),
            formatDesc: formatDesc,
            decodeUnit: decodeUnit
        ) else {
            return DR_NEED_IDR
        }

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        if decodeStatus != noErr {
            NSLog("%@", "[Video] VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
            return DR_NEED_IDR
        }

        if decodeUnit.pointee.frameType == FRAME_TYPE_IDR, !reportedContentShown {
            reportedContentShown = true
            callbacks.videoContentShown()
        }

        return DR_OK
    }

    // MARK: - Helper: Recreate Format Description for IDR

    private func recreateFormatDescriptionForIDR(
        dataPtr: UnsafeMutablePointer<UInt8>,
        length: Int32
    ) -> CMVideoFormatDescription? {
        // Freed old formatDesc
        if let old = formatDesc {
            // CFRelease(old)
            formatDesc = nil
        }

        // If's H.264 or HEVC, gather parameter sets. Each keyframe carries a
        // fresh copy, so consume them here; keeping old sets would build the
        // format description from duplicates and break decoding.
        if (videoFormat & VIDEO_FORMAT_MASK_H264) != 0 {
            let desc = createH264FormatDescription()
            parameterSetBuffers.removeAll(keepingCapacity: true)
            return desc
        } else if (videoFormat & VIDEO_FORMAT_MASK_H265) != 0 {
            let desc = createHEVCFormatDescription()
            parameterSetBuffers.removeAll(keepingCapacity: true)
            return desc
        } else if (videoFormat & VIDEO_FORMAT_MASK_AV1) != 0 {
            // For AV1, parse IDR frame to create a format desc
            parameterSetBuffers.removeAll(keepingCapacity: true)
            let frameData = Data(bytesNoCopy: dataPtr, count: Int(length), deallocator: .none)
            return createAV1FormatDescriptionForIDRFrame(frameData)
        } else {
            // Unsupported video format - return nil to request IDR
            return nil
        }
    }

    /// Calls `body` with a pointer into each parameter set while every buffer
    /// is guaranteed to stay alive. `UnsafePointer(_:)` alone only promises
    /// that for the duration of the initializer call.
    private static func withParameterSetPointers<T>(
        _ sets: [[UInt8]],
        _ body: ([UnsafePointer<UInt8>], [Int]) -> T
    ) -> T {
        func recurse(
            _ index: Int,
            _ pointers: [UnsafePointer<UInt8>],
            _ sizes: [Int]
        ) -> T {
            guard index < sets.count else { return body(pointers, sizes) }
            return sets[index].withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    return recurse(index + 1, pointers, sizes)
                }
                return recurse(
                    index + 1,
                    pointers + [base],
                    sizes + [buffer.count]
                )
            }
        }
        return recurse(0, [], [])
    }

    /// Creates an H.264 `CMVideoFormatDescription` from the stored `parameterSetBuffers`.
    private func createH264FormatDescription() -> CMVideoFormatDescription? {
        let sets = parameterSetBuffers
        guard !sets.isEmpty else { return nil }

        var formatDesc: CMFormatDescription?
        let status = Self.withParameterSetPointers(sets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(NAL_LENGTH_PREFIX_SIZE),
                formatDescriptionOut: &formatDesc
            )
        }

        if status != noErr {
            print("Failed to create H264 format description: \(status)")
            return nil
        }
        return formatDesc
    }

    /// Creates an HEVC `CMVideoFormatDescription` from the stored `parameterSetBuffers`.
    private func createHEVCFormatDescription() -> CMVideoFormatDescription? {
        let sets = parameterSetBuffers
        guard !sets.isEmpty else { return nil }

        // Prepare metadata dictionary
        let videoFormatParams = NSMutableDictionary()

        if let contentLightLevelInfo = contentLightLevelInfo {
            videoFormatParams.setObject(contentLightLevelInfo, forKey: kCMFormatDescriptionExtension_ContentLightLevelInfo as NSString)
        }
        if let masteringDisplayColorVolume = masteringDisplayColorVolume {
            videoFormatParams.setObject(masteringDisplayColorVolume, forKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume as NSString)
        }

        var formatDesc: CMFormatDescription?
        let status = Self.withParameterSetPointers(sets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(NAL_LENGTH_PREFIX_SIZE),
                extensions: videoFormatParams as CFDictionary,
                formatDescriptionOut: &formatDesc
            )
        }

        if status != noErr {
            print("Failed to create HEVC format description: \(status)")
            return nil
        }
        return formatDesc
    }

    /// Creates an AV1 `CMVideoFormatDescription` from the data for an IDR frame.
    private func createAV1FormatDescriptionForIDRFrame(_ frameData: Data) -> CMVideoFormatDescription? {
        do {
            return try frameData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> CMVideoFormatDescription in
                var mutableBuffer = UnsafeMutableBufferPointer<UInt8>(mutating: buffer.bindMemory(to: UInt8.self))
                let fd = try CMVideoFormatDescriptionCreateFromAV1SequenceHeaderOBUWithAV1C(
                    mutableBuffer,
                    masteringDisplayColorVolume: masteringDisplayColorVolume,
                    contentLightLevelInfo: contentLightLevelInfo
                )
                return fd as CMVideoFormatDescription
            }
        } catch {
            print("AV1 format description creation failed: \(error)")
            return nil
        }
    }

    // MARK: - Creating a Sample Buffer

    private func createSampleBuffer(
        dataPtr: UnsafeMutablePointer<UInt8>,
        length: Int,
        formatDesc: CMVideoFormatDescription,
        decodeUnit: PDECODE_UNIT!
    ) -> CMSampleBuffer? {
        // Create an empty container block for rewriting AnnexB to length-delimited if needed
        var frameBlockBuffer: CMBlockBuffer?

        // If H.264/HEVC, rewrite from AnnexB to length-delimited
        if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) != 0 {
            // dataPtr is either tied to the resulting BB, or is copied and freed immediately.
            // dataPtr is also freed even if the result is nil.
            let nals = UnsafeMutableBufferPointer<UInt8>(start: UnsafeMutablePointer(mutating: dataPtr), count: length)
            frameBlockBuffer = annexBBufferToCMSampleBuffer(buffer: nals, videoFormat: formatDesc)
        } else {
            // AV1 or other codecs that don't need rewriting
            let statusDataBlock = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: dataPtr,
                blockLength: length,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: length,
                flags: 0,
                blockBufferOut: &frameBlockBuffer
            )
            if statusDataBlock != kCMBlockBufferNoErr {
                print("CMBlockBufferCreateWithMemoryBlock failed: \(statusDataBlock)")
                // The block buffer did not take ownership of the frame.
                free(dataPtr)
                return nil
            }
            // Now the CMBlockBuffer controls freeing `dataPtr`
        }

        // Build the sample buffer
        var sampleBuffer: CMSampleBuffer?
        // The decode unit carries the presentation time in microseconds.
        var sampleTiming = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTimeMake(
                value: Int64(decodeUnit.pointee.presentationTimeUs),
                timescale: 1_000_000
            ),
            decodeTimeStamp: CMTime.invalid
        )
        let statusSample = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: frameBlockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        if statusSample != noErr {
            print("CMSampleBufferCreate failed: \(statusSample)")
            return nil
        }

        return sampleBuffer
    }

    // Based on https://webrtc.googlesource.com/src/+/refs/heads/main/common_video/h264/h264_common.cc
    private func findNaluIndices(bufferBounded: UnsafeMutableBufferPointer<UInt8>) -> ([NaluIndex], Bool) {
        var elgibleForModifyInPlace = true
        guard bufferBounded.count >= /* kNaluShortStartSequenceSize */ 3 else {
            return ([], false)
        }

        var sequences = [NaluIndex]()

        let end = bufferBounded.count - /* kNaluShortStartSequenceSize */ 3
        var i = 0
        let buffer = Data(bytesNoCopy: bufferBounded.baseAddress!, count: bufferBounded.count, deallocator: .none) // ?? why is this faster
        while i < end {
            if buffer[i + 2] > 1 {
                i += 3
            } else if buffer[i + 2] == 1 {
                if buffer[i + 1] == 0 && buffer[i] == 0 {
                    var index = NaluIndex(startOffset: i, payloadStartOffset: i + 3, payloadSize: 0, threeByteHeader: true)
                    if index.startOffset > 0 && buffer[index.startOffset - 1] == 0 {
                        index.startOffset -= 1
                        index.threeByteHeader = false
                    } else {
                        elgibleForModifyInPlace = false
                    }

                    if !sequences.isEmpty {
                        sequences[sequences.count - 1].payloadSize = index.startOffset - sequences.last!.payloadStartOffset
                    }

                    sequences.append(index)
                }

                i += 3
            } else {
                i += 1
            }
        }

        if !sequences.isEmpty {
            sequences[sequences.count - 1].payloadSize = bufferBounded.count - sequences.last!.payloadStartOffset
        }

        return (sequences, elgibleForModifyInPlace)
    }

    private struct NaluIndex {
        var startOffset: Int
        var payloadStartOffset: Int
        var payloadSize: Int
        var threeByteHeader: Bool
    }

    // Based on https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/video_codec/nalu_rewriter.cc
    private func annexBBufferToCMSampleBuffer(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat: CMFormatDescription) -> CMBlockBuffer? {
        let (naluIndices, elgibleForModifyInPlace) = findNaluIndices(bufferBounded: buffer)

        if elgibleForModifyInPlace {
            return annexBBufferToCMSampleBufferModifyInPlace(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        } else {
            return annexBBufferToCMSampleBufferWithCopy(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        }
    }

    private func annexBBufferToCMSampleBufferWithCopy(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat _: CMFormatDescription, naluIndices: [NaluIndex]) -> CMBlockBuffer? {
        var err: OSStatus = 0
        defer { buffer.deallocate() }

        // replacing the 3/4 nalu headers with a 4 byte length, so add an extra byte on top of the original length for each 3-byte nalu header
        let blockBufferLength = buffer.count + naluIndices.filter(\.threeByteHeader).count
        
        // Safe allocation with graceful frame dropping on OOM
        guard let blockBuffer = try? CMBlockBuffer(length: blockBufferLength, flags: .assureMemoryNow) else {
            print("⚠️ Failed to allocate CMBlockBuffer (\(blockBufferLength) bytes) - dropping frame due to memory pressure")
            return nil
        }

        var contiguousBuffer: CMBlockBuffer!
        if !CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) {
            err = CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: blockBuffer, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguousBuffer)
            if err != 0 {
                print("CMBlockBufferCreateContiguous error")
                return nil
            }
        } else {
            contiguousBuffer = blockBuffer
        }

        var blockBufferSize = 0
        var dataPtr: UnsafeMutablePointer<Int8>!
        err = CMBlockBufferGetDataPointer(contiguousBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &blockBufferSize, dataPointerOut: &dataPtr)
        if err != 0 {
            print("CMBlockBufferGetDataPointer error")
            return nil
        }

        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(dataPtr))!
        var offset = 0

        buffer.withUnsafeBytes { unsafeBytes in
            let bytes = unsafeBytes.bindMemory(to: UInt8.self).baseAddress!

            for index in naluIndices {
                pointer.advanced(by: offset).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
                pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
                pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >> 8) & 0xFF)
                pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize) & 0xFF)
                offset += 4

                pointer.advanced(by: offset).update(from: bytes.advanced(by: index.payloadStartOffset), count: index.payloadSize)
                offset += index.payloadSize
            }
        }

        return contiguousBuffer
    }

    private func annexBBufferToCMSampleBufferModifyInPlace(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat _: CMFormatDescription, naluIndices: [NaluIndex]) -> CMBlockBuffer? {
        var offset = 0

        let umrbp = UnsafeMutableRawBufferPointer(start: buffer.baseAddress, count: buffer.count)
        
        // Safe allocation with graceful frame dropping on OOM
        guard let bb = try? CMBlockBuffer(buffer: umrbp, deallocator: { _, _ in buffer.deallocate() }, flags: .assureMemoryNow) else {
            print("⚠️ Failed to create CMBlockBuffer from buffer (\(buffer.count) bytes) - dropping frame due to memory pressure")
            buffer.deallocate()
            return nil
        }

        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(buffer.baseAddress!))!
        for index in naluIndices {
            pointer.advanced(by: offset + 0).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
            pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
            pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >> 8) & 0xFF)
            pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize) & 0xFF)
            offset += 4

            offset += index.payloadSize
        }

        return bb
    }

    // MARK: - HDR Mode

    /// Human-readable color/format summary for the stats overlay, matching the
    /// AVSampleBufferDisplayLayer renderer this decoder replaces. The string is
    /// rebuilt when a new format description arrives and cached, so the stats
    /// timer never reads decoder state from another thread.
    func getColorDescription() -> String? {
        colorDescriptionLock.lock()
        defer { colorDescriptionLock.unlock() }
        return cachedColorDescription
    }

    private func updateColorDescriptionCache() {
        let description = Self.describe(formatDesc)
        colorDescriptionLock.lock()
        cachedColorDescription = description
        colorDescriptionLock.unlock()
    }

    private static func describe(_ formatDesc: CMVideoFormatDescription?) -> String? {
        guard let formatDesc else { return nil }
        var parts: [String] = []

        if let bits = CMFormatDescriptionGetExtension(
            formatDesc,
            extensionKey: kCMFormatDescriptionExtension_BitsPerComponent
        ) as? NSNumber {
            parts.append("\(bits.intValue)-bit")
        }

        if let primaries = Self.stringExtension(
            formatDesc,
            key: kCMFormatDescriptionExtension_ColorPrimaries
        ) {
            if primaries == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String {
                parts.append("BT.2020")
            } else if primaries == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String {
                parts.append("BT.709")
            } else if !primaries.isEmpty {
                parts.append(primaries)
            }
        }

        if let transfer = Self.stringExtension(
            formatDesc,
            key: kCMFormatDescriptionExtension_TransferFunction
        ) {
            if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String {
                parts.append("PQ (HDR)")
            } else if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String {
                parts.append("HLG (HDR)")
            } else if transfer == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String {
                parts.append("BT.709")
            } else if !transfer.isEmpty {
                parts.append(transfer)
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func stringExtension(
        _ formatDesc: CMVideoFormatDescription,
        key: CFString
    ) -> String? {
        guard let value = CMFormatDescriptionGetExtension(formatDesc, extensionKey: key) else {
            return nil
        }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return (value as! CFString) as String
        }
        return nil
    }

    func setHdrMode(_ enabled: Bool) {
        var metadataChanged = false

        // Mastering display color volume check
        let displayMetadata = HDRParsingUtils.parseHDRDisplayMetadata(enabled)

        if let displayMetadata = displayMetadata,
           masteringDisplayColorVolume == nil ||
           masteringDisplayColorVolume != displayMetadata
        {
            masteringDisplayColorVolume = displayMetadata
            metadataChanged = true
        } else if masteringDisplayColorVolume != nil {
            masteringDisplayColorVolume = nil
            metadataChanged = true
        }

        // Content light level info check
        let lightMetadata = HDRParsingUtils.parseHDRLightMetadata(enabled)
        if let lightMetadata = lightMetadata,
           contentLightLevelInfo == nil ||
           contentLightLevelInfo != lightMetadata
        {
            contentLightLevelInfo = lightMetadata
            metadataChanged = true
        } else if contentLightLevelInfo != nil {
            contentLightLevelInfo = nil
            metadataChanged = true
        }

        if metadataChanged {
            updateHDRMetadata()
            LiRequestIdrFrame()
        }
    }

    /// Sync constants with `Shaders.metal` `chromaHaloRimFragment` / `Reactive1ChromosphereReach`.
    private func chromaHaloTemporalFrameMix() -> Float {
        let kBase: Float = 1.55
        let kSpan: Float = 1.93
        let reachT = min(1, max(0, (chromaHaloScale - kBase) / max(kSpan, 1e-4)))
        return 0.27 + reachT * 0.055
    }

    private func ensureChromaHaloBlurScratchMatches(_ haloTex: MTLTexture) {
        let w = haloTex.width
        let h = haloTex.height
        let pf = haloTex.pixelFormat
        if let a = chromaHaloScratchA,
           a.width == w, a.height == h, a.pixelFormat == pf,
           let b = chromaHaloScratchB,
           b.width == w, b.height == h, b.pixelFormat == pf {
            return
        }
        chromaHaloScratchA = nil
        chromaHaloScratchB = nil
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pf, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        chromaHaloScratchA = mtlDevice.makeTexture(descriptor: desc)
        chromaHaloScratchB = mtlDevice.makeTexture(descriptor: desc)
    }

    // Builds a simple copy pipeline with no input buffers, just
    // draw 4 vertices to copy the input texture to the output
    private func buildCopyPipeline(
        fragment: String,
        format: MTLPixelFormat? = nil
    ) -> MTLRenderPipelineState? {
        guard
            let library = mtlDevice.makeDefaultLibrary()
        else {
            return nil
        }
        
        let vertexFunction = library.makeFunction(name: "copyVertexShader")
        
        // We always request single-plane RGBA output from VT (RGBA16F for HDR, BGRA8 for SDR),
        // so always use the HDR copy fragment (no YUV conversion).
        let fragmentFunction = library.makeFunction(name: fragment)
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "CopyBlitPipeline:\(fragment)"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = format ?? metalFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        pipelineDescriptor.maxVertexAmplificationCount = 1

        return try? mtlDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    // Convert big endian UInt16 to host Float
    private func convertBigEndianUInt16ToFloat(_ value: UInt16) -> Float {
        let hostValue = CFSwapInt16BigToHost(value)
        return Float(hostValue)
    }

    // Create parameter buffers for HDR metadata
    private func createHDRParameterBuffers() -> (MTLBuffer?, MTLBuffer?) {
        var hdrParams = hdrSettingsProvider?() ?? HDRParams(
            boost: 1.0,
            contrast: 1.0,
            saturation: 1.0,
            brightness: 0.0,
            pqExposure: 1.0,
            mode: 0
        )

        // In HDR, allow Filmic/ACES mapping and gentle enhancement,
        // but clamp to safe ranges and force additive brightness to 0.0.
        if hdrEnabled {
            hdrParams.brightness = 0.0
            // Remove clamps for HDR to allow true neutral defaults and wild presets
            // hdrParams.boost = max(0.85, min(hdrParams.boost, 1.25))
            // hdrParams.contrast = max(0.90, min(hdrParams.contrast, 1.20))
            // hdrParams.saturation = max(0.90, min(hdrParams.saturation, 1.25))
            // If no mode set, prefer ACES filmic in HDR
            if hdrParams.mode == 0 {
                hdrParams.mode = 1
            }
        }

        // Enable enhancements in HDR (for ACES tone mapping),
        // keep the toggle for SDR tied to mode != 0.
        let applyEnhancements: Bool = hdrEnabled ? true : (hdrParams.mode != 0)

        var enabled = applyEnhancements
        let enabledBuffer = mtlDevice.makeBuffer(
            bytes: &enabled,
            length: MemoryLayout<Bool>.size,
            options: .storageModeShared
        )

        let paramsBuffer = mtlDevice.makeBuffer(
            bytes: &hdrParams,
            length: MemoryLayout<HDRParams>.size,
            options: .storageModeShared
        )

        return (enabledBuffer, paramsBuffer)
    }

    // MARK: - METAL

    private let planeVertexData: [Float] = [
        -1, -1, 0, 1,
        1, -1, 1, 1,
        -1, 1, 0, 0,
        1, 1, 1, 0,
    ]

    // Add new method to update HDR metadata
    private func updateHDRMetadata() {
        // Get HDR metadata from the core
        if !LiGetHdrMetadata(&hdrMetadata) {
            print("Failed to fetch HDR metadata from the core")
        }
    }
    
    // Parse SMPTE ST 2086 mastering display color volume metadata
    private func parseMasteringDisplayColorVolume(_ data: Data) {
        // Data should be 24 bytes
        guard data.count == 24 else {
            print("Invalid metadata length: \(data.count)")
            return
        }

        // Extract values (stored as normalized 16-bit unsigned integers)
        let displayPrimariesX = [
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) })) / 50000.0,
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) })) / 50000.0,
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self) })) / 50000.0
        ]
        
        let displayPrimariesY = [
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) })) / 50000.0,
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) })) / 50000.0,
            Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 10, as: UInt16.self) })) / 50000.0
        ]
        
        let whitePointX = Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt16.self) })) / 50000.0
        let whitePointY = Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 14, as: UInt16.self) })) / 50000.0
        
        let maxDisplayLuminance = Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt16.self) }))
        let minDisplayLuminance = Float(CFSwapInt16BigToHost(data.withUnsafeBytes { $0.load(fromByteOffset: 18, as: UInt16.self) })) / 10000.0

        print("\nHDR Display Metadata:")
        print("Display Primaries (x,y):")
        print("Red:    (\(displayPrimariesX[0]), \(displayPrimariesY[0]))")
        print("Green: (\(displayPrimariesX[1]), \(displayPrimariesY[1]))")
        print("Blue:  (\(displayPrimariesX[2]), \(displayPrimariesY[2]))")
        print("White Point: (\(whitePointX), \(whitePointY))")
        print("Max Display Luminance: \(maxDisplayLuminance) nits")
        print("Min Display Luminance: \(minDisplayLuminance) nits")
    }
}

// MARK: - Constants Port

private let NALU_START_PREFIX_SIZE: Int = 3
private let NAL_LENGTH_PREFIX_SIZE: Int = 4

// Video format constants, decode buffer types and DR_* results come from
// Limelight.h through the bridging header.

