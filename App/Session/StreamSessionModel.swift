//
//  StreamSessionModel.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import AVFoundation
import CoreMedia
import Foundation
import GameController
import Observation
import UIKit
import VideoToolbox

/// Owns one game stream: configuration, start/stop, connection callbacks,
/// input and stats.
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
    let keyboardInput = StreamKeyboardInput()

    private(set) var phase: Phase = .idle
    private(set) var statsText = ""
    private(set) var isBackgrounded = false
    private(set) var isMuted = false
    private(set) var connectionPoor = false
    var volume: Double = 1.0 {
        didSet {
            isMuted = volume <= 0
            MVSetStreamVolume(Float(volume))
        }
    }
    private var volumeBeforeMute: Double = 1.0

    private let operationQueue = OperationQueue()
    private var streamManager: StreamManager?
    private var connectionDelegate: StreamConnectionDelegate?
    private var statsTimer: Timer?
    private var started = false
    private var userInitiatedStop = false
    private var activeConfig: StreamConfiguration?

    private let mouseInput = StreamMouseInput()
    private let pointerHider = StreamPointerHider()
    private var pointerInteraction: UIPointerInteraction?
    private var gameControllerInteraction: GCEventInteraction?
    private var controllerSupport: ControllerSupport?
    private var controllerDelegate: StreamControllerDelegate?
    private var inputActive = false

    init(host: TemporaryHost, app: TemporaryApp) {
        self.host = host
        self.app = app
    }

    var statusText: String {
        switch phase {
        case .idle, .preparing:
            return String(localized: "Preparing stream…")
        case .connecting(let stage):
            return stage
        case .streaming:
            return ""
        case .stopping:
            return String(localized: "Disconnecting…")
        case .ended(let message):
            return message ?? String(localized: "Disconnected")
        }
    }

    var isStreaming: Bool {
        phase == .streaming
    }

    func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute > 0 ? volumeBeforeMute : 1
        }
    }

    /// The renderer sizes its layer from the view bounds, so wait until SwiftUI has laid it out.
    func startWhenReady() async {
        guard !started else { return }
        started = true
        // The original client starts immediately; VideoDecoderRenderer owns
        // late layout through its bounds KVO and stays hidden until the first IDR.
        await start()
    }

    func stop() {
        guard !userInitiatedStop else { return }
        userInitiatedStop = true

        switch phase {
        case .ended, .stopping:
            return
        default:
            break
        }

        phase = .stopping
        teardownInput()

        guard let manager = streamManager else {
            finish(message: nil)
            return
        }
        streamManager = nil

        // StreamManager/Connection serialize LiStopConnection against a later
        // LiStartConnection with Connection's static initLock, exactly like the
        // core client. No extra gate or watchdog is needed.
        manager.stopStream(completion: { [weak self] in
            Task { @MainActor in
                self?.finish(message: nil)
            }
        })
    }

    /// Called from the stream scene when visionOS backgrounds or foregrounds the window.
    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded

        if backgrounded {
            teardownInput()
            return
        }

        switch phase {
        case .streaming, .connecting:
            if let config = activeConfig {
                setupInput(config: config)
            }
        default:
            break
        }
    }

    // MARK: - Start

    private func start() async {
        guard streamManager == nil, !userInitiatedStop else { return }

        phase = .preparing
        connectionPoor = false
        let config = makeConfiguration()
        activeConfig = config
        setupInput(config: config)
        MVSetStreamVolume(Float(volume))
        MVSetStreamSpatialAudio(StreamSettingsStore.shared.spatialAudio)

        let delegate = StreamConnectionDelegate()
        delegate.onStage = { [weak self] stage in
            Task { @MainActor in
                guard let self, case .streaming = self.phase else {
                    self?.phase = .connecting(stage: stage)
                    return
                }
            }
        }
        delegate.onConnectionStatus = { [weak self] status in
            Task { @MainActor in
                self?.connectionPoor = (status == Int32(CONN_STATUS_POOR))
            }
        }
        delegate.onConnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.controllerSupport?.connectionEstablished()
                if case .connecting = self.phase {
                    self.phase = .connecting(stage: String(localized: "Connected"))
                }
            }
        }
        delegate.onFirstFrame = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.phase = .streaming
                self.startStatsTimer()
            }
        }
        delegate.onTerminated = { [weak self] code in
            Task { @MainActor in
                self?.handleTermination(code)
            }
        }
        delegate.onLaunchFailed = { [weak self] message in
            Task { @MainActor in
                self?.finishAfterTeardown(message: message)
            }
        }
        delegate.onStageFailed = { [weak self] stage, code, _ in
            Task { @MainActor in
                self?.finishAfterTeardown(message: String(format: String(localized: "%@ failed (%d)"), stage, code))
            }
        }
        delegate.onRumble = { [weak self] controller, low, high in
            Task { @MainActor in
                self?.controllerSupport?.rumble(controller, lowFreqMotor: low, highFreqMotor: high)
            }
        }
        delegate.onRumbleTriggers = { [weak self] controller, left, right in
            Task { @MainActor in
                self?.controllerSupport?.rumbleTriggers(controller, leftTrigger: left, rightTrigger: right)
            }
        }
        delegate.onSetMotionEventState = { [weak self] controller, motionType, rate in
            Task { @MainActor in
                self?.controllerSupport?.setMotionEventState(controller, motionType: motionType, reportRateHz: rate)
            }
        }
        delegate.onSetControllerLed = { [weak self] controller, r, g, b in
            Task { @MainActor in
                self?.controllerSupport?.setControllerLed(controller, r: r, g: g, b: b)
            }
        }

        connectionDelegate = delegate
        guard let manager = StreamManager(config: config, renderView: renderView, connectionCallbacks: delegate) else {
            finish(message: String(localized: "Could not start the stream."))
            return
        }
        streamManager = manager
        operationQueue.addOperation(manager)

    }

    private func handleTermination(_ code: Int32) {
        if userInitiatedStop {
            finish(message: nil)
            return
        }
        // Terminated-connection behavior: a terminated connection ends the stream
        // and reports the error. The StreamManager must still be stopped so
        // LiStopConnection releases common-c's static state for the next stream.
        finishAfterTeardown(message: code == 0
            ? nil
            : String(format: String(localized: "Connection lost (%d)"), code))
    }

    private func finishAfterTeardown(message: String?) {
        let manager = streamManager
        streamManager = nil
        finish(message: message)
        manager?.stopStream(completion: nil)
    }

    // MARK: - Configuration

    private func makeConfiguration() -> StreamConfiguration {
        let settings = StreamSettingsStore.shared
        let config = StreamConfiguration()
        config.host = host.activeAddress ?? host.address ?? ""
        config.httpsPort = host.httpsPort
        config.appID = app.id ?? ""
        config.appName = app.name ?? ""
        config.serverCert = host.serverCert
        config.serverCodecModeSupport = host.serverCodecModeSupport

        config.width = settings.resolution.width
        config.height = settings.resolution.height
        config.frameRate = Int32(settings.frameRate)
        config.bitRate = Int32(settings.bitrateMbps * 1000)
        config.useFramePacing = settings.framePacing
        config.framePacingDepth = Int32(settings.framePacingDepth)
        config.playAudioOnPC = settings.playAudioOnPC
        config.optimizeGameSettings = settings.optimizeGameSettings
        config.swapABXYButtons = settings.swapABXY
        config.multiController = settings.multiController
        config.gamepadMask = Int32(ControllerSupport.getConnectedGamepadMask(config))
        config.audioConfiguration = audioConfiguration(for: settings)
        config.supportedVideoFormats = preferredVideoFormats(settings: settings)

        return config
    }

    private func preferredVideoFormats(settings: StreamSettingsStore) -> Int32 {
        let hevcSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1Supported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

        // Match the mature clients' policy: HDR is requested only when the user
        // enabled it, the selected codec can carry 10-bit, and the host reports
        // the matching Main10 capability. Do not gate this on
        // AVPlayer.availableHDRModes; it is not a reliable HDR capability signal
        // on visionOS, and gating on it silently disables HDR entirely.
        let hostMask = UInt32(truncatingIfNeeded: host.serverCodecModeSupport)
        let hostHEVCMain10 = (hostMask & UInt32(SCM_HEVC_MAIN10)) != 0
        let hostAV1Main10 = (hostMask & UInt32(SCM_AV1_MAIN10)) != 0
        let hdrRequested = settings.hdrEnabled && settings.codec.supportsHDR

        var formats = Int32(VIDEO_FORMAT_H264)

        switch settings.codec {
        case .auto:
            if hevcSupported {
                formats |= Int32(VIDEO_FORMAT_H265)
                if hdrRequested && hostHEVCMain10 {
                    formats |= Int32(VIDEO_FORMAT_H265_MAIN10)
                }
            }
            if av1Supported {
                formats |= Int32(VIDEO_FORMAT_AV1_MAIN8)
                if hdrRequested && hostAV1Main10 {
                    formats |= Int32(VIDEO_FORMAT_AV1_MAIN10)
                }
            }
        case .h264:
            break
        case .hevc:
            if hevcSupported {
                formats |= Int32(VIDEO_FORMAT_H265)
                if hdrRequested && hostHEVCMain10 {
                    formats |= Int32(VIDEO_FORMAT_H265_MAIN10)
                }
            }
        case .av1:
            if av1Supported {
                formats |= Int32(VIDEO_FORMAT_AV1_MAIN8)
                if hdrRequested && hostAV1Main10 {
                    formats |= Int32(VIDEO_FORMAT_AV1_MAIN10)
                }
            }
            // HEVC is a fallback when the host or client cannot do AV1.
            if hevcSupported {
                formats |= Int32(VIDEO_FORMAT_H265)
                if hdrRequested && hostHEVCMain10 {
                    formats |= Int32(VIDEO_FORMAT_H265_MAIN10)
                }
            }
        }

        NSLog("[Stream] HDR requested=%d codec=%@ hostMask=0x%x formats=0x%x",
              hdrRequested ? 1 : 0,
              settings.codec.rawValue,
              hostMask,
              formats)
        return formats
    }

    private func audioConfiguration(for settings: StreamSettingsStore) -> Int32 {
        let maxChannels = StreamSettingsStore.maximumOutputChannels
        let requested: Int
        switch settings.audioMode {
        case .auto: requested = maxChannels
        case .stereo: requested = 2
        case .surround51: requested = 6
        case .surround71: requested = 8
        }

        if requested >= 8, maxChannels >= 8 {
            return (0x63F << 16) | (8 << 8) | 0xCA
        }
        if requested >= 6, maxChannels >= 6 {
            return (0x3F << 16) | (6 << 8) | 0xCA
        }
        return (0x3 << 16) | (2 << 8) | 0xCA
    }

    // MARK: - Input

    private func setupInput(config: StreamConfiguration) {
        guard !inputActive else { return }
        inputActive = true

        let pointer = UIPointerInteraction(delegate: pointerHider)
        renderView.addInteraction(pointer)
        pointerInteraction = pointer

        // Receive raw gamepad events instead of letting visionOS turn them into
        // gaze/pinch events on the focused view.
        let gameController = GCEventInteraction()
        gameController.receivesEventsInView = false
        renderView.addInteraction(gameController)
        gameControllerInteraction = gameController

        let settings = StreamSettingsStore.shared
        mouseInput.start(mode: settings.mouseMode, streamWidth: config.width, streamHeight: config.height)

        let delegate = StreamControllerDelegate()
        delegate.onExitRequested = { [weak self] in
            Task { @MainActor in
                self?.stop()
            }
        }
        controllerDelegate = delegate
        controllerSupport = ControllerSupport(config: config, delegate: delegate)
    }

    private func teardownInput() {
        guard inputActive else { return }
        inputActive = false

        mouseInput.stop()
        controllerSupport?.cleanup()
        controllerSupport = nil
        controllerDelegate = nil

        if let pointerInteraction {
            renderView.removeInteraction(pointerInteraction)
            self.pointerInteraction = nil
        }
        if let gameControllerInteraction {
            renderView.removeInteraction(gameControllerInteraction)
            self.gameControllerInteraction = nil
        }
    }

    // MARK: - Teardown and stats

    private func finish(message: String?) {
        teardownInput()
        statsTimer?.invalidate()
        statsTimer = nil
        streamManager = nil
        connectionDelegate = nil
        statsText = ""
        connectionPoor = false
        if case .ended = phase { return }
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
    var onConnectionStatus: ((Int32) -> Void)?
    var onRumble: ((UInt16, UInt16, UInt16) -> Void)?
    var onRumbleTriggers: ((UInt16, UInt16, UInt16) -> Void)?
    var onSetMotionEventState: ((UInt16, UInt8, UInt16) -> Void)?
    var onSetControllerLed: ((UInt16, UInt8, UInt8, UInt8) -> Void)?

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
        onLaunchFailed?(message ?? String(localized: "Failed to launch the app."))
    }

    func videoContentShown() {
        onFirstFrame?()
    }

    func rumble(_ controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
        onRumble?(controllerNumber, lowFreqMotor, highFreqMotor)
    }

    func connectionStatusUpdate(_ status: Int32) {
        onConnectionStatus?(status)
    }

    func setHdrMode(_ enabled: Bool) {}

    func rumbleTriggers(_ controllerNumber: UInt16, leftTrigger: UInt16, rightTrigger: UInt16) {
        onRumbleTriggers?(controllerNumber, leftTrigger, rightTrigger)
    }

    func setMotionEventState(_ controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        onSetMotionEventState?(controllerNumber, motionType, reportRateHz)
    }

    func setControllerLed(_ controllerNumber: UInt16, r: UInt8, g: UInt8, b: UInt8) {
        onSetControllerLed?(controllerNumber, r, g, b)
    }
}

final class StreamControllerDelegate: NSObject, ControllerSupportDelegate {
    var onExitRequested: (() -> Void)?

    func gamepadPresenceChanged() {}

    func mousePresenceChanged() {}

    func streamExitRequested() {
        onExitRequested?()
    }
}
