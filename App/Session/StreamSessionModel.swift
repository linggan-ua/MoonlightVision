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
import Metal
import Observation
import RealityKit
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
    let inputView = StreamWindowInputView()
    let keyboardInput = StreamKeyboardInput()

    /// The window plane's texture. Created for each stream with the requested
    /// resolution and pixel format; the decoder renders frames into it.
    private(set) var videoTexture: TextureResource?
    private var videoTextureWidth = 0
    let frameMailbox = StreamFrameMailbox()

    /// Set while a local 2D→3D conversion is running; the decoder reads it
    /// from its own thread through this flag.
    private let realtime3DActivation = Realtime3DActivationFlag()
    /// The decoder of the active stream, for live 3D toggles and stats.
    private(set) var activeDecoder: DrawableVideoDecoder?

    /// 2D or side-by-side 3D presentation. Runtime-only, like the mature
    /// clients: each stream starts in 2D.
    var videoMode: VideoMode = .standard2D {
        didSet {
            if videoMode != .sideBySide3D {
                showSBSConfirm = false
            }
            let enabled = videoMode == .sideBySide3D
            let store = StreamSettingsStore.shared
            if store.stereoSBS != enabled {
                store.stereoSBS = enabled
            }
            applyVideoModeChange()
        }
    }
    /// The SBS confirmation card is showing in the stream window.
    var showSBSConfirm = false

    private(set) var phase: Phase = .idle
    private(set) var statsText = ""
    private(set) var isBackgrounded = false
    /// When the app went to the background, used to decide whether a silent
    /// connection loss needs an automatic reconnect on return.
    private var backgroundedAt: Date?
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
    private var appListInFlight = false
    private var userInitiatedStop = false
    private var activeConfig: StreamConfiguration?

    /// Local cursor overlay shared by the input strategy and the video surface.
    let localCursor = StreamLocalCursor()

    private var mouseStrategy: (any StreamMouseStrategy)?
    private let touchInput = StreamTouchInput()
    private(set) var isRestarting = false
    private(set) var hidesStreamChrome = false
    private var gameControllerInteraction: GCEventInteraction?
    private var controllerSupport: ControllerSupport?
    private var controllerDelegate: StreamControllerDelegate?
    private var inputActive = false

    init(host: TemporaryHost, app: TemporaryApp) {
        self.host = host
        self.app = app
        // The persisted master switch decides how the next stream presents.
        videoMode = StreamSettingsStore.shared.stereoSBS
            ? .sideBySide3D
            : .standard2D
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

    /// True once the session has ended. Connection callbacks arrive through
    /// `Task { @MainActor }`, so one queued before teardown can still run after
    /// it; they must not revive the session.
    private var hasEnded: Bool {
        if case .ended = phase { return true }
        return false
    }

    /// Width ÷ height of the picture the window shows. Packed SBS streams
    /// carry both eyes side by side, so each eye's picture is half as wide; the
    /// window locks to that per-eye aspect in 3D.
    var streamAspect: Double {
        if videoMode == .sideBySide3D, isSBSStream {
            return (Double(streamWidth) / 2) / Double(max(streamHeight, 1))
        }
        return Double(streamWidth) / Double(max(streamHeight, 1))
    }

    /// Host frame size for the active stream.
    var streamWidth: Int {
        Int(activeConfig?.width ?? StreamSettingsStore.shared.resolution.width)
    }

    var streamHeight: Int {
        Int(activeConfig?.height ?? StreamSettingsStore.shared.resolution.height)
    }

    /// True when the host itself sends a frame-packed side-by-side picture.
    /// 32:9 is detected automatically; "Packed SBS Input" extends that to any
    /// 3:1-or-wider frame.
    var isSBSStream: Bool {
        StreamPictureGeometry.isPackedStream(
            width: streamWidth,
            height: streamHeight,
            allowWide: StreamSettingsStore.shared.packedSBSInput
        )
    }

    /// A normal 2D stream shown as side-by-side 3D by converting it on device.
    var isRealtime3DActive: Bool {
        videoMode == .sideBySide3D && !isSBSStream
    }

    /// Maps the host frame onto what the window actually shows. In side-by-side
    /// 3D the picture is one eye's half, so absolute pointer and touch input
    /// must be compressed into that half instead of stretched over the frame.
    private func makeInputSize(width: Int32, height: Int32) -> StreamInputSize {
        let hostWidth = max(width, 1)
        let hostHeight = max(height, 1)
        let isSBS = videoMode == .sideBySide3D
            && StreamPictureGeometry.isPackedStream(
                width: Int(hostWidth),
                height: Int(hostHeight),
                allowWide: StreamSettingsStore.shared.packedSBSInput
            )
        return StreamInputSize(
            hostWidth: hostWidth,
            hostHeight: hostHeight,
            displayedWidth: isSBS ? max(hostWidth / 2, 1) : hostWidth,
            displayedHeight: hostHeight
        )
    }

    private var inputSize: StreamInputSize {
        let settings = StreamSettingsStore.shared
        return makeInputSize(
            width: activeConfig?.width ?? settings.resolution.width,
            height: activeConfig?.height ?? settings.resolution.height
        )
    }

    /// Applies the master Stereo 3D switch from the settings page to the live
    /// session.
    func setStereoSBS(_ enabled: Bool) {
        let mode: VideoMode = enabled ? .sideBySide3D : .standard2D
        guard videoMode != mode else { return }
        videoMode = mode
    }

    /// Re-applies the layout after the packed-input assertion changes.
    func refreshSBSLayout() {
        applyVideoModeChange()
    }

    /// Applies the anti-shimmer (mipmap) option to the live decoder.
    func setAntiShimmerMipmaps(_ enabled: Bool) {
        activeDecoder?.setMipmappedOutput(enabled)
    }

    /// Reconciles the stream with the current display mode: local 2D→3D needs
    /// a double-width texture and the decoder's stereo output.
    private func applyVideoModeChange() {
        let active = isRealtime3DActive
        realtime3DActivation.isActive = active
        refreshInputSize()

        guard let config = activeConfig else { return }
        let desiredWidth = max(1, Int(config.width) * (active ? 2 : 1))
        let needsTexture = videoTextureWidth != desiredWidth
        if needsTexture {
            prepareVideoTexture(for: config)
            frameMailbox.clear()
        }
        activeDecoder?.setStereoOutputEnabled(active, forceReattach: needsTexture)
        if isStreaming {
            LiRequestIdrFrame()
        }
    }

    private func refreshInputSize() {
        guard inputActive else { return }
        let size = inputSize
        touchInput.updateStreamSize(size)
        mouseStrategy?.updateStreamSize(size)
    }

    func toggleMute() {
        if volume > 0 {
            volumeBeforeMute = volume
            volume = 0
        } else {
            volume = volumeBeforeMute > 0 ? volumeBeforeMute : 1
        }
    }

    /// The renderer sizes its texture from the requested stream resolution, so
    /// wait until the window exists before connecting.
    func startWhenReady() async {
        guard !started else { return }
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
        // Stop GPU submission before the asynchronous connection teardown.
        activeDecoder?.setRenderingPaused(true)
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

    /// Rebuilds the connection in place, keeping the stream window and its
    /// chrome. Used when a setting that only applies at connect time changes.
    func restart() async {
        guard !isRestarting, !userInitiatedStop else { return }
        isRestarting = true
        defer { isRestarting = false }

        phase = .preparing
        teardownInput()
        statsTimer?.invalidate()
        statsTimer = nil
        statsText = ""
        connectionPoor = false
        showSBSConfirm = false
        frameMailbox.clear()
        videoTexture = nil
        videoTextureWidth = 0
        activeDecoder = nil
        realtime3DActivation.isActive = false

        let manager = streamManager
        streamManager = nil
        connectionDelegate = nil

        if let manager {
            await withCheckedContinuation { continuation in
                manager.stopStream {
                    continuation.resume()
                }
            }
        }

        guard !userInitiatedStop else { return }
        phase = .idle
        started = false
        await start()
    }

    /// Called from the stream scene when visionOS backgrounds or foregrounds the window.
    func setBackgrounded(_ backgrounded: Bool) {
        guard isBackgrounded != backgrounded else { return }
        isBackgrounded = backgrounded

        if backgrounded {
            // Metal rejects command buffers submitted from the background, so
            // stop GPU work immediately even if the connection is still up.
            if backgroundedAt == nil { backgroundedAt = Date() }
            activeDecoder?.setRenderingPaused(true)
            teardownInput()
            return
        }

        activeDecoder?.setRenderingPaused(false)
        switch phase {
        case .streaming, .connecting:
            if let config = activeConfig {
                setupInput(config: config)
            }
            // Frames were dropped while paused; the next one must be a keyframe.
            LiRequestIdrFrame()
        default:
            break
        }
    }

    /// Re-establishes the stream after the app returns from the background.
    /// visionOS suspends the process while another immersive app is running,
    /// so the host usually drops the session; the window stays open and the
    /// connection is rebuilt in place.
    /// Waits for the host's termination callback to settle, then reconnects
    /// if the session did not survive the background.
    func scheduleReconnectAfterBackground(force: Bool) {
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            reconnectAfterBackgroundIfNeeded(force: force)
        }
    }

    func reconnectAfterBackgroundIfNeeded(force: Bool = false) {
        guard !isBackgrounded else { return }
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        guard !userInitiatedStop, !isRestarting else { return }

        switch phase {
        case .ended:
            Task { await restart() }
        case .streaming, .connecting:
            // visionOS suspends us while another immersive app runs, so even
            // without an explicit termination the connection is usually gone.
            if force || away > 3 {
                Task { await restart() }
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
        realtime3DActivation.isActive = isRealtime3DActive
        prepareVideoTexture(for: config)
        setupInput(config: config)
        MVSetStreamVolume(Float(volume))
        MVSetStreamSpatialAudio(StreamSettingsStore.shared.spatialAudio)

        let delegate = StreamConnectionDelegate()
        delegate.onStage = { [weak self] stage in
            Task { @MainActor in
                guard let self, !self.hasEnded else { return }
                if case .streaming = self.phase {
                    return
                }
                self.phase = .connecting(stage: stage)
            }
        }
        delegate.onConnectionStatus = { [weak self] status in
            Task { @MainActor in
                guard let self, !self.hasEnded else { return }
                self.connectionPoor = (status == Int32(CONN_STATUS_POOR))
            }
        }
        delegate.onConnected = { [weak self] in
            Task { @MainActor in
                guard let self, !self.hasEnded else { return }
                self.controllerSupport?.connectionEstablished()
                if case .connecting = self.phase {
                    self.phase = .connecting(stage: String(localized: "Connected"))
                }
            }
        }
        delegate.onFirstFrame = { [weak self] in
            Task { @MainActor in
                guard let self, !self.hasEnded, self.streamManager != nil else { return }
                self.phase = .streaming
                self.refreshChromeVisibility()
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
        guard let texture = videoTexture else {
            finish(message: String(localized: "Could not start the stream."))
            return
        }
        let hdr = StreamSettingsStore.shared.hdrEnabled
        let mipmappedOutput = StreamSettingsStore.shared.antiShimmerMipmaps
        let renderingPaused = isBackgrounded
        let useFramePacing = config.useFramePacing
        let activation = realtime3DActivation
        let initialAspect = Float(streamAspect)
        guard let manager = StreamManager(
            config: config,
            rendererProvider: { [weak self] in
                let decoder = DrawableVideoDecoder(
                    texture: texture,
                    callbacks: delegate,
                    aspectRatio: initialAspect,
                    useFramePacing: useFramePacing,
                    enableHDR: hdr,
                    hdrSettingsProvider: nil,
                    enhancementsProvider: nil,
                    realtime3DSettingsProvider: {
                        Realtime3DSettingsStore.shared.settings(active: activation.isActive)
                    },
                    mipmappedOutput: mipmappedOutput,
                    callbackToRender: { [weak self] queue, _, _ in
                        self?.frameMailbox.deposit(queue)
                    }
                )
                // Must be set before setup(): it decides the initial queue width.
                decoder.setStereoOutputEnabled(self?.isRealtime3DActive ?? false)
                decoder.setRenderingPaused(renderingPaused)
                self?.activeDecoder = decoder
                return decoder
            },
            connectionCallbacks: delegate
        ) else {
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
        config.playAudioOnPC = settings.playAudioOnPC
        config.optimizeGameSettings = settings.optimizeGameSettings
        config.swapABXYButtons = settings.swapABXY
        config.multiController = settings.multiController
        config.gamepadMask = Int32(ControllerSupport.getConnectedGamepadMask(config))
        config.audioConfiguration = audioConfiguration(for: settings)
        config.supportedVideoFormats = preferredVideoFormats(settings: settings)

        return config
    }

    private func prepareVideoTexture(for config: StreamConfiguration) {
        // Local 2D→3D packs both eyes into one double-width frame.
        let multiplier = isRealtime3DActive ? 2 : 1
        let width = max(1, Int(config.width) * multiplier)
        let height = max(1, Int(config.height))
        videoTextureWidth = width
        let hdr = StreamSettingsStore.shared.hdrEnabled
        let bytesPerPixel = hdr ? 8 : 4
        let pixelFormat: MTLPixelFormat = hdr ? .rgba16Float : .bgra8Unorm_srgb
        do {
            videoTexture = try TextureResource(
                dimensions: .dimensions(width: width, height: height),
                format: .raw(pixelFormat: pixelFormat),
                contents: .init(
                    mipmapLevels: [
                        .mip(
                            data: Data(count: bytesPerPixel * width * height),
                            bytesPerRow: bytesPerPixel * width
                        )
                    ]
                )
            )
        } catch {
            NSLog("%@", "[Stream] Failed to create video texture \(width)x\(height): \(error)")
            videoTexture = try? TextureResource(
                dimensions: .dimensions(width: 1, height: 1),
                format: .raw(pixelFormat: .bgra8Unorm_srgb),
                contents: .init(mipmapLevels: [.mip(data: Data(count: 4), bytesPerRow: 4)])
            )
        }
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
        let hdrRequested = settings.hdrEnabled && settings.codec.supportsHDR

        // H.264 has no 10-bit profile. When HDR is requested the decoder sizes
        // its pixel buffers and texture for 10-bit, so never let the host pick
        // an 8-bit H.264 stream in that case.
        var formats: Int32 = hdrRequested ? 0 : Int32(VIDEO_FORMAT_H264)

        switch settings.codec {
        case .auto:
            if hevcSupported {
                formats |= Int32(VIDEO_FORMAT_H265)
                if hdrRequested && hostHEVCMain10 {
                    formats |= Int32(VIDEO_FORMAT_H265_MAIN10)
                }
            }
            // AV1 Main10 is not advertised on visionOS: VTIsHardwareDecodeSupported
            // is per-codec, not per-profile, and the Vision Pro AV1 decoder was
            // observed freezing on an HDR Main10 stream. Keep AV1 for SDR only.
            if av1Supported && !hdrRequested {
                formats |= Int32(VIDEO_FORMAT_AV1_MAIN8)
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
            // AV1 Main10 is not advertised on visionOS: VTIsHardwareDecodeSupported
            // is per-codec, not per-profile, and the Vision Pro AV1 decoder was
            // observed freezing on an HDR Main10 stream. Keep AV1 for SDR only.
            if av1Supported && !hdrRequested {
                formats |= Int32(VIDEO_FORMAT_AV1_MAIN8)
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
        // Request the user's selected layout and let AVAudioEngine downmix if
        // the current route has fewer channels, like the mature clients. Only
        // "Auto" follows the current hardware channel count.
        switch settings.audioMode {
        case .auto:
            let maxChannels = StreamSettingsStore.maximumOutputChannels
            if maxChannels >= 8 {
                return Int32(MVAudioConfiguration71())
            }
            if maxChannels >= 6 {
                return Int32(MVAudioConfiguration51())
            }
            return Int32(MVAudioConfigurationStereo())
        case .stereo:
            return Int32(MVAudioConfigurationStereo())
        case .surround51:
            return Int32(MVAudioConfiguration51())
        case .surround71:
            return Int32(MVAudioConfiguration71())
        }
    }

    // MARK: - Input

    private func setupInput(config: StreamConfiguration) {
        guard !inputActive else { return }
        inputActive = true

        // Receive raw gamepad events instead of letting visionOS turn them into
        // gaze/pinch events on the focused view.
        let gameController = GCEventInteraction()
        gameController.receivesEventsInView = false
        inputView.addInteraction(gameController)
        gameControllerInteraction = gameController

        let size = makeInputSize(width: config.width, height: config.height)
        touchInput.updateStreamSize(size)
        inputView.directTouchDelegate = touchInput
        inputView.onDirectTouchBegan = { [weak self] in
            self?.exitMouseCapture()
        }

        let settings = StreamSettingsStore.shared
        inputView.setTouchpadMode(settings.mouseInputMode == .touchpad)
        let strategy: any StreamMouseStrategy = TouchscreenGCMouseStrategy(localCursor: localCursor)
        mouseStrategy = strategy
        strategy.start(
            view: inputView,
            mode: settings.mouseMode,
            size: size,
            active: !isBackgrounded
        )
        strategy.onCaptureChanged = { [weak self] _ in
            self?.refreshChromeVisibility()
        }
        refreshChromeVisibility()

        let delegate = StreamControllerDelegate()
        delegate.onExitRequested = { [weak self] in
            Task { @MainActor in
                self?.stop()
            }
        }
        controllerDelegate = delegate
        controllerSupport = ControllerSupport(config: config, delegate: delegate)
    }

    // MARK: - Window chrome and mouse capture

    /// Re-evaluate whether the control ornament and system overlays should be
    /// hidden. The mouse captures on a click on the picture, so chrome hides
    /// only while a capture is active.
    func refreshChromeVisibility() {
        let settings = StreamSettingsStore.shared
        let captured = mouseStrategy?.isCaptured ?? false
        touchInput.setSuppressRestoreTap(settings.suppressRestoreTap)
        touchInput.setChromeHidden(captured)
        inputView.setTouchpadMode(settings.mouseInputMode == .touchpad)
        inputView.setTouchpadSuppressRestoreTap(settings.suppressRestoreTap)
        inputView.setTouchpadChromeHidden(captured)

        let shouldHide = settings.hideChromeDuringMouseInput && captured && isStreaming
        guard shouldHide != hidesStreamChrome else { return }
        hidesStreamChrome = shouldHide
        NSLog("[Stream] mouse captured=%d chrome hidden=%d", captured ? 1 : 0, shouldHide ? 1 : 0)
    }

    /// Releases mouse capture when the user gaze-taps the picture, and keeps
    /// that contact from also clicking the host.
    func exitMouseCapture() {
        guard let strategy = mouseStrategy, strategy.isCaptured else { return }
        if StreamSettingsStore.shared.suppressRestoreTap {
            touchInput.suppressNextContact()
        }
        strategy.setCaptured(false)
    }

    /// Applies a mouse tracking mode change to the live strategy.
    func setMouseMode(_ mode: MouseTrackingMode) {
        mouseStrategy?.setTrackingMode(mode)
    }

    /// Applies the ABXY swap without reconnecting.
    func setSwapABXY(_ swap: Bool) {
        controllerSupport?.applySwapABXYButtons(swap)
    }

    private func teardownInput() {
        guard inputActive else { return }
        inputActive = false

        inputView.releaseHeldKeys()
        touchInput.setChromeHidden(false)
        touchInput.cancelAll()
        inputView.directTouchDelegate = nil
        inputView.onDirectTouchBegan = nil
        mouseStrategy?.stop()
        mouseStrategy = nil
        hidesStreamChrome = false
        controllerSupport?.cleanup()
        controllerSupport = nil
        controllerDelegate = nil

        if let gameControllerInteraction {
            inputView.removeInteraction(gameControllerInteraction)
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
        showSBSConfirm = false
        realtime3DActivation.isActive = false
        activeDecoder = nil
        frameMailbox.clear()
        videoTexture = nil
        if case .ended = phase { return }
        phase = .ended(message)
    }

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let manager = self.streamManager else { return }
                guard StreamSettingsStore.shared.showStats else {
                    if !self.statsText.isEmpty {
                        self.statsText = ""
                    }
                    return
                }
                var text = manager.getStatsOverlayText() ?? ""
                if self.isRealtime3DActive,
                   let report = self.activeDecoder?.realtime3DReport() {
                    let inferMS = (report.inferenceSeconds ?? 0) * 1000
                    text += String(
                        format: "\n3D: depth age %d fr | stride %d | infer %.1f ms | synth %.1f ms",
                        report.depthAgeFrames, report.depthStride,
                        inferMS, report.synthesisSeconds * 1000
                    )
                }
                self.statsText = text
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
