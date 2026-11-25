//
//  LSRealtimeDepthEstimator.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import CoreML
import CoreVideo
import Foundation
import OSLog

/// One real-time 3D depth network on the Neural Engine, per model.
///
/// 每个 `LSRealtimeDepthModel` 一个实例、进程内缓存：切换模型不重载（ANE 首次
/// 编译要数秒），两个模型可以同时常驻。第一个加载会编译网络，通常在后台队列
/// 上做；未就绪时渲染器输出零视差立体而不是卡住投递队列。
///
/// The first load compiles the network for the ANE and can take seconds, so
/// it runs once on a background queue and every renderer (they are rebuilt on
/// each format/layout change) shares the loaded model. Until it is ready the
/// renderer keeps presenting zero-parallax stereo instead of stalling the
/// render queue.
nonisolated final class LSRealtimeDepthEstimator: @unchecked Sendable {
    enum EstimatorError: LocalizedError {
        case modelUnavailable
        case loadFailed(String)
        case invalidInput
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "实时 3D 深度模型缺失：\(LSRealtimeDepthModel.default.resourceName)"
            case .loadFailed(let description):
                return "实时 3D 深度模型加载失败：\(description)"
            case .invalidInput:
                return "实时 3D 深度模型输入尺寸不符"
            case .invalidOutput:
                return "实时 3D 深度模型未返回有效深度"
            }
        }
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// 模型声明的固定输入尺寸（ZipDepth768x416）。启动前渲染器就要按它分配
    /// 模型输入/深度缓冲，所以是常量；MLRealtimeStereoModelSpecTests 会核对
    /// Resources 里的模型声明与这里一致。
    /// 模型共享缓存：按模型各一个实例，切换不重载。
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: [LSRealtimeDepthModel: LSRealtimeDepthEstimator] = [:]

    /// 指定模型的进程共享实例。
    static func shared(for model: LSRealtimeDepthModel) -> LSRealtimeDepthEstimator {
        cacheLock.withLock {
            if let existing = cached[model] { return existing }
            let created = LSRealtimeDepthEstimator(
                model: model,
                modelURL: Bundle.main.url(forResource: model.resourceName, withExtension: "mlmodelc")
            )
            cached[model] = created
            return created
        }
    }

    /// 这个实例的模型与它声明的输入尺寸。
    let model: LSRealtimeDepthModel
    var inputWidth: Int { model.inputWidth }
    var inputHeight: Int { model.inputHeight }

    private static let logger = Logger(subsystem: "app.moonlightvision", category: "realtime3D")

    private let modelURL: URL?
    private let computeUnits: MLComputeUnits
    private let loadQueue = DispatchQueue(label: "app.moonlightvision.realtime3D.depthModel", qos: .userInitiated)
    private let lock = NSLock()
    /// One prediction at a time even if two theaters briefly overlap during
    /// a candidate/promotion handoff.
    private let predictionLock = NSLock()
    private var loadState = LoadState.idle
    /// 已加载的 Core ML 网络（与 `model`（模型标识）区分）。
    private var network: MLModel?

    init(model: LSRealtimeDepthModel = .default, modelURL: URL?, computeUnits: MLComputeUnits? = nil) {
        self.model = model
        self.modelURL = modelURL
        #if targetEnvironment(simulator)
        // The visionOS simulator has no Neural Engine or MPSGraph backend.
        self.computeUnits = computeUnits ?? .cpuOnly
        #else
        self.computeUnits = computeUnits ?? .cpuAndNeuralEngine
        #endif
    }

    var state: LoadState {
        lock.withLock { loadState }
    }

    /// Starts the one-time load if needed. Returns true once predictions can run.
    @discardableResult
    func prepare() -> Bool {
        let shouldLoad: Bool = lock.withLock {
            switch loadState {
            case .ready:
                return false
            case .loading, .failed:
                return false
            case .idle:
                loadState = .loading
                return true
            }
        }
        if shouldLoad {
            loadQueue.async { [self] in load() }
        }
        return lock.withLock { loadState == .ready }
    }

    /// Blocks until the model has loaded or failed. Tests and offline tools only.
    func waitUntilLoaded() throws {
        prepare()
        loadQueue.sync {}
        if case .failed(let description) = state {
            throw EstimatorError.loadFailed(description)
        }
    }

    /// Runs the network on `input` (model.inputWidth×inputHeight BGRA) and returns
    /// the depth image (same size, OneComponent16Half, relative inverse depth,
    /// 1 = nearest). 两个模型的输出同向（实测 ZipDepth 也是越大越近，与 DA V2
    /// 的相关性 +0.93~0.97），画面管线不需要按模型取反。
    /// `output` is offered as the output backing so the result stays on its
    /// IOSurface; the returned buffer is whatever Core ML actually wrote.
    func predict(input: CVPixelBuffer, output: CVPixelBuffer) throws -> CVPixelBuffer {
        guard CVPixelBufferGetWidth(input) == inputWidth,
              CVPixelBufferGetHeight(input) == inputHeight else {
            throw EstimatorError.invalidInput
        }
        guard let network = lock.withLock({ network }) else {
            throw EstimatorError.modelUnavailable
        }
        let options = MLPredictionOptions()
        options.outputBackings = ["depth": output]
        let features = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: input)]
        )
        let result = try predictionLock.withLock {
            try network.prediction(from: features, options: options)
        }
        guard let depth = result.featureValue(for: "depth")?.imageBufferValue,
              CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_OneComponent16Half,
              CVPixelBufferGetWidth(depth) == inputWidth,
              CVPixelBufferGetHeight(depth) == inputHeight else {
            throw EstimatorError.invalidOutput
        }
        return depth
    }

    private func load() {
        do {
            guard let modelURL else { throw EstimatorError.modelUnavailable }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            let started = ContinuousClock.now
            let loaded = try MLModel(contentsOf: modelURL, configuration: configuration)
            // One throwaway prediction finishes the ANE compilation here rather
            // than on the first converted frame.
            let input = try makeBuffer(format: kCVPixelFormatType_32BGRA)
            let output = try makeBuffer(format: kCVPixelFormatType_OneComponent16Half)
            let options = MLPredictionOptions()
            options.outputBackings = ["depth": output]
            _ = try loaded.prediction(
                from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]),
                options: options
            )
            lock.withLock {
                network = loaded
                loadState = .ready
            }
            let elapsed = started.duration(to: .now)
            Self.logger.info("Depth model ready in \(elapsed.components.seconds, privacy: .public)s \(elapsed.components.attoseconds / 1_000_000_000_000_000, privacy: .public)ms")
        } catch {
            lock.withLock { loadState = .failed(error.localizedDescription) }
            Self.logger.error("Depth model load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 按本模型输入尺寸分配像素缓冲（渲染器用它建模型输入与深度输出缓冲）。
    func makeBuffer(format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            inputWidth,
            inputHeight,
            format,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw EstimatorError.invalidInput
        }
        return buffer
    }
}
