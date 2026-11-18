//
//  LSRealtimeStereoRenderer.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import CoreVideo
import Foundation
import Metal
import OSLog

/// Swift mirrors of the structs in RealtimeStereo.metal. Field order and
/// SIMD alignment must match the Metal declarations exactly.
nonisolated struct LSRealtimeStereoColorParams {
    var range: SIMD4<Float>
    var matrix: SIMD4<Float>
}

nonisolated struct LSRealtimeStereoPrepareParams {
    var contentRect: SIMD4<Float>
    var taps: SIMD2<UInt32>
    var reserved = SIMD2<UInt32>(0, 0)
}

nonisolated struct LSRealtimeStereoAnalyzeParams {
    var contentRect: SIMD4<Int32>
    var forceReset: UInt32
    var cutThreshold: Float
    var minimumRange: Float
    var smoothing: Float
    /// RSA_ANALYZE_* 位标志（bit0 = 两级切镜）。
    var flags: UInt32 = 0

    static let twoStageCutFlag: UInt32 = 1 << 0
}

/// 两级切镜的阈值（the 3D pipeline 的原值：jumpDiff 0.06 / jumpHist 0.50 /
/// sameDiff 0.06 / sameHist 0.20 / corrMax 0.60 / standOut 3.0 / twoBack 1.12）。
nonisolated struct LSRealtimeStereoCutParams {
    var jumpDiff: Float
    var jumpHist: Float
    var sameDiff: Float
    var sameHist: Float
    var correlationMax: Float
    var standOut: Float
    var twoBack: Float
    var flat: Float

    static let moonlightDefaults = LSRealtimeStereoCutParams(
        jumpDiff: 0.06, jumpHist: 0.50, sameDiff: 0.06, sameHist: 0.20,
        correlationMax: 0.60, standOut: 3.0, twoBack: 1.12, flat: 1.0e-5
    )
}

/// 归一化参数：老链路按像素变化加权；方案 3/4/5 用真实时间一阶平均。
nonisolated struct LSRealtimeStereoNormalizeParams {
    var temporalAlpha: Float
    var changeSigma: Float
    var flags: UInt32
    var reserved: UInt32 = 0

    static let timeTauFlag: UInt32 = 1 << 0
}

/// 两级切镜状态缓冲的字节数（对应 Metal 的 `RSCutState`；GPU 读写，CPU 只在
/// 分配时清零）。
nonisolated enum LSRealtimeStereoCutStateLayout {
    static let gridCells = 16 * 16
    static let histogramBins = 16
    static let thumbCount = 4      // current / last / older / before
    static let scalarFloats = 5    // lastDiff…twoBackDiff
    static let scalarUInts = 4     // haveLast…pending

    static var byteCount: Int {
        thumbCount * (gridCells + histogramBins) * MemoryLayout<Float>.size
            + scalarFloats * MemoryLayout<Float>.size
            + scalarUInts * MemoryLayout<UInt32>.size
    }
}

nonisolated struct LSRealtimeStereoAnalysisState {
    var lo: Float = 0
    var hi: Float = 1
    var sceneDelta: Float = 0
    /// 有任一重置（jump / confirmed / 老链路判切）时为 1。
    var cut: UInt32 = 0
    var active = SIMD4<Int32>(0, 0, 0, 0)
    var frames: UInt32 = 0
    /// RSA_CUT_*：本张预测触发的重置位（bit0 = jump/TEXEL，bit1 = confirmed/RANGE）。
    var cutFlags: UInt32 = 0
    var reserved1: UInt32 = 0
    var reserved2: UInt32 = 0

    static let cutTEXELFlag: UInt32 = 1 << 0
    static let cutRANGEFlag: UInt32 = 1 << 1
}

nonisolated struct LSRealtimeStereoUpsampleParams {
    var contentRect: SIMD4<Float>
    var footprint: SIMD2<Float>
    var rangeSigma: Float
    var spatialSigma: Float
}

nonisolated struct LSRealtimeStereoParams {
    /// 精修时深度沿行用三次 B 样条读（复刻 the 3D pipeline 的低分辨率深度读取）。
    static let cubicDepthFlag: UInt32 = 1 << 0

    var amplitude: Float
    var convergence: Float
    var slope: Float
    var radius: Int32
    var edgeMargin: Float
    var iterations: UInt32
    /// 牛顿精修步数（0 = 不精修）。
    var refineSteps: UInt32 = 0
    var flags: UInt32 = 0
}

/// Pipelines are compiled once per process; renderers come and go with every
/// AVSampleBufferVideoRenderer rebuild.
nonisolated final class LSRealtimeStereoGPU: @unchecked Sendable {
    enum GPUError: LocalizedError {
        case metalUnavailable
        case libraryUnavailable
        case functionUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .metalUnavailable: return "实时 3D 所需的 Metal 设备不可用"
            case .libraryUnavailable: return "实时 3D 着色器库不可用"
            case .functionUnavailable(let name): return "实时 3D 着色器缺失：\(name)"
            }
        }
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let prepareYCbCr: MTLComputePipelineState
    let prepareRGBA: MTLComputePipelineState
    let upsampleYCbCr: MTLComputePipelineState
    let upsampleRGBA: MTLComputePipelineState
    let analyze: MTLComputePipelineState
    let normalize: MTLComputePipelineState
    let dilate: MTLComputePipelineState
    let inverseMap: MTLComputePipelineState
    let gather: MTLComputePipelineState
    let refine: MTLComputePipelineState
    let warp: MTLComputePipelineState

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: LSRealtimeStereoGPU?

    static func shared() throws -> LSRealtimeStereoGPU {
        try lock.withLock {
            if let cached { return cached }
            guard let device = MTLCreateSystemDefaultDevice() else { throw GPUError.metalUnavailable }
            guard let library = try? device.makeDefaultLibrary(bundle: .main) else {
                throw GPUError.libraryUnavailable
            }
            let gpu = try LSRealtimeStereoGPU(device: device, library: library)
            cached = gpu
            return gpu
        }
    }

    init(device: MTLDevice, library: MTLLibrary) throws {
        guard let queue = device.makeCommandQueue() else { throw GPUError.metalUnavailable }
        queue.label = "Real-time 3D"
        self.device = device
        self.queue = queue

        func pipeline(_ name: String, rgba: Bool? = nil) throws -> MTLComputePipelineState {
            let function: MTLFunction
            if let rgba {
                let constants = MTLFunctionConstantValues()
                var value = rgba
                constants.setConstantValue(&value, type: .bool, index: 0)
                function = try library.makeFunction(name: name, constantValues: constants)
            } else {
                guard let plain = library.makeFunction(name: name) else {
                    throw GPUError.functionUnavailable(name)
                }
                function = plain
            }
            return try device.makeComputePipelineState(function: function)
        }

        prepareYCbCr = try pipeline("rs_prepare", rgba: false)
        prepareRGBA = try pipeline("rs_prepare", rgba: true)
        upsampleYCbCr = try pipeline("rs_upsample", rgba: false)
        upsampleRGBA = try pipeline("rs_upsample", rgba: true)
        analyze = try pipeline("rs_analyze")
        normalize = try pipeline("rs_normalize")
        dilate = try pipeline("rs_dilate")
        inverseMap = try pipeline("rs_inverse_map")
        gather = try pipeline("rs_gather")
        refine = try pipeline("rs_refine")
        warp = try pipeline("rs_warp")
    }
}

