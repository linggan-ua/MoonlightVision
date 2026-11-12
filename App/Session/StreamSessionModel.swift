//
//  StreamSessionModel.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import AVFoundation
import CoreMedia
import Foundation
import Observation
import VideoToolbox

/// Owns one game stream: configuration, start/stop, connection callbacks and stats.
@MainActor
@Observable
final class StreamSessionModel {
    enum Phase: Equatable {
        case idle
        case preparing
        case connecting(stage: String)
        case streaming
        case stopping
        case ended(String?)
    }

    let host: TemporaryHost
    let app: TemporaryApp
    let renderView = StreamRenderView()

    private(set) var phase: Phase = .idle
    private(set) var statsText = ""

    private let operationQueue = OperationQueue()
    private var streamManager: StreamManager?
    private var connectionDelegate: StreamConnectionDelegate?
    private var statsTimer: Timer?
    private var started = false

    init(host: TemporaryHost, app: TemporaryApp) {
        self.host = host
        self.app = app
    }

    var statusText: String {
        switch phase {
        case .idle, .preparing:
            return "Preparing stream…"
        case .connecting(let stage):
            return stage
        case .streaming:
            return ""
        case .stopping:
            return "Disconnecting…"
        case .ended(let message):
            return message ?? "Disconnected"
        }
    }

    var isStreaming: Bool {
        phase == .streaming
    }

    /// The renderer sizes its layer from the view bounds, so wait until SwiftUI has laid it out.
    func startWhenReady() async {
        guard !started else { return }
        for _ in 0..<200 {
            if renderView.bounds.width > 1, renderView.bounds.height > 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        started = true
        start()
    }

    func stop() {
        switch phase {
        case .ended, .stopping:
            return
        default:
            break
        }

        phase = .stopping
        streamManager?.stopStream()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, case .stopping = self.phase else { return }
            self.finish(message: nil)
        }
    }

    // MARK: - Start

    private func start() {
        guard streamManager == nil else { return }

        phase = .preparing
        let config = makeConfiguration()

        let delegate = StreamConnectionDelegate()
        delegate.onStage = { [weak self] stage in
            Task { @MainActor in
                guard let self, case .streaming = self.phase else {
                    self?.phase = .connecting(stage: stage)
                    return
                }
            }
        }
        delegate.onConnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if case .connecting = self.phase {
                    self.phase = .connecting(stage: "Connected")
                }
            }
        }
        delegate.onFirstFrame = { [weak self] in
            Task { @MainActor in
                self?.phase = .streaming
                self?.startStatsTimer()
            }
        }
        delegate.onTerminated = { [weak self] code in
            Task { @MainActor in
                self?.finish(message: code == 0 ? nil : "Connection lost (\(code))")
            }
        }
        delegate.onLaunchFailed = { [weak self] message in
            Task { @MainActor in
                self?.finish(message: message)
            }
        }
        delegate.onStageFailed = { [weak self] stage, code, _ in
            Task { @MainActor in
                self?.finish(message: "\(stage) failed (\(code))")
            }
        }

        connectionDelegate = delegate
        guard let manager = StreamManager(config: config, renderView: renderView, connectionCallbacks: delegate) else {
            finish(message: "Could not start the stream.")
            return
        }
        streamManager = manager
        operationQueue.addOperation(manager)
    }

    private func makeConfiguration() -> StreamConfiguration {
        let config = StreamConfiguration()
        config.host = host.activeAddress ?? host.address ?? ""
        config.httpsPort = host.httpsPort
        config.appID = app.id ?? ""
        config.appName = app.name ?? ""
        config.serverCert = host.serverCert
        config.serverCodecModeSupport = host.serverCodecModeSupport

        config.width = 1920
        config.height = 1080
        config.frameRate = 60
        config.bitRate = 10000
        config.useFramePacing = true
        config.playAudioOnPC = false
        config.optimizeGameSettings = true
        config.swapABXYButtons = false
        config.multiController = false
        config.gamepadMask = 0
        // AUDIO_CONFIGURATION_STEREO expands through a function-like macro, so the
        // Clang importer cannot expose it. This is MAKE_AUDIO_CONFIGURATION(2, 0x3).
        config.audioConfiguration = (0x3 << 16) | (2 << 8) | 0xCA

        var videoFormats = Int32(VIDEO_FORMAT_H264)
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            videoFormats |= Int32(VIDEO_FORMAT_H265)
        }
        config.supportedVideoFormats = videoFormats

        return config
    }

    // MARK: - Teardown and stats

    private func finish(message: String?) {
        statsTimer?.invalidate()
        statsTimer = nil
        streamManager = nil
        statsText = ""
        phase = .ended(message)
    }

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let manager = self.streamManager else { return }
                self.statsText = manager.getStatsOverlayText() ?? ""
            }
        }
    }
}

/// Forwards ConnectionCallbacks (delivered on core threads) as closures.
final class StreamConnectionDelegate: NSObject, ConnectionCallbacks {
    var onStage: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var onTerminated: ((Int32) -> Void)?
    var onLaunchFailed: ((String) -> Void)?
    var onStageFailed: ((String, Int32, Int32) -> Void)?

    func stageStarting(_ stageName: UnsafePointer<CChar>!) {
        guard let stageName else { return }
        onStage?(String(cString: stageName))
    }

    func stageComplete(_ stageName: UnsafePointer<CChar>!) {}

    func stageFailed(_ stageName: UnsafePointer<CChar>!, withError errorCode: Int32, portTestFlags: Int32) {
        onStageFailed?(stageName.map { String(cString: $0) } ?? "Connection", errorCode, portTestFlags)
    }

    func connectionStarted() {
        onConnected?()
    }

    func connectionTerminated(_ errorCode: Int32) {
        onTerminated?(errorCode)
    }

    func launchFailed(_ message: String!) {
        onLaunchFailed?(message ?? "Failed to launch the app.")
    }

    func videoContentShown() {
        onFirstFrame?()
    }

    func rumble(_ controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {}

    func connectionStatusUpdate(_ status: Int32) {}

    func setHdrMode(_ enabled: Bool) {}

    func rumbleTriggers(_ controllerNumber: UInt16, leftTrigger: UInt16, rightTrigger: UInt16) {}

    func setMotionEventState(_ controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {}

    func setControllerLed(_ controllerNumber: UInt16, r: UInt8, g: UInt8, b: UInt8) {}
}
