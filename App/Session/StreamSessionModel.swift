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
/// input, reconnect and stats.
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
    private var fpsMonitorTimer: Timer?
    private var lowFpsSeconds = 0
    private var fpsRestartInProgress = false
    private var started = false
    private var userInitiatedStop = false
    private var reconnectAttempts = 0
    private var pendingTerminationCode: Int32?
    private var stopCompletionSeen = false
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
        for _ in 0..<200 {
            if renderView.bounds.width > 1, renderView.bounds.height > 1 {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        started = true
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
        StreamStartGate.shared.beginStop()
        stopCompletionSeen = false

        guard let manager = streamManager else {
            stopCompletionSeen = true
            StreamStartGate.shared.endStop()
            finish(message: nil)
            return
        }
        streamManager = nil

        manager.stopStream(completion: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopCompletionSeen else { return }
                self.stopCompletionSeen = true
                StreamStartGate.shared.endStop()
                self.finish(message: nil)
            }
        })

        // Ultimate watchdog: never leave the next start gated forever if the
        // underlying LiStopConnection() is wedged.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !self.stopCompletionSeen else { return }
            self.stopCompletionSeen = true
            StreamStartGate.shared.endStop()
            self.finish(message: "Disconnect timed out.")
        }
    }

    /// Called from the stream scene when visionOS backgrounds or foregrounds the window.
    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded

        if backgrounded {
            teardownInput()
            return
        }

        if let code = pendingTerminationCode {
            pendingTerminationCode = nil
            reconnect(message: String(format: String(localized: "Connection lost (%d)"), code))
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

        await StreamStartGate.shared.waitUntilStartable()
        guard !userInitiatedStop, streamManager == nil else { return }

        phase = .preparing
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
                self.reconnectAttempts = 0
                self.lowFpsSeconds = 0
                self.phase = .streaming
                self.startStatsTimer()
                self.startFpsMonitor()
            }
        }
        delegate.onTerminated = { [weak self] code in
            Task { @MainActor in
                self?.handleTermination(code)
            }
        }
        delegate.onLaunchFailed = { [weak self] message in
            Task { @MainActor in
                self?.finish(message: message)
            }
        }
        delegate.onStageFailed = { [weak self] stage, code, _ in
            Task { @MainActor in
                self?.finish(message: String(format: String(localized: "%@ failed (%d)"), stage, code))
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
        if isBackgrounded {
            pendingTerminationCode = code
            return
        }
        if code == 0 {
            finish(message: nil)
            return
        }
        reconnect(message: String(format: String(localized: "Connection lost (%d)"), code))
    }

    private func reconnect(message: String) {
        guard reconnectAttempts < 3 else {
            finish(message: message)
            return
        }

        reconnectAttempts += 1
        teardownInput()
        streamManager = nil
        connectionDelegate = nil
        phase = .connecting(stage: String(format: String(localized: "Reconnecting… (%d/3)"), Int32(reconnectAttempts)))

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !self.userInitiatedStop, !self.isBackgrounded else { return }
            await self.start()
        }
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
        var formats = Int32(VIDEO_FORMAT_H264)

        switch settings.codec {
        case .auto:
            if hevcSupported { formats |= Int32(VIDEO_FORMAT_H265) }
            if av1Supported { formats |= Int32(VIDEO_FORMAT_AV1_MAIN8) }
        case .h264:
            break
        case .hevc:
            if hevcSupported { formats |= Int32(VIDEO_FORMAT_H265) }
        case .av1:
            if av1Supported { formats |= Int32(VIDEO_FORMAT_AV1_MAIN8) }
            if hevcSupported { formats |= Int32(VIDEO_FORMAT_H265) }
        }

        if settings.hdrEnabled, AVPlayer.availableHDRModes.contains(.hdr10) {
            if hevcSupported { formats |= Int32(VIDEO_FORMAT_H265_MAIN10) }
            if av1Supported { formats |= Int32(VIDEO_FORMAT_AV1_MAIN10) }
        }

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
        fpsMonitorTimer?.invalidate()
        fpsMonitorTimer = nil
        streamManager = nil
        connectionDelegate = nil
        statsText = ""
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

    // MARK: - Frame-rate mismatch

    private func startFpsMonitor() {
        fpsMonitorTimer?.invalidate()
        fpsMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkFrameRate()
            }
        }
    }

    private func checkFrameRate() {
        guard phase == .streaming, !fpsRestartInProgress, !isBackgrounded,
              let manager = streamManager else {
            return
        }

        let requested = Double(StreamSettingsStore.shared.frameRate)
        guard requested >= 100 else {
            lowFpsSeconds = 0
            return
        }

        var stats = video_stats_t()
        guard manager.getVideoStats(&stats) else { return }
        let interval = stats.endTime - stats.startTime
        guard interval > 0 else { return }
        let actual = Double(stats.totalFrames) / interval

        if actual > 0, actual < requested * 0.95 {
            lowFpsSeconds += 1
        } else {
            lowFpsSeconds = 0
        }

        guard lowFpsSeconds >= 10 else { return }
        lowFpsSeconds = 0

        // an earlier GPL-3.0 project's rule: at most one mismatch restart per host every 300 s.
        let key = "mv.lastFpsRestart.\(host.uuid)"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: key)
        guard now - last >= 300 else { return }
        UserDefaults.standard.set(now, forKey: key)

        restartForFrameRate(actual: actual, requested: requested)
    }

    private func restartForFrameRate(actual: Double, requested: Double) {
        guard !userInitiatedStop, !fpsRestartInProgress, let manager = streamManager else { return }
        fpsRestartInProgress = true
        NSLog("[Stream] FPS mismatch: requested %.0f, received %.0f; restarting once", requested, actual)
        phase = .connecting(stage: String(localized: "Restarting for frame rate…"))
        teardownInput()
        streamManager = nil

        StreamStartGate.shared.beginStop()
        manager.stopStream(completion: { [weak self] in
            Task { @MainActor in
                StreamStartGate.shared.endStop()
                guard let self, !self.userInitiatedStop, case .connecting = self.phase else { return }
                self.fpsRestartInProgress = false
                await self.start()
            }
        })

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.fpsRestartInProgress, case .connecting = self.phase else { return }
            self.fpsRestartInProgress = false
            StreamStartGate.shared.endStop()
            self.finish(message: String(localized: "Frame-rate restart timed out."))
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

    func connectionStatusUpdate(_ status: Int32) {}

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