/// Per-stream 2D→3D renderer. Queue-confined: every call comes from the owning
/// player's serial render queue.
///
/// Each converted frame gets its own depth prediction whenever the device can
/// keep up with the frame rate; only when inference is slower than the frame
/// interval (60 fps on slower chips) is the newest depth reused for the frame
/// in between. Nothing waits for depth: a frame is never dropped or delayed
/// because inference is pending.
nonisolated final class LSRealtimeStereoRenderer: @unchecked Sendable {
    enum RenderError: LocalizedError {
        case unsupportedPixelFormat(OSType)
        case texture(OSStatus)
        case textureCache(OSStatus)
        case commandBuffer
        case gpu(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedPixelFormat(let format):
                return "实时 3D 不支持此像素格式：\(format)"
            case .texture(let status):
                return "实时 3D 无法创建纹理（\(status)）"
            case .textureCache(let status):
                return "实时 3D 无法创建纹理缓存（\(status)）"
            case .commandBuffer:
                return "实时 3D 无法创建 Metal 命令"
            case .gpu(let description):
                return "实时 3D GPU 执行失败：\(description)"
            }
        }
    }

    struct FrameTiming {
        /// Presentation time in seconds.
        var presentationTime: Double
        /// Nominal frame duration in seconds, if the container provides it.
        var duration: Double?
        /// Paused / scrubbing frames always get a fresh prediction.
        var isStill = false
    }

    struct Report: Equatable {
        var inferredDepth: Bool
        var hasDepth: Bool
        var depthStride: Int
        /// Model input + Neural Engine prediction, when this frame inferred.
        var inferenceSeconds: Double?
        /// Depth field, inverse map and both eye resamples.
        var synthesisSeconds: Double
        /// 本帧用的深度比它自己旧/新多少帧（0 = 同帧深度）。调预取深度用。
        var depthAgeFrames: Int
    }

    /// Geometry of the 3D effect, derived from the user-facing settings.
    struct Geometry: Equatable {
        /// Per-eye shift per unit of normalised depth, as a fraction of width.
        var amplitude: Float
        /// Normalised depth that lands on the screen plane.
        var convergence: Float

        /// 标尺对齐 the 3D pipeline：深度 100 % = 每眼 1.5 % 画宽（他们的滑条上限；
        /// 他们的 ZipDepth 默认 0.6 %，对应我们的深度 40 %）。汇聚滑条 0 = 0.5，
        /// 与他们的默认（50 %）一致：滑条 −1 全部出屏、+1 全部入屏，0 时前后各半。
        init(settings: LSRealtime3DSettings) {
            amplitude = settings.depthStrength * 0.015
            convergence = 0.5 + 0.5 * settings.convergence
        }
    }

    /// Working grid for the depth field and inverse map (longer side).
    static let workingMaximumSide = 960
    /// Upper bound on |dS/du| from depth ramps; the remainder of the
    /// contraction budget is reserved for the edge fade.
    static let rampContraction: Float = 0.6
    /// Edge fade contributes at most 1 / edgeFadeFactor to |dS/du|.
    static let edgeFadeFactor: Float = 4

    private static let logger = Logger(subsystem: "com.lingganua.prismxr", category: "realtime3D")

    private struct SourceLayout: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let isRGBA: Bool
        let planeFormats: [MTLPixelFormat]
    }

    private let gpu: LSRealtimeStereoGPU
    /// 按模型解析估计器（进程缓存，切换不重载）。
    private let depthEstimatorResolver: @Sendable (LSRealtimeDepthModel) -> LSRealtimeDepthEstimator
    /// 当前模型与它的估计器；模型切换时重建模型相关资源并作废在途推理。
    private var depthModel: LSRealtimeDepthModel
    private var depthEstimator: LSRealtimeDepthEstimator
    private let textureCache: CVMetalTextureCache
    private let analysisState: MTLBuffer
    private let cutState: MTLBuffer

    private var layout: SourceLayout?
    /// 首次 prepareResources 会按当前模型重算；默认值取默认模型的输入尺寸。
    private var contentRect = SIMD4<Float>(0, 0, Float(LSRealtimeDepthModel.default.inputWidth),
                                           Float(LSRealtimeDepthModel.default.inputHeight))
    private var workingSize = (width: 0, height: 0)
    /// 当前工作网格长边（换方案时网格尺寸变，需要重建深度纹理）。
    private var appliedWorkingSide = 0
    /// 最近一次渲染/预取用的方案（模型切换时的缓冲重建要用同一个网格尺度）。
    private var currentScheme: LSRealtimeStereoScheme = .default
    private var modelInputs: [CVPixelBuffer] = []
    private var modelInputTextures: [MTLTexture] = []
    private var modelInputBackings: [CVMetalTexture] = []
    private var depthOutput: CVPixelBuffer?
    private var normalizedDepth: [MTLTexture] = []
    private var workingDepth: MTLTexture?
    private var dilatedDepth: MTLTexture?
    private var offsets: MTLTexture?
    /// 可见性 gather + 牛顿精修的产物；不用精修时为 nil（warp 直接读 offsets）。
    private var refinedOffsets: MTLTexture?
    /// 最近一次深度发布（normalizedDepth[slot] 配它自己的低分辨率引导
    /// modelInputTextures[slot]），带源帧时间。投递线程只读，推理线程写完才
    /// 发布；乒乓两个槽保证“写的”永远不是投递正在读的那个。投递帧按时间取用
    /// 不晚于自己的最新一份，绝不把未来帧的深度贴到过去的画面上。
    private var publishedSlot = -1
    private var publishedSourceTime = 0.0
    private var publishedGeneration: UInt64 = 0
    private var publishedUpdateCount: UInt64 = 0
    /// 上一份发布（另一个乒乓槽），用于“本帧的深度还没算完”时回退。
    private var previousPublication: (slot: Int, sourceTime: Double, updateCount: UInt64)?
    /// seek / 换布局 / 停止后自增：在途推理的结果属于旧时间线，发布前丢弃。
    private var depthGeneration: UInt64 = 0
    /// 只在投递线程（帧队列）读写。
    private var forceReset = true
    /// 已提交给深度管线的最大源帧时间。预取超前于转换，所以转换时同一帧不再
    /// 重复提交（重复提交会让深度线程做两倍工作，还会让发布乱序——快速模型上
    /// 实测表现为投递选到旧一帧的深度）。
    private var lastSubmittedDepthTime = -Double.infinity
    /// 深度速率上限用：上一次真正入队推理的时刻（同步推理不计）。
    private var lastDepthSubmissionInstant: ContinuousClock.Instant?
    /// 上一次预测的源帧时间（两级切镜的时间常数用）。受 depthState 保护。
    private var lastPredictionSourceTime: Double?
    /// 最近若干次推理的耗时（秒）与治理后的深度速率上限（方案 5）。受 depthState 保护。
    private var recentInferenceSeconds: [Double] = []
    private var governedDepthCap: Double = 0
    private var framesSinceDepthUpdate = 0
    private var observedDepthStride = 1
    private var lastAppliedUpdateCount: UInt64 = 0
    private var inferenceSeconds: Double?
    private var synthesisSeconds: Double?
    private var frameInterval: Double?
    private var lastPresentationTime: Double?
    private var reportedDepthFailure = false
    /// Range 平滑：Quest 用 150 ms 真实时间常数；实验过 0.18 每张固定混合，
    /// 后者会随 map 速率变化（20/s 档比 60/s 档慢 3 倍）。
    private var lastAnalyzeSourceTime: Double?
    /// 深度速率治理的失败记忆/退避（Quest 的 governor 语义，见 recordInference）。
    private var governorFailedCeiling: Double = .infinity
    private var governorHoldUntil: ContinuousClock.Instant?
    private var governorLastChange: ContinuousClock.Instant?
    private var governorBackoffSeconds: Double = 30
    private var governorRaisedSinceCut = false

    /// 深度推理独立队列与它的“最新一帧”请求槽：投递线程提交后立刻返回，
    /// 推理线程自己做模型输入、Core ML 推理、统计归一化，完成后发布深度。
    /// 同一时刻最多一个在跑 + 一个排队——新请求取消还没开跑的那个，所以慢
    /// 设备上不会积压，永远在算最新一帧。
    private let depthQueue = DispatchQueue(label: "com.prismxr.realtime3D.depth", qos: .userInitiated)
    private let depthState = NSLock()
    /// 排队中（还没开跑）的推理，按提交顺序。深度管线比内容帧率慢是常态
    /// （60fps 片源 vs 约 33 次/秒推理），所以按“先进先出 + 超量丢最旧”处理：
    /// 后进的帧深度不会挤掉先进帧的，投递侧按帧取用即可对上画面。
    private var queuedDepthWork: [DispatchWorkItem] = []
    /// 排队上限。上限越大预取越深、越能抵消推理耗时，但深度离画面越远。
    private static let maximumQueuedDepthRequests = 3
    /// 离线工具与测试：逐帧同步推理（同帧深度），不启用异步管线。
    private let prefersSynchronousDepth: Bool

    /// 一帧的异步推理请求。持有 CVPixelBuffer 本身，推理期间 IOSurface 不会
    /// 被解码器的缓冲池回收；纹理绑定是投递线程上已经建好的那几个（只读）。
    private struct DepthRequest {
        let generation: UInt64
        let source: CVPixelBuffer
        let sourceTime: Double
        let planes: [TextureBinding]
        let color: LSRealtimeStereoColorParams
        let isRGBA: Bool
        let contentRect: SIMD4<Float>
        /// 提交这一帧时用的方案（决定切镜判定与时间常数）。
        let scheme: LSRealtimeStereoScheme
        /// 深度速率上限（maps/s，0 = 不限）。
        let depthRateCap: Double
    }

    /// 投递线程为该帧选中的深度：`ageFrames` = 深度源帧比这一帧早/晚多少帧
    /// （0 = 同帧深度，正数 = 深度比画面旧，负数 = 用了更晚帧的深度）。
    private struct PublishedDepth {
        var slot = -1
        var valid = false
        var updateCount: UInt64 = 0
        var ageFrames = 0
    }

    /// 固定单个估计器（离线工具与测试用；模型切换会一直解析到同一个实例）。
    convenience init(gpu: LSRealtimeStereoGPU, depthEstimator: LSRealtimeDepthEstimator,
                     prefersSynchronousDepth: Bool = false) throws {
        try self.init(gpu: gpu,
                      depthEstimatorResolver: { _ in depthEstimator },
                      initialModel: depthEstimator.model,
                      prefersSynchronousDepth: prefersSynchronousDepth)
    }

    init(gpu: LSRealtimeStereoGPU,
         depthEstimatorResolver: @escaping @Sendable (LSRealtimeDepthModel) -> LSRealtimeDepthEstimator,
         initialModel: LSRealtimeDepthModel = .default,
         prefersSynchronousDepth: Bool = false) throws {
        self.gpu = gpu
        self.depthEstimatorResolver = depthEstimatorResolver
        self.depthModel = initialModel
        self.depthEstimator = depthEstimatorResolver(initialModel)
        self.prefersSynchronousDepth = prefersSynchronousDepth
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            gpu.device,
            [kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary,
            &cache
        )
        guard status == kCVReturnSuccess, let cache else { throw RenderError.textureCache(status) }
        textureCache = cache
        guard let buffer = gpu.device.makeBuffer(
            length: MemoryLayout<LSRealtimeStereoAnalysisState>.stride,
            options: .storageModeShared
        ) else {
            throw RenderError.commandBuffer
        }
        analysisState = buffer
        analysisState.contents().storeBytes(of: LSRealtimeStereoAnalysisState(), as: LSRealtimeStereoAnalysisState.self)
        guard let cutBuffer = gpu.device.makeBuffer(
            length: LSRealtimeStereoCutStateLayout.byteCount,
            options: .storageModeShared
        ) else {
            throw RenderError.commandBuffer
        }
        cutBuffer.label = "Real-time 3D cut state"
        memset(cutBuffer.contents(), 0, LSRealtimeStereoCutStateLayout.byteCount)
        cutState = cutBuffer
    }

    /// Seek, flush or a new item: drop all depth and temporal state so the
    /// next frame is converted from its own prediction only.
    func reset() {
        depthState.withLock {
            // 在途推理属于旧时间线：换代次后它的发布会被丢弃（分析状态随后由
            // 同步推理的 forceReset 覆盖）。
            depthGeneration &+= 1
            publishedSlot = -1
            previousPublication = nil
            for work in queuedDepthWork { work.cancel() }
            queuedDepthWork.removeAll()
        }
        forceReset = true
        lastSubmittedDepthTime = -Double.infinity
        lastDepthSubmissionInstant = nil
        depthState.withLock {
            lastPredictionSourceTime = nil
            recentInferenceSeconds.removeAll()
            governedDepthCap = 0
        }
        framesSinceDepthUpdate = 0
        lastAppliedUpdateCount = 0
        observedDepthStride = 1
        lastPresentationTime = nil
        depthState.withLock {
            lastAnalyzeSourceTime = nil
            governorFailedCeiling = .infinity
            governorHoldUntil = nil
            governorLastChange = nil
            governorBackoffSeconds = 30
            governorRaisedSinceCut = false
        }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Writes the left/right eye views of `source` into `left` and `right`,
    /// which must share the source's size and pixel format.
    @discardableResult
    func render(
        source: CVPixelBuffer,
        left: CVPixelBuffer,
        right: CVPixelBuffer,
        settings: LSRealtime3DSettings,
        timing: FrameTiming
    ) throws -> Report {
        let sourceLayout = try Self.layout(of: source)
        try adoptModelIfNeeded(settings.model, for: sourceLayout)
        currentScheme = settings.scheme
        try prepareResources(for: sourceLayout, scheme: settings.scheme)
        updateFrameInterval(timing)

        let geometry = Geometry(settings: settings)
        let scheme = settings.scheme
        let wantsDepth = geometry.amplitude > 0.000_01
        let modelReady = wantsDepth && depthEstimator.prepare()

        let sourcePlanes = try planeTextures(source, layout: sourceLayout)
        let leftPlanes = try planeTextures(left, layout: sourceLayout)
        let rightPlanes = try planeTextures(right, layout: sourceLayout)
        let color = Self.colorParams(for: source, layout: sourceLayout)

        // 同步推理只发生在没有帧率压力的时刻：首帧 / seek 后第一帧 / 换布局后
        // （还没有任何可用深度，起播不能先平后立体）、暂停与拖动的静帧（静帧要
        // 的是本帧自己的深度），以及离线工具与测试要求的逐帧同帧深度。播放中的
        // 帧一律只提交异步请求：投递线程绝不等推理，每帧只做 GPU 重采样。
        var published = depthForFrame(at: timing.presentationTime)
        let requiresSynchronousDepth = prefersSynchronousDepth || forceReset
            || timing.isStill || !published.valid
        var inferred = false
        var frameInferenceSeconds: Double?
        if modelReady && requiresSynchronousDepth {
            let started = ContinuousClock.now
            do {
                let slot = drainDepthPipelineForSynchronousPrediction()
                try runInference(sourcePlanes: sourcePlanes, color: color,
                                 isRGBA: sourceLayout.isRGBA, slot: slot)
                publishDepth(slot: slot, generation: currentDepthGeneration(),
                             sourceTime: timing.presentationTime)
                published = depthForFrame(at: timing.presentationTime)
                inferred = true
                let elapsed = started.duration(to: .now).seconds
                frameInferenceSeconds = elapsed
                inferenceSeconds = Self.blend(inferenceSeconds, elapsed)
                reportedDepthFailure = false
                recordInference(
                    seconds: elapsed,
                    scheme: scheme,
                    cap: effectiveDepthRateCap(for: scheme, settings: settings)
                )
            } catch {
                // A failed prediction must not freeze playback: keep the last
                // valid depth (or zero parallax) and try again next frame.
                if !reportedDepthFailure {
                    reportedDepthFailure = true
                    Self.logger.error("Depth inference failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else if modelReady {
            submitDepthRequest(
                source: source,
                sourceTime: timing.presentationTime,
                planes: sourcePlanes,
                color: color,
                layout: sourceLayout,
                scheme: scheme,
                depthRateCap: effectiveDepthRateCap(for: scheme, settings: settings)
            )
        }

        let hasDepthField = wantsDepth && published.valid
        // 统计两次用上新深度之间隔了几帧（= 实际复用间隔），报告与调参用。
        if hasDepthField {
            if published.updateCount != lastAppliedUpdateCount {
                observedDepthStride = framesSinceDepthUpdate + 1
                framesSinceDepthUpdate = 0
                lastAppliedUpdateCount = published.updateCount
            } else {
                framesSinceDepthUpdate += 1
            }
        }

        let synthesisStarted = ContinuousClock.now
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw RenderError.commandBuffer }
        commandBuffer.label = "Real-time 3D synthesis"
        if inferred {
            try encodeAnalysis(commandBuffer, slot: published.slot, forceReset: forceReset,
                               scheme: scheme, sourceTime: timing.presentationTime)
            forceReset = false
        }
        let usesGather = scheme.usesVisibilityGather
        let stereo = stereoParams(geometry: geometry, enabled: hasDepthField, scheme: scheme)
        var warpOffsets: MTLTexture?
        if hasDepthField {
            try encodeDepthField(commandBuffer, sourcePlanes: sourcePlanes, color: color,
                                 isRGBA: sourceLayout.isRGBA, stereo: stereo, slot: published.slot,
                                 dilate: !usesGather)
        }
        if hasDepthField && usesGather {
            try encodeGather(commandBuffer, stereo: stereo)
            if stereo.refineSteps > 0 {
                try encodeRefine(commandBuffer, stereo: stereo)
                warpOffsets = refinedOffsets
            } else {
                warpOffsets = offsets
            }
        } else {
            // 老链路；或没有可用深度（零视差）时统一走固定点逆映射，输出零位移。
            try encodeInverseMap(commandBuffer, stereo: stereo)
            warpOffsets = offsets
        }
        for plane in sourcePlanes.indices {
            try encodeWarp(commandBuffer, source: sourcePlanes[plane].texture,
                           left: leftPlanes[plane].texture, right: rightPlanes[plane].texture,
                           offsets: warpOffsets)
        }

        // Keep textures alive until the GPU finishes. Measure synthesis time
        // asynchronously so the caller doesn't block.
        let capturedTextures = (sourcePlanes, leftPlanes, rightPlanes)
        let capturedCache = textureCache
        commandBuffer.addCompletedHandler { [weak self] buffer in
            if let error = buffer.error {
                Self.logger.error("实时 3D GPU 执行失败：\(error.localizedDescription, privacy: .public)")
            }
            let elapsed = synthesisStarted.duration(to: .now).seconds
            self?.synthesisSeconds = Self.blend(self?.synthesisSeconds, elapsed)
            withExtendedLifetime(capturedTextures) {}
            CVMetalTextureCacheFlush(capturedCache, 0)
        }
        commandBuffer.commit()

        // Estimate synthesis time from the GPU schedule, not the actual completion.
        let frameSynthesisSeconds = synthesisStarted.duration(to: .now).seconds
        return Report(inferredDepth: inferred, hasDepth: hasDepthField, depthStride: observedDepthStride,
                      inferenceSeconds: frameInferenceSeconds, synthesisSeconds: frameSynthesisSeconds,
                      depthAgeFrames: hasDepthField ? published.ageFrames : 0)
    }

    // MARK: - Inspection (tests and offline tools)

    struct DebugTextures {
        /// 模型输入（也是双边上采样的引导图）：518×392 或 768×416 的显示参考 sRGB。
        let modelInput: MTLTexture?
        let normalized: MTLTexture?
        let working: MTLTexture?
        let dilated: MTLTexture?
        let offsets: MTLTexture?
    }

    /// 最新一份已发布深度（测试与离线工具读纹理/深度图用，不做按帧选择）。
    private func latestPublishedDepth() -> PublishedDepth {
        depthState.withLock {
            guard publishedGeneration == depthGeneration, publishedSlot >= 0 else { return PublishedDepth() }
            return PublishedDepth(slot: publishedSlot, valid: true,
                                  updateCount: publishedUpdateCount, ageFrames: 0)
        }
    }

    func debugTextures() -> DebugTextures {
        let published = latestPublishedDepth()
        return DebugTextures(
            modelInput: modelInputTextures.indices.contains(max(published.slot, 0))
                ? modelInputTextures[max(published.slot, 0)] : nil,
            normalized: published.valid ? normalizedDepth[published.slot] : nil,
            working: workingDepth,
            dilated: dilatedDepth,
            offsets: offsets
        )
    }

    func debugAnalysis() -> LSRealtimeStereoAnalysisState {
        analysisState.contents().load(as: LSRealtimeStereoAnalysisState.self)
    }

    // MARK: - Scheduling

    // MARK: - 深度管线（异步推理）

    /// 为某个投递帧挑选深度：优先“源帧时间不晚于本帧”的最新一份（对得上画面），
    /// 没有再退回最新发布（起播早期只有晚于本帧的那一份）。
    private func depthForFrame(at presentationTime: Double) -> PublishedDepth {
        depthState.withLock {
            guard publishedGeneration == depthGeneration else { return PublishedDepth() }
            // 两槽里挑离本帧最近的一份：模型快时管线会跑到画面之前（晚一帧），
            // 模型慢时落在画面之后（早一帧/更多），取最近的那份误差最小。
            var candidates: [(slot: Int, sourceTime: Double, updateCount: UInt64)] = []
            if publishedSlot >= 0 {
                candidates.append((publishedSlot, publishedSourceTime, publishedUpdateCount))
            }
            if let previousPublication {
                candidates.append(previousPublication)
            }
            let chosen = candidates.min {
                abs($0.sourceTime - presentationTime) < abs($1.sourceTime - presentationTime)
            }
            guard let chosen else { return PublishedDepth() }
            let age: Int
            if let interval = frameInterval, interval > 0, presentationTime.isFinite,
               chosen.sourceTime.isFinite {
                // 大数（工具读“最新一份”时用极大值）先夹住再转 Int：Double→Int
                // 越界是运行时陷阱。
                let raw = ((presentationTime - chosen.sourceTime) / interval).rounded()
                age = raw.isFinite ? Int(min(max(raw, -10_000), 10_000)) : 0
            } else {
                // 还没测出帧间隔：时差没有意义。
                age = 0
            }
            return PublishedDepth(slot: chosen.slot, valid: true,
                                  updateCount: chosen.updateCount, ageFrames: age)
        }
    }

    private func currentDepthGeneration() -> UInt64 {
        depthState.withLock { depthGeneration }
    }

    /// 推理线程上执行一帧：模型输入（GPU）→ Core ML → 统计归一化（GPU）→ 发布。
    /// 全程只碰自己的乒乓槽与共享分析状态，不碰投递线程的状态。
    private func runDepthPipeline(_ request: DepthRequest) {
        guard request.generation == currentDepthGeneration() else { return }
        let started = ContinuousClock.now
        let slot = nextWriteSlot()
        do {
            try encodeModelInput(planes: request.planes, color: request.color,
                                 isRGBA: request.isRGBA, contentRect: request.contentRect, slot: slot)
            guard let depthOutput else { throw RenderError.commandBuffer }
            let depth = try depthEstimator.predict(input: modelInputs[slot], output: depthOutput)
            if depth !== depthOutput {
                try Self.copyPixels(from: depth, to: depthOutput)
            }
            guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw RenderError.commandBuffer }
            commandBuffer.label = "Real-time 3D depth statistics (async)"
            try encodeAnalysis(commandBuffer, slot: slot, forceReset: false,
                               scheme: request.scheme, sourceTime: request.sourceTime)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw RenderError.gpu(error.localizedDescription) }
            // 做完这一帧期间可能已经 seek / 换布局：结果属于旧时间线，丢弃。
            guard request.generation == currentDepthGeneration() else { return }
            publishDepth(slot: slot, generation: request.generation, sourceTime: request.sourceTime)
            recordInference(
                seconds: started.duration(to: .now).seconds,
                scheme: request.scheme,
                cap: request.depthRateCap
            )
        } catch {
            // 失败不阻塞播放：投递侧继续用上一份深度（或零视差），下一帧还会再试。
            depthState.withLock {
                if !reportedDepthFailure {
                    reportedDepthFailure = true
                    Self.logger.error("Depth inference failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// 投递线程调用（帧队列上）：把这一帧交给推理线程，立即返回。同一时刻
    /// 一个在跑、其余排队（上限 `maximumQueuedDepthRequests`，超量的丢最旧——
    /// 那些帧早就转换过了，算了也用不上）。
    private func submitDepthRequest(
        source: CVPixelBuffer,
        sourceTime: Double,
        planes: [TextureBinding],
        color: LSRealtimeStereoColorParams,
        layout: SourceLayout,
        scheme: LSRealtimeStereoScheme,
        depthRateCap: Double
    ) {
        let request = DepthRequest(
            generation: currentDepthGeneration(),
            source: source,
            sourceTime: sourceTime,
            planes: planes,
            color: color,
            isRGBA: layout.isRGBA,
            contentRect: contentRect,
            scheme: scheme,
            depthRateCap: depthRateCap
        )
        enqueueDepthRequest(request)
    }

    private func enqueueDepthRequest(_ request: DepthRequest) {
        guard request.sourceTime > lastSubmittedDepthTime else { return }
        // 深度速率上限（方案 3/5）：超过上限周期的请求直接丢，投递帧继续用已有
        // 深度（按源帧时间选取）。首帧 / seek 后第一帧 / 静帧的同步推理不走这里。
        if let lastInstant = lastDepthSubmissionInstant,
           !LSRealtimeStereoScheme.depthSubmissionDue(
               elapsed: (ContinuousClock.now - lastInstant).seconds,
               capPerSecond: submissionGateCap(for: request.depthRateCap)
           ) {
            return
        }
        lastDepthSubmissionInstant = .now
        lastSubmittedDepthTime = request.sourceTime
        depthState.withLock {
            while queuedDepthWork.count >= Self.maximumQueuedDepthRequests {
                queuedDepthWork.removeFirst().cancel()
            }
            let work = DispatchWorkItem { [weak self] in
                self?.runDepthPipeline(request)
            }
            queuedDepthWork.append(work)
            depthQueue.async(execute: work)
        }
    }

    /// 预取一帧的深度：在真正转换这一帧之前调用（投递侧提前几帧拉帧），
    /// 把推理耗时藏进投递提前量里——画面变化后 3D 不必等一个推理周期才跟上。
    /// 与 `render` 共用同一套排队与发布规则，重复提交同一帧无害。
    func prefetchDepth(
        source: CVPixelBuffer,
        presentationTime: Double,
        settings: LSRealtime3DSettings
    ) {
        guard Geometry(settings: settings).amplitude > 0.000_01,
              presentationTime.isFinite,
              let sourceLayout = try? Self.layout(of: source),
              (try? adoptModelIfNeeded(settings.model, for: sourceLayout)) != nil,
              (try? prepareResources(for: sourceLayout, scheme: settings.scheme)) != nil,
              depthEstimator.prepare(),
              let planes = try? planeTextures(source, layout: sourceLayout) else { return }
        enqueueDepthRequest(DepthRequest(
            generation: currentDepthGeneration(),
            source: source,
            sourceTime: presentationTime,
            planes: planes,
            color: Self.colorParams(for: source, layout: sourceLayout),
            isRGBA: sourceLayout.isRGBA,
            contentRect: contentRect,
            scheme: settings.scheme,
            depthRateCap: effectiveDepthRateCap(for: settings.scheme, settings: settings)
        ))
    }

    /// Drains the depth queue before model/working-grid resources are rebuilt.
    /// runDepthPipeline can still be touching modelInputs/textures when a model
    /// or scheme switch arrives; the generation bump alone only stops the next
    /// publish, not an in-flight array read.
    private func drainDepthQueueForResourceRebuild() {
        depthState.withLock {
            for work in queuedDepthWork { work.cancel() }
            queuedDepthWork.removeAll()
        }
        depthQueue.sync {}
    }

    /// 同步推理前把异步管线排空（在跑的推理最多 ~30ms），之后投递线程独占
    /// 模型输入/输出缓冲与乒乓槽。返回本次要写的槽。
    private func drainDepthPipelineForSynchronousPrediction() -> Int {
        depthState.withLock {
            for work in queuedDepthWork { work.cancel() }
            queuedDepthWork.removeAll()
        }
        depthQueue.sync {}
        return nextWriteSlot()
    }

    /// 记录一次推理耗时；走治理的方案按它调整深度速率上限。Quest 的 governor
    /// 看显示预算，我们看推理预算；这里补上他们的失败记忆/退避语义：削减后
    /// 至少保持 10 s，恢复要稳定满一个退避窗口（初始 30 s，恢复失败后翻倍，
    /// 上限 300 s），且回升上限不超过失败值的一半。
    private func recordInference(seconds: Double, scheme: LSRealtimeStereoScheme, cap: Double) {
        // `cap` is the configured (scheme/override) ceiling, not the currently
        // gated value; using the gated value here made every recovery propose
        // no change and permanently pin the rate after one cut.
        depthState.withLock {
            recentInferenceSeconds.append(seconds)
            if recentInferenceSeconds.count > 16 {
                recentInferenceSeconds.removeFirst()
            }
            guard scheme.usesDepthRateGovernor, cap > 0,
                  recentInferenceSeconds.count >= 8 else { return }
            let now = ContinuousClock.now
            if let holdUntil = governorHoldUntil, now < holdUntil { return }
            let base = governedDepthCap > 0 ? governedDepthCap : cap
            let proposed = LSRealtimeStereoScheme.governedDepthRate(
                current: base, schemeCap: cap, recentSeconds: recentInferenceSeconds
            )
            guard abs(proposed - base) > 0.0001 else { return }

            if proposed < base {
                // Cut: remember the target that failed; recovery may not exceed
                // half of it, and a repeat failure doubles the recovery window.
                governorFailedCeiling = min(governorFailedCeiling, max(proposed * 2, 5))
                if governorRaisedSinceCut {
                    governorBackoffSeconds = min(governorBackoffSeconds * 2, 300)
                }
                governorRaisedSinceCut = false
                governorHoldUntil = now + .seconds(10)
                governorLastChange = now
                governedDepthCap = proposed
            } else {
                if let lastChange = governorLastChange,
                   (now - lastChange).seconds < governorBackoffSeconds {
                    return
                }
                let raised = min(proposed, cap, governorFailedCeiling)
                guard raised > base else { return }
                governedDepthCap = raised
                governorRaisedSinceCut = true
                governorLastChange = now
                governorHoldUntil = now + .seconds(10)
                if raised >= cap {
                    governorBackoffSeconds = 30
                    governorFailedCeiling = .infinity
                }
            }
        }
    }

    /// 配置的速率上限（用户覆盖优先，否则方案默认；0 = 不限）。
    private func effectiveDepthRateCap(for scheme: LSRealtimeStereoScheme,
                                       settings: LSRealtime3DSettings) -> Double {
        settings.effectiveDepthRateCap
    }

    /// 实际提交门限：治理方案叠加治理后的上限。用户选择不限速时清掉治理值，
    /// 避免旧的上限把提交永久卡住。
    private func submissionGateCap(for requestCap: Double) -> Double {
        guard requestCap > 0 else {
            depthState.withLock { governedDepthCap = 0 }
            return 0
        }
        let governed = depthState.withLock { governedDepthCap }
        return governed > 0 ? min(governed, requestCap) : requestCap
    }

    /// 真实时间一阶平均的权重：α = 1 − e^(−dt/τ)，dt 是两次预测的源帧时间差，
    /// 夹到他们的 [1/60 s, 1 s]。τ 由方案给（老链路不用）。
    private func temporalAlpha(sourceTime: Double, tau: Double) -> Float {
        let previous = depthState.withLock { () -> Double? in
            let prior = lastPredictionSourceTime
            lastPredictionSourceTime = sourceTime
            return prior
        }
        let dt = previous.map { min(max(sourceTime - $0, 1.0 / 60.0), 1.0) } ?? (1.0 / 60.0)
        return LSRealtimeStereoScheme.temporalAlpha(dt: dt, tau: tau)
    }

    /// 当前代的写槽 = 已发布槽的对侧：推理写的永远不是投递正在读的那个。
    private func nextWriteSlot() -> Int {
        depthState.withLock { publishedSlot == 0 ? 1 : 0 }
    }

    /// 当前队列里等待推理的帧数（测试与诊断用）。
    var debugQueuedDepthCount: Int {
        depthState.withLock { queuedDepthWork.count }
    }

    private func publishDepth(slot: Int, generation: UInt64, sourceTime: Double) {
        depthState.withLock {
            guard generation == depthGeneration else { return }
            if publishedSlot >= 0 {
                previousPublication = (publishedSlot, publishedSourceTime, publishedUpdateCount)
            }
            publishedSlot = slot
            publishedSourceTime = sourceTime
            publishedGeneration = generation
            publishedUpdateCount &+= 1
        }
    }

    /// 测试与离线工具：等已经提交的异步推理全部结束。
    func waitForDepthPipeline() {
        depthQueue.sync {}
    }

    private func updateFrameInterval(_ timing: FrameTiming) {
        defer { lastPresentationTime = timing.presentationTime }
        if let duration = timing.duration, duration.isFinite, duration > 0.004, duration < 0.2 {
            frameInterval = duration
            return
        }
        guard let last = lastPresentationTime else { return }
        let delta = timing.presentationTime - last
        guard delta > 0.004, delta < 0.2 else { return }
        frameInterval = Self.blend(frameInterval, delta)
    }

    private static func blend(_ current: Double?, _ sample: Double) -> Double {
        guard let current else { return sample }
        return current * 0.8 + sample * 0.2
    }

    // MARK: - Passes

    /// 同步推理（投递线程）：首帧 / seek 后第一帧 / 静帧 / 离线工具与测试。
    /// 播放中的帧走 `submitDepthRequest`，允许在这里等推理的只有这些没有帧率
    /// 压力的时刻。
    private func runInference(sourcePlanes: [TextureBinding], color: LSRealtimeStereoColorParams,
                              isRGBA: Bool, slot: Int) throws {
        guard let depthOutput else { throw RenderError.commandBuffer }
        try encodeModelInput(planes: sourcePlanes, color: color, isRGBA: isRGBA,
                             contentRect: contentRect, slot: slot)
        let depth = try depthEstimator.predict(input: modelInputs[slot], output: depthOutput)
        if depth !== depthOutput {
            try Self.copyPixels(from: depth, to: depthOutput)
        }
    }

    /// 模型输入 pass：源帧 → 模型输入尺寸的显示参考 sRGB。Core ML 要读这块 IOSurface，
    /// 所以提交后必须等 GPU 完成（这一步只在推理侧等待，投递线程不走这里）。
    private func encodeModelInput(planes: [TextureBinding], color: LSRealtimeStereoColorParams,
                                  isRGBA: Bool, contentRect: SIMD4<Float>, slot: Int) throws {
        guard let commandBuffer = gpu.queue.makeCommandBuffer() else { throw RenderError.commandBuffer }
        commandBuffer.label = "Real-time 3D model input"
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError.commandBuffer }
        let target = modelInputTextures[slot]
        encoder.setComputePipelineState(isRGBA ? gpu.prepareRGBA : gpu.prepareYCbCr)
        encoder.setTexture(planes[0].texture, index: 0)
        encoder.setTexture(planes.count > 1 ? planes[1].texture : planes[0].texture, index: 1)
        encoder.setTexture(target, index: 2)
        var colorParams = color
        encoder.setBytes(&colorParams, length: MemoryLayout<LSRealtimeStereoColorParams>.stride, index: 0)
        let sourceWidth = Float(planes[0].texture.width)
        let sourceHeight = Float(planes[0].texture.height)
        var prepare = LSRealtimeStereoPrepareParams(
            contentRect: contentRect,
            taps: SIMD2(
                UInt32(min(max((sourceWidth / contentRect.z / 2).rounded(.up), 1), 6)),
                UInt32(min(max((sourceHeight / contentRect.w / 2).rounded(.up), 1), 6))
            )
        )
        encoder.setBytes(&prepare, length: MemoryLayout<LSRealtimeStereoPrepareParams>.stride, index: 1)
        dispatch(encoder, pipeline: isRGBA ? gpu.prepareRGBA : gpu.prepareYCbCr, width: target.width, height: target.height)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error { throw RenderError.gpu(error.localizedDescription) }
    }

    private func encodeAnalysis(_ commandBuffer: MTLCommandBuffer, slot: Int, forceReset: Bool,
                                scheme: LSRealtimeStereoScheme, sourceTime: Double) throws {
        guard let depthOutput else { throw RenderError.commandBuffer }
        let rawDepth = try texture(for: depthOutput, plane: 0, format: .r16Float)
        let previous = 1 - slot
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError.commandBuffer }
        encoder.label = "Real-time 3D depth statistics"
        encoder.setComputePipelineState(gpu.analyze)
        encoder.setTexture(rawDepth.texture, index: 0)
        encoder.setTexture(modelInputTextures[slot], index: 1)
        encoder.setTexture(modelInputTextures[previous], index: 2)
        encoder.setBuffer(analysisState, offset: 0, index: 0)
        // Range 平滑用 Quest 的 150 ms 真实时间常数，而不是每张图固定 0.18：
        // 后者让同一个设置在 20/s 档比 60/s 档慢三倍，pan 时整体"呼吸"会随档位变化。
        let rangeSmoothing: Float = {
            guard !forceReset else { return 1 }
            return depthState.withLock {
                guard let previous = lastAnalyzeSourceTime else {
                    lastAnalyzeSourceTime = sourceTime
                    return 1
                }
                lastAnalyzeSourceTime = sourceTime
                let dt = min(max(sourceTime - previous, 1.0 / 60.0), 1.0)
                return LSRealtimeStereoScheme.temporalAlpha(dt: dt, tau: 0.150)
            }
        }()
        var params = LSRealtimeStereoAnalyzeParams(
            contentRect: SIMD4<Int32>(
                Int32(contentRect.x.rounded()), Int32(contentRect.y.rounded()),
                Int32(contentRect.z.rounded()), Int32(contentRect.w.rounded())
            ),
            forceReset: forceReset ? 1 : 0,
            cutThreshold: 0.09,
            minimumRange: 0.3,
            smoothing: rangeSmoothing,
            flags: scheme.usesTwoStageCut ? LSRealtimeStereoAnalyzeParams.twoStageCutFlag : 0
        )
        encoder.setBytes(&params, length: MemoryLayout<LSRealtimeStereoAnalyzeParams>.stride, index: 1)
        var cutParams = LSRealtimeStereoCutParams.moonlightDefaults
        encoder.setBytes(&cutParams, length: MemoryLayout<LSRealtimeStereoCutParams>.stride, index: 2)
        encoder.setBuffer(cutState, offset: 0, index: 3)
        var threads = min(1024, gpu.analyze.maxTotalThreadsPerThreadgroup)
        threads = 1 << (Int.bitWidth - 1 - threads.leadingZeroBitCount)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))

        encoder.setComputePipelineState(gpu.normalize)
        encoder.setTexture(rawDepth.texture, index: 0)
        encoder.setTexture(modelInputTextures[slot], index: 1)
        encoder.setTexture(modelInputTextures[previous], index: 2)
        encoder.setTexture(normalizedDepth[previous], index: 3)
        encoder.setTexture(normalizedDepth[slot], index: 4)
        encoder.setBuffer(analysisState, offset: 0, index: 0)
        var normalizeParams = LSRealtimeStereoNormalizeParams(
            temporalAlpha: scheme.temporalTauSeconds > 0
                ? temporalAlpha(sourceTime: sourceTime, tau: scheme.temporalTauSeconds)
                : 1,
            changeSigma: 0.025,
            flags: scheme.temporalTauSeconds > 0 ? LSRealtimeStereoNormalizeParams.timeTauFlag : 0
        )
        encoder.setBytes(&normalizeParams, length: MemoryLayout<LSRealtimeStereoNormalizeParams>.stride, index: 1)
        dispatch(encoder, pipeline: gpu.normalize, width: normalizedDepth[slot].width,
                 height: normalizedDepth[slot].height)
        encoder.endEncoding()
        withExtendedLifetime(rawDepth) {}
        // 发布由调用方完成：同步路径在 render() 里、异步路径在 runDepthPipeline 里。
    }

    private func encodeDepthField(
        _ commandBuffer: MTLCommandBuffer,
        sourcePlanes: [TextureBinding],
        color: LSRealtimeStereoColorParams,
        isRGBA: Bool,
        stereo: LSRealtimeStereoParams,
        slot: Int,
        dilate: Bool
    ) throws {
        guard let workingDepth, let dilatedDepth,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBuffer
        }
        encoder.label = "Real-time 3D depth field"
        let upsample = isRGBA ? gpu.upsampleRGBA : gpu.upsampleYCbCr
        encoder.setComputePipelineState(upsample)
        encoder.setTexture(sourcePlanes[0].texture, index: 0)
        encoder.setTexture(sourcePlanes.count > 1 ? sourcePlanes[1].texture : sourcePlanes[0].texture, index: 1)
        encoder.setTexture(normalizedDepth[slot], index: 2)
        encoder.setTexture(modelInputTextures[slot], index: 3)
        encoder.setTexture(workingDepth, index: 4)
        var colorParams = color
        encoder.setBytes(&colorParams, length: MemoryLayout<LSRealtimeStereoColorParams>.stride, index: 0)
        var upsampleParams = LSRealtimeStereoUpsampleParams(
            contentRect: contentRect,
            footprint: SIMD2(1 / Float(workingDepth.width), 1 / Float(workingDepth.height)),
            rangeSigma: 0.1,
            spatialSigma: 0.9
        )
        encoder.setBytes(&upsampleParams, length: MemoryLayout<LSRealtimeStereoUpsampleParams>.stride, index: 1)
        encoder.setBuffer(analysisState, offset: 0, index: 2)
        dispatch(encoder, pipeline: upsample, width: workingDepth.width, height: workingDepth.height)

        // 可见性 gather 直接读上采样后的深度（遮挡由求解给出），不做膨胀。
        if dilate {
            encoder.setComputePipelineState(gpu.dilate)
            encoder.setTexture(workingDepth, index: 0)
            encoder.setTexture(dilatedDepth, index: 1)
            var params = stereo
            encoder.setBytes(&params, length: MemoryLayout<LSRealtimeStereoParams>.stride, index: 0)
            dispatch(encoder, pipeline: gpu.dilate, width: dilatedDepth.width, height: dilatedDepth.height)
        }
        encoder.endEncoding()
    }

    private func encodeInverseMap(_ commandBuffer: MTLCommandBuffer, stereo: LSRealtimeStereoParams) throws {
        guard let dilatedDepth, let offsets,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBuffer
        }
        encoder.label = "Real-time 3D inverse map"
        encoder.setComputePipelineState(gpu.inverseMap)
        encoder.setTexture(dilatedDepth, index: 0)
        encoder.setTexture(offsets, index: 1)
        var params = stereo
        encoder.setBytes(&params, length: MemoryLayout<LSRealtimeStereoParams>.stride, index: 0)
        dispatch(encoder, pipeline: gpu.inverseMap, width: offsets.width, height: offsets.height)
        encoder.endEncoding()
    }

    /// 可见性 gather（the 3D pipeline 的求根 + 最近面），输出与固定点逆映射同格式
    /// 的 RG16F 偏移，warp 不用改。
    private func encodeGather(_ commandBuffer: MTLCommandBuffer,
                              stereo: LSRealtimeStereoParams) throws {
        guard let workingDepth, let offsets,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBuffer
        }
        encoder.label = "Real-time 3D visibility gather"
        encoder.setComputePipelineState(gpu.gather)
        encoder.setTexture(workingDepth, index: 0)
        encoder.setTexture(offsets, index: 1)
        var params = stereo
        encoder.setBytes(&params, length: MemoryLayout<LSRealtimeStereoParams>.stride, index: 0)
        dispatch(encoder, pipeline: gpu.gather, width: offsets.width, height: offsets.height)
        encoder.endEncoding()
    }

    /// 两步阻尼牛顿：把 gather 的一个 texel 精度精修到亚 texel。
    private func encodeRefine(_ commandBuffer: MTLCommandBuffer,
                              stereo: LSRealtimeStereoParams) throws {
        guard let offsets, let refinedOffsets,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBuffer
        }
        encoder.label = "Real-time 3D offset refinement"
        encoder.setComputePipelineState(gpu.refine)
        encoder.setTexture(workingDepth, index: 0)
        encoder.setTexture(offsets, index: 1)
        encoder.setTexture(refinedOffsets, index: 2)
        var params = stereo
        encoder.setBytes(&params, length: MemoryLayout<LSRealtimeStereoParams>.stride, index: 0)
        dispatch(encoder, pipeline: gpu.refine, width: refinedOffsets.width, height: refinedOffsets.height)
        encoder.endEncoding()
    }

    private func encodeWarp(_ commandBuffer: MTLCommandBuffer, source: MTLTexture,
                            left: MTLTexture, right: MTLTexture,
                            offsets: MTLTexture?) throws {
        guard let offsets, let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBuffer
        }
        encoder.label = "Real-time 3D eye resample"
        encoder.setComputePipelineState(gpu.warp)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(offsets, index: 1)
        encoder.setTexture(left, index: 2)
        encoder.setTexture(right, index: 3)
        let width = gpu.warp.threadExecutionWidth
        let height = max(gpu.warp.maxTotalThreadsPerThreadgroup / width / 2, 1)
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 2),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
    }

    private func stereoParams(geometry: Geometry, enabled: Bool,
                              scheme: LSRealtimeStereoScheme) -> LSRealtimeStereoParams {
        let flags: UInt32 = scheme.gatherUsesCubicDepthRead ? LSRealtimeStereoParams.cubicDepthFlag : 0
        guard enabled, workingSize.width > 0 else {
            return LSRealtimeStereoParams(amplitude: 0, convergence: 0, slope: 1, radius: 0,
                                          edgeMargin: 1, iterations: 1,
                                          refineSteps: 0, flags: flags)
        }
        let texelsPerDepth = geometry.amplitude * Float(workingSize.width)
        // 到汇聚面的最大深度距离：视差最大处决定搜索半径（他们同式 + 余量）。
        let reachDepth = max(abs(geometry.convergence), abs(1 - geometry.convergence))
        let gatherReach = Int32(min(max((abs(texelsPerDepth) * reachDepth).rounded(.up) + 2, 2), 64))
        let slope = min(Self.rampContraction / max(texelsPerDepth, 0.000_1), 1)
        let radius = scheme.usesVisibilityGather
            ? gatherReach
            : min(Int32((1 / slope).rounded(.up)) + 1, 64)
        return LSRealtimeStereoParams(
            amplitude: geometry.amplitude,
            convergence: geometry.convergence,
            slope: max(slope, 1 / Float(max(radius - 1, 1))),
            radius: radius,
            edgeMargin: max(Self.edgeFadeFactor * geometry.amplitude * reachDepth, 0.000_1),
            iterations: 10,
            refineSteps: enabled && scheme.usesVisibilityGather ? scheme.gatherRefinementSteps : 0,
            flags: flags
        )
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                          width: Int, height: Int) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(pipeline.maxTotalThreadsPerThreadgroup / threadWidth / 2, 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }

    // MARK: - Resources

    private struct TextureBinding {
        let texture: MTLTexture
        let backing: CVMetalTexture
    }

    /// 切到另一个深度模型：换成它的估计器，模型输入/归一化深度/输出缓冲按新
    /// 尺寸重建，在途推理作废（写的是旧模型的槽），下一帧同步推理一次。
    private func adoptModelIfNeeded(
        _ model: LSRealtimeDepthModel,
        for sourceLayout: SourceLayout
    ) throws {
        guard model != depthModel else { return }
        drainDepthQueueForResourceRebuild()
        depthModel = model
        depthEstimator = depthEstimatorResolver(model)
        depthState.withLock {
            depthGeneration &+= 1
            publishedSlot = -1
            previousPublication = nil
            for work in queuedDepthWork { work.cancel() }
            queuedDepthWork.removeAll()
        }
        modelInputs.removeAll()
        modelInputTextures.removeAll()
        modelInputBackings.removeAll()
        normalizedDepth.removeAll()
        depthOutput = nil
        forceReset = true
        lastSubmittedDepthTime = -Double.infinity
        lastDepthSubmissionInstant = nil
        depthState.withLock {
            lastPredictionSourceTime = nil
            recentInferenceSeconds.removeAll()
            governedDepthCap = 0
        }
        layout = nil
        try prepareResources(for: sourceLayout, scheme: currentScheme)
    }

    private func prepareResources(for sourceLayout: SourceLayout,
                                  scheme: LSRealtimeStereoScheme) throws {
        let workingSideForLayout = LSRealtimeStereoScheme.workingMaximumSide(
            frameLongSide: max(sourceLayout.width, sourceLayout.height),
            divisor: scheme.workingGridDivisor
        )
        let gridChanged = layout?.width != sourceLayout.width
            || layout?.height != sourceLayout.height
            || appliedWorkingSide != workingSideForLayout
        if modelInputs.isEmpty || gridChanged {
            drainDepthQueueForResourceRebuild()
        }
        if modelInputs.isEmpty {
            for _ in 0..<2 {
                let buffer = try depthEstimator.makeBuffer(format: kCVPixelFormatType_32BGRA)
                let binding = try texture(for: buffer, plane: 0, format: .bgra8Unorm)
                modelInputs.append(buffer)
                modelInputTextures.append(binding.texture)
                modelInputBackings.append(binding.backing)
                normalizedDepth.append(try makePrivateTexture(
                    format: .r16Float,
                    width: depthEstimator.inputWidth,
                    height: depthEstimator.inputHeight
                ))
            }
            depthOutput = try depthEstimator.makeBuffer(format: kCVPixelFormatType_OneComponent16Half)
        }
        let workingSide = workingSideForLayout
        guard gridChanged else {
            layout = sourceLayout
            return
        }
        layout = sourceLayout
        appliedWorkingSide = workingSide
        contentRect = Self.modelContentRect(width: sourceLayout.width, height: sourceLayout.height,
                                            model: depthModel)
        let scale = min(1, Double(workingSide) / Double(max(sourceLayout.width, sourceLayout.height)))
        let workingWidth = max(Int((Double(sourceLayout.width) * scale).rounded()), 2)
        let workingHeight = max(Int((Double(sourceLayout.height) * scale).rounded()), 2)
        workingSize = (workingWidth, workingHeight)
        workingDepth = try makePrivateTexture(format: .r16Float, width: workingWidth, height: workingHeight)
        dilatedDepth = try makePrivateTexture(format: .r16Float, width: workingWidth, height: workingHeight)
        offsets = try makePrivateTexture(format: .rg16Float, width: workingWidth, height: workingHeight)
        refinedOffsets = try makePrivateTexture(format: .rg16Float, width: workingWidth, height: workingHeight)
        // 换布局：在途推理（写的是旧尺寸的槽）作废，深度从零开始。
        lastSubmittedDepthTime = -Double.infinity
        lastDepthSubmissionInstant = nil
        depthState.withLock {
            lastPredictionSourceTime = nil
            recentInferenceSeconds.removeAll()
            governedDepthCap = 0
        }
        depthState.withLock {
            depthGeneration &+= 1
            publishedSlot = -1
            previousPublication = nil
            for work in queuedDepthWork { work.cancel() }
            queuedDepthWork.removeAll()
        }
        forceReset = true
    }

    private func makePrivateTexture(format: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else {
            throw RenderError.texture(kCVReturnError)
        }
        return texture
    }

    private func planeTextures(_ buffer: CVPixelBuffer, layout: SourceLayout) throws -> [TextureBinding] {
        guard CVPixelBufferGetWidth(buffer) == layout.width,
              CVPixelBufferGetHeight(buffer) == layout.height,
              CVPixelBufferGetPixelFormatType(buffer) == layout.pixelFormat else {
            throw RenderError.unsupportedPixelFormat(CVPixelBufferGetPixelFormatType(buffer))
        }
        return try layout.planeFormats.enumerated().map { plane, format in
            try texture(for: buffer, plane: plane, format: format)
        }
    }

    private func texture(for buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> TextureBinding {
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw RenderError.texture(status)
        }
        return TextureBinding(texture: texture, backing: cvTexture)
    }

    private static func layout(of buffer: CVPixelBuffer) throws -> SourceLayout {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let planes: [MTLPixelFormat]
        let isRGBA: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            planes = [.r8Unorm, .rg8Unorm]
            isRGBA = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            planes = [.r16Unorm, .rg16Unorm]
            isRGBA = false
        case kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_Lossless_32BGRA,
             kCVPixelFormatType_Lossy_32BGRA:
            planes = [.bgra8Unorm]
            isRGBA = true
        case kCVPixelFormatType_64RGBAHalf:
            planes = [.rgba16Float]
            isRGBA = true
        default:
            throw RenderError.unsupportedPixelFormat(format)
        }
        guard width >= 16, height >= 16 else { throw RenderError.unsupportedPixelFormat(format) }
        return SourceLayout(width: width, height: height, pixelFormat: format,
                            isRGBA: isRGBA, planeFormats: planes)
    }

    static func supports(pixelFormat: OSType) -> Bool {
        [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_32BGRA,
         kCVPixelFormatType_Lossless_32BGRA,
         kCVPixelFormatType_Lossy_32BGRA,
         kCVPixelFormatType_64RGBAHalf].contains(pixelFormat)
    }

    /// 默认模型的画面摆放（测试与旧调用点用）。
    static func modelContentRect(width: Int, height: Int) -> SIMD4<Float> {
        modelContentRect(width: width, height: height, model: .default)
    }

    /// Where the picture sits inside the model's fixed input (518×392 for
    /// Depth Anything V2 Small, 768×416 for ZipDepth). Up to a 1.5× anisotropic
    /// stretch is used to fill the input (16:9 is native for ZipDepth, 4:3 uses
    /// every pixel); wider or taller pictures are letterboxed beyond that.
    static func modelContentRect(width: Int, height: Int,
                                 model: LSRealtimeDepthModel) -> SIMD4<Float> {
        let modelWidth = Double(model.inputWidth)
        let modelHeight = Double(model.inputHeight)
        let modelAspect = modelWidth / modelHeight
        let sourceAspect = Double(width) / Double(max(height, 1))
        let stretch = min(max(sourceAspect / modelAspect, 1 / 1.5), 1.5)
        let aspect = sourceAspect / stretch
        var contentWidth = modelWidth
        var contentHeight = modelHeight
        if aspect >= modelAspect {
            contentHeight = (modelWidth / aspect).rounded()
        } else {
            contentWidth = (modelHeight * aspect).rounded()
        }
        let x = ((modelWidth - contentWidth) / 2).rounded(.down)
        let y = ((modelHeight - contentHeight) / 2).rounded(.down)
        return SIMD4(Float(x), Float(y), Float(contentWidth), Float(contentHeight))
    }

    static func colorParams(for buffer: CVPixelBuffer, isRGBA: Bool, pixelFormat: OSType) -> LSRealtimeStereoColorParams {
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil)
        var transferCode: Float = 0
        if let transfer {
            if CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) {
                transferCode = 1
            } else if CFEqual(transfer, kCVImageBufferTransferFunction_Linear) {
                transferCode = 2
            }
        } else if pixelFormat == kCVPixelFormatType_64RGBAHalf {
            transferCode = 2
        }
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
        var kr: Float = 0.2126
        var kb: Float = 0.0722
        if let matrix {
            if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
                kr = 0.2627
                kb = 0.0593
            } else if CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) ||
                        CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995) {
                kr = 0.299
                kb = 0.114
            }
        } else if CVPixelBufferGetWidth(buffer) < 1280 {
            kr = 0.299
            kb = 0.114
        }
        let range: SIMD4<Float>
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            range = SIMD4(16 / 255, 255 / 219, 128 / 255, 255 / 224)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            range = SIMD4(0, 1, 128 / 255, 1)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            range = SIMD4(4096 / 65535, 65535 / (876 * 64), 32768 / 65535, 65535 / (896 * 64))
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            range = SIMD4(0, 65535 / (1023 * 64), 32768 / 65535, 65535 / (1023 * 64))
        default:
            range = SIMD4(0, 1, 0.5, 1)
        }
        return LSRealtimeStereoColorParams(range: range, matrix: SIMD4(kr, kb, transferCode, 0))
    }

    private static func colorParams(for buffer: CVPixelBuffer, layout: SourceLayout) -> LSRealtimeStereoColorParams {
        colorParams(for: buffer, isRGBA: layout.isRGBA, pixelFormat: layout.pixelFormat)
    }

    private static func copyPixels(from source: CVPixelBuffer, to target: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source),
              let to = CVPixelBufferGetBaseAddress(target) else {
            throw LSRealtimeDepthEstimator.EstimatorError.invalidOutput
        }
        let rowBytes = min(CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(target))
        for row in 0..<CVPixelBufferGetHeight(target) {
            memcpy(to.advanced(by: row * CVPixelBufferGetBytesPerRow(target)),
                   from.advanced(by: row * CVPixelBufferGetBytesPerRow(source)),
                   rowBytes)
        }
    }
}

private extension Duration {
    nonisolated var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
