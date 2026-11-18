//
//  Realtime3DTests.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import CoreMedia
import CoreVideo
import RealityKit
import XCTest
@testable import MoonlightVision

final class Realtime3DTests: XCTestCase {
    func testZipDepthModelLoadsAndPredicts() throws {
        let estimator = LSRealtimeDepthEstimator.shared(for: .zipDepth)
        try estimator.waitUntilLoaded()

        let input = try estimator.makeBuffer(format: kCVPixelFormatType_32BGRA)
        let output = try estimator.makeBuffer(format: kCVPixelFormatType_OneComponent16Half)
        fillWithGradient(input)

        let depth = try estimator.predict(input: input, output: output)
        XCTAssertEqual(CVPixelBufferGetWidth(depth), estimator.inputWidth)
        XCTAssertEqual(CVPixelBufferGetHeight(depth), estimator.inputHeight)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(depth),
            kCVPixelFormatType_OneComponent16Half
        )
    }

    func testConverterProducesBothEyes() throws {
        guard let converter = Realtime3DConverter() else {
            throw XCTSkip("Metal shaders unavailable in this environment")
        }
        let width = 640
        let height = 360
        let source = makeBGRA(width: width, height: height)
        fillWithGradient(source)

        let settings = LSRealtime3DSettings(
            isEnabled: true,
            depthStrength: 0.4,
            convergence: 0,
            swapsEyes: false,
            showsDepth: false,
            scheme: .fusion
        )
        let conversion = converter.convert(
            source: source,
            settings: settings,
            presentationTime: CMTime(value: 1, timescale: 60),
            duration: CMTime(value: 1, timescale: 60)
        )
        let result = try XCTUnwrap(conversion)
        XCTAssertEqual(CVPixelBufferGetWidth(result.left), width)
        XCTAssertEqual(CVPixelBufferGetHeight(result.left), height)
        XCTAssertEqual(CVPixelBufferGetWidth(result.right), width)
        XCTAssertEqual(CVPixelBufferGetHeight(result.right), height)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(result.left),
            kCVPixelFormatType_32BGRA
        )
        XCTAssertNotNil(converter.lastReport)
    }

    // MARK: - Helpers

    private func makeBGRA(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary,
            &buffer
        )
        return buffer!
    }

    private func fillWithGradient(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = UInt8((x + y) & 0xFF)
                row[offset + 1] = UInt8((y * 2) & 0xFF)
                row[offset + 2] = UInt8((x * 2) & 0xFF)
                row[offset + 3] = 255
            }
        }
    }
}

private final class TestCallbacks: NSObject, ConnectionCallbacks {
    func connectionStarted() {}
    func connectionTerminated(_ errorCode: Int32) {}
    func stageStarting(_ stageName: UnsafePointer<CChar>!) {}
    func stageComplete(_ stageName: UnsafePointer<CChar>!) {}
    func stageFailed(_ stageName: UnsafePointer<CChar>!, withError errorCode: Int32, portTestFlags: Int32) {}
    func launchFailed(_ message: String!) {}
    func rumble(_ controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {}
    func connectionStatusUpdate(_ status: Int32) {}
    func setHdrMode(_ enabled: Bool) {}
    func rumbleTriggers(_ controllerNumber: UInt16, leftTrigger: UInt16, rightTrigger: UInt16) {}
    func setMotionEventState(_ controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {}
    func setControllerLed(_ controllerNumber: UInt16, r: UInt8, g: UInt8, b: UInt8) {}
    func videoContentShown() {}
}

final class DrawableVideoDecoderStereoQueueTests: XCTestCase {
    func testStereoOutputDoublesTheDrawableQueueWidth() throws {
        var queueWidths: [Int] = []
        let texture = try TextureResource(
            dimensions: .dimensions(width: 1280, height: 360),
            format: .raw(pixelFormat: .bgra8Unorm_srgb),
            contents: .init(mipmapLevels: [.mip(data: Data(count: 4 * 1280 * 360), bytesPerRow: 4 * 1280)])
        )
        let decoder = DrawableVideoDecoder(
            texture: texture,
            callbacks: TestCallbacks(),
            aspectRatio: 9.0 / 16.0,
            useFramePacing: false,
            enableHDR: false,
            hdrSettingsProvider: nil,
            enhancementsProvider: nil,
            realtime3DSettingsProvider: nil,
            callbackToRender: { queue, _, _ in
                if let drawable = try? queue.nextDrawable() {
                    queueWidths.append(drawable.texture.width)
                }
            }
        )
        decoder.setup(withVideoFormat: Int32(VIDEO_FORMAT_H264), width: 640, height: 360, frameRate: 30)
        XCTAssertEqual(queueWidths.last, 640)

        decoder.setStereoOutputEnabled(true)
        XCTAssertEqual(queueWidths.last, 1280)

        decoder.setStereoOutputEnabled(false)
        XCTAssertEqual(queueWidths.last, 640)
    }
}
