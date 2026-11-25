//
//  Realtime3DConverter.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  Adapter between the stream decoder and the real-time 2D→3D renderer: owns
//  the depth renderer and a small CVPixelBuffer pool for the two eye frames.
//

import CoreMedia
import CoreVideo
import Foundation
import Metal

nonisolated final class Realtime3DConverter: @unchecked Sendable {
    struct Conversion {
        let left: CVPixelBuffer
        let right: CVPixelBuffer
        let report: LSRealtimeStereoRenderer.Report
    }

    private struct PoolKey: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    private let gpu: LSRealtimeStereoGPU
    private let renderer: LSRealtimeStereoRenderer
    private var pool: CVPixelBufferPool?
    private var poolKey: PoolKey?
    private let reportLock = NSLock()
    private var storedReport: LSRealtimeStereoRenderer.Report?

    /// Latest report, safe to read from the UI thread.
    var lastReport: LSRealtimeStereoRenderer.Report? {
        reportLock.lock()
        defer { reportLock.unlock() }
        return storedReport
    }

    /// The eye copy pass must be submitted on this queue *after* the renderer's
    /// synthesis buffer, so the decoder uses it as the frame queue while 3D is on.
    var commandQueue: MTLCommandQueue { gpu.queue }

    init?() {
        guard let gpu = try? LSRealtimeStereoGPU.shared() else {
            print("[Realtime3D] Metal shaders unavailable; real-time 3D disabled")
            return nil
        }
        do {
            renderer = try LSRealtimeStereoRenderer(
                gpu: gpu,
                depthEstimatorResolver: { LSRealtimeDepthEstimator.shared(for: $0) },
                prefersSynchronousDepth: false
            )
        } catch {
            print("[Realtime3D] Renderer init failed: \(error.localizedDescription)")
            return nil
        }
        self.gpu = gpu
    }

    /// Compiles the pipelines and starts the one-time model load in the background.
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? LSRealtimeStereoGPU.shared()
            LSRealtimeDepthEstimator.shared(for: .default).prepare()
            if let other = LSRealtimeDepthModel.allCases.first(where: { $0 != .default }) {
                LSRealtimeDepthEstimator.shared(for: other).prepare()
            }
        }
    }

    func reset() {
        renderer.reset()
        reportLock.lock()
        storedReport = nil
        reportLock.unlock()
    }

    static func supports(pixelFormat: OSType) -> Bool {
        LSRealtimeStereoRenderer.supports(pixelFormat: pixelFormat)
    }

    func prefetchDepth(for source: CVPixelBuffer,
                       settings: LSRealtime3DSettings,
                       presentationTime: CMTime) {
        guard settings.isEnabled, presentationTime.isNumeric else { return }
        renderer.prefetchDepth(
            source: source,
            presentationTime: CMTimeGetSeconds(presentationTime),
            settings: settings
        )
    }

    /// Converts one decoded frame into left/right eye pixel buffers. Returns nil
    /// when 3D is off, the pixel format is unsupported, or no output buffer is
    /// available (the caller then renders the mono frame instead of stalling).
    func convert(source: CVPixelBuffer,
                 settings: LSRealtime3DSettings,
                 presentationTime: CMTime,
                 duration: CMTime,
                 isStill: Bool = false) -> Conversion? {
        guard settings.isEnabled, presentationTime.isNumeric else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard width >= 16, height >= 16,
              Self.supports(pixelFormat: pixelFormat),
              let pool = outputPool(width: width, height: height, pixelFormat: pixelFormat),
              let left = makePixelBuffer(from: pool),
              let right = makePixelBuffer(from: pool) else {
            return nil
        }

        let timing = LSRealtimeStereoRenderer.FrameTiming(
            presentationTime: CMTimeGetSeconds(presentationTime),
            duration: duration.isNumeric ? CMTimeGetSeconds(duration) : nil,
            isStill: isStill
        )
        do {
            let report = try renderer.render(
                source: source,
                left: left,
                right: right,
                settings: settings,
                timing: timing
            )
            reportLock.lock()
            storedReport = report
            reportLock.unlock()
            return settings.swapsEyes
                ? Conversion(left: right, right: left, report: report)
                : Conversion(left: left, right: right, report: report)
        } catch {
            print("[Realtime3D] Conversion failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Latest depth textures for the debug "show depth" view (working grid).
    func debugTextures() -> LSRealtimeStereoRenderer.DebugTextures {
        renderer.debugTextures()
    }

    // MARK: - Output pool

    private func outputPool(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBufferPool? {
        let key = PoolKey(width: width, height: height, pixelFormat: pixelFormat)
        if key == poolKey, let pool { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &created
        )
        guard status == kCVReturnSuccess, let created else {
            print("[Realtime3D] Output pool creation failed (\(status))")
            return nil
        }
        pool = created
        poolKey = key
        return created
    }

    private func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        // The decoder keeps at most three frames in flight; 12 eye buffers cover
        // that comfortably and bound memory if a frame is ever retained.
        let aux: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: 12]
        var status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            aux as CFDictionary,
            &buffer
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }
}
