//
//  StreamAudioRenderer.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import AVFoundation
import Foundation

/// Fresh visionOS audio output for the stream.
///
/// Structure adapted from an earlier GPL-3.0 project: AVAudioEngine with a
/// pull-based AVAudioSourceNode, an explicit channel layout for 5.1/7.1, the
/// GameStream 7.1 channel-order fix, and AVAudioSession spatial experience.
/// Ring-buffer parameters and engine recovery follow an earlier GPL-3.0 project's StreamAudioOutput
/// (GPL-3.0): 100 ms capacity, 20 ms priming, trim 60 ms down to 30 ms, and
/// restart on configuration changes, interruptions and media-service resets.
@objc(MVStreamAudioRenderer)
public final class StreamAudioRenderer: NSObject {
    private static let capacitySeconds = 0.100
    private static let primeSeconds = 0.020
    private static let trimAboveSeconds = 0.060
    private static let trimToSeconds = 0.030

    private let ring = AudioRingBuffer()
    private let lifecycleLock = NSLock()
    private let engineQueue = DispatchQueue(label: "com.moonlightvision.audio.engine")

    private var decoder: OpaquePointer?
    private var channelCount = 0
    private var sampleRate = 0
    private var samplesPerFrame = 0
    private var pcmBuffer: [Float] = []

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    private var volume: Float = 1.0
    private var spatialAudioEnabled = false
    private var running = false
    private var stopped = false
    private var lastRecoveryTime: CFAbsoluteTime = 0
    private let stateLock = NSLock()
    private var engineIsRunning = false

    @objc(initWithOpusConfig:)
    public init?(opusConfig: UnsafePointer<OPUS_MULTISTREAM_CONFIGURATION>) {
        super.init()

        let config = opusConfig.pointee
        channelCount = Int(config.channelCount)
        sampleRate = Int(config.sampleRate)
        samplesPerFrame = Int(config.samplesPerFrame)
        guard channelCount > 0, sampleRate > 0, samplesPerFrame > 0 else { return nil }

        pcmBuffer = [Float](repeating: 0, count: samplesPerFrame * channelCount)
        ring.configure(
            sampleRate: sampleRate,
            channels: channelCount,
            capacitySeconds: Self.capacitySeconds,
            primeSeconds: Self.primeSeconds,
            trimAboveSeconds: Self.trimAboveSeconds,
            trimToSeconds: Self.trimToSeconds
        )

        // GameStream's 7.1 order is FL FR C LFE BL BR SL SR; CoreAudio's MPEG 7.1 C
        // expects the side pair before the rear pair, so swap them in the mapping.
        var mapping = withUnsafeBytes(of: config.mapping) { Array($0) }
        if channelCount == 8 {
            mapping.swapAt(4, 6)
            mapping.swapAt(5, 7)
        }

        var error: Int32 = 0
        decoder = mapping.withUnsafeBufferPointer { pointer in
            opus_multistream_decoder_create(
                Int32(sampleRate),
                Int32(channelCount),
                config.streams,
                config.coupledStreams,
                pointer.baseAddress!,
                &error
            )
        }
        guard error == 0, decoder != nil else {
            decoder = nil
            return nil
        }
    }

    deinit {
        cleanup()
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }

    private var isEngineRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return engineIsRunning
    }

    private func setEngineRunning(_ value: Bool) {
        stateLock.lock()
        engineIsRunning = value
        stateLock.unlock()
    }

    private var isStopped: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return stopped
    }

    // MARK: - Lifecycle (called by the core's Ar callbacks)

    @objc public func start() {
        engineQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.setRunning(true)
            self.installObserversIfNeeded()
            if self.engine == nil {
                self.buildEngine()
            } else {
                self.activateSession()
                self.startEngine(reason: "start")
            }
        }
    }

    @objc public func stop() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.setRunning(false)
            self.engine?.stop()
            self.setEngineRunning(false)
            self.deactivateSession()
        }
    }

    @objc public func setVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.volume = clamped
            self.engine?.mainMixerNode.outputVolume = clamped
        }
    }

    @objc public func setSpatialAudio(_ enabled: Bool) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.spatialAudioEnabled = enabled
            self.applySpatialExperience()
        }
    }

    @objc public func cleanup() {
        lifecycleLock.lock()
        stopped = true
        let decoderToDestroy = decoder
        decoder = nil
        lifecycleLock.unlock()

        engineQueue.sync {
            setRunning(false)
            setEngineRunning(false)
            if let sourceNode, let engine {
                engine.detach(sourceNode)
            }
            engine?.stop()
            engine = nil
            sourceNode = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let engineObserver {
                NotificationCenter.default.removeObserver(engineObserver)
                self.engineObserver = nil
            }
            self.deactivateSession()
        }

        if let decoderToDestroy {
            opus_multistream_decoder_destroy(decoderToDestroy)
        }
    }

    // MARK: - Decode (called on the core's audio thread)

    @objc(decodeAndPlaySample:length:)
    public func decodeAndPlaySample(_ data: UnsafeMutablePointer<CChar>?, length: Int32) {
        // The official/Starlight audio paths drop packets when the core's audio
        // queue is already backing up, instead of decoding stale packets forever.
        if LiGetPendingAudioDuration() > 30 {
            return
        }

        lifecycleLock.lock()
        guard !stopped, let decoder else {
            lifecycleLock.unlock()
            return
        }

        let decoded = pcmBuffer.withUnsafeMutableBufferPointer { output -> Int32 in
            if let data {
                return data.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { input in
                    opus_multistream_decode_float(
                        decoder,
                        input,
                        length,
                        output.baseAddress!,
                        Int32(samplesPerFrame),
                        0
                    )
                }
            }
            // Packet loss: let Opus synthesize a concealment frame.
            return opus_multistream_decode_float(
                decoder,
                nil,
                0,
                output.baseAddress!,
                Int32(samplesPerFrame),
                0
            )
        }
        lifecycleLock.unlock()

        guard decoded > 0 else { return }
        pcmBuffer.withUnsafeBufferPointer { samples in
            ring.write(samples.baseAddress!, frames: Int(decoded))
        }
        recoverEngineIfNeeded()
    }

    // MARK: - Engine

    private func channelLayoutTag() -> AudioChannelLayoutTag {
        switch channelCount {
        case 2: return kAudioChannelLayoutTag_Stereo
        case 6: return kAudioChannelLayoutTag_MPEG_5_1_A
        case 8: return kAudioChannelLayoutTag_MPEG_7_1_C
        default: return kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
        }
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try? session.setPreferredSampleRate(Double(sampleRate))
            try? session.setPreferredIOBufferDuration(0.005)
            if session.maximumOutputNumberOfChannels >= channelCount {
                try? session.setPreferredOutputNumberOfChannels(channelCount)
            }
            #if os(visionOS)
            applySpatialExperience()
            #endif
            try session.setActive(true)
        } catch {
            NSLog("[Audio] session activation failed: %@", error.localizedDescription)
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    #if os(visionOS)
    private func applySpatialExperience() {
        let session = AVAudioSession.sharedInstance()
        if spatialAudioEnabled {
            try? session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic)
            )
        } else {
            try? session.setIntendedSpatialExperience(.bypassed)
        }
    }
    #endif

    private func buildEngine() {
        activateSession()

        guard let layout = AVAudioChannelLayout(layoutTag: channelLayoutTag()) else {
            NSLog("[Audio] unsupported channel layout for %d channels", channelCount)
            return
        }
        let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate),
            channelLayout: layout
        )

        let engine = AVAudioEngine()
        installEngineObserver(for: engine)
        let ring = self.ring
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            ring.read(
                into: UnsafeMutableAudioBufferListPointer(audioBufferList),
                frames: Int(frameCount),
                isSilence: isSilence
            )
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        // Ask the output for the stream's channel count only when the route can
        // actually take it; otherwise the mixer downmixes to the hardware format.
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        if hardware.channelCount >= AVAudioChannelCount(channelCount) {
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        }

        engine.prepare()
        do {
            try engine.start()
            engine.mainMixerNode.outputVolume = volume
            self.engine = engine
            self.sourceNode = node
            self.setEngineRunning(true)
        } catch {
            NSLog("[Audio] engine start failed: %@", error.localizedDescription)
            engine.detach(node)
            self.setEngineRunning(false)
        }
    }

    private func startEngine(reason: String) {
        guard let engine else { return }
        do {
            try engine.start()
            setEngineRunning(true)
        } catch {
            setEngineRunning(false)
            NSLog("[Audio] engine restart failed (%@): %@", reason, error.localizedDescription)
        }
    }

    private func recoverEngineIfNeeded() {
        guard isRunning else { return }
        guard !isEngineRunning else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRecoveryTime >= 1.0 else { return }
        lastRecoveryTime = now
        engineQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            if self.engine == nil {
                self.buildEngine()
            } else {
                self.activateSession()
                self.startEngine(reason: "framesWithoutEngine")
            }
        }
    }

    private func installEngineObserver(for engine: AVAudioEngine) {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.engineQueue.async {
                guard let self, self.isRunning else { return }
                self.activateSession()
                self.startEngine(reason: "configurationChange")
            }
        }
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .ended else { return }
            self.engineQueue.async {
                guard self.isRunning else { return }
                self.activateSession()
                self.startEngine(reason: "interruptionEnded")
            }
        }

        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.engineQueue.async {
                guard let self, self.isRunning else { return }
                if let sourceNode = self.sourceNode {
                    self.engine?.detach(sourceNode)
                }
                self.engine?.stop()
                self.engine = nil
                self.sourceNode = nil
                self.buildEngine()
            }
        }
    }
}

/// Lock-free single-producer/single-consumer interleaved float ring.
///
/// Backed by the vendored ring buffer (zlib, the same ring the official
/// the protocol audio output used) through MVAudioRing. The network/audio decode
/// thread writes whole Opus frames; the AVAudioSourceNode render thread reads
/// and deinterleaves them. The render callback never takes a lock. Backlog
/// trimming happens on the consumer side, so it cannot race the producer.
final class AudioRingBuffer: @unchecked Sendable {
    private var ring: OpaquePointer?
    private var scratch: UnsafeMutablePointer<Float>?
    private var sampleRate = 0
    private var channels = 0
    private var capacityFrames = 0
    private var bytesPerFrame = 0
    private var primeFrames = 0
    private var trimAboveFrames = 0
    private var trimToFrames = 0
    private var priming = true
    private(set) var underruns: Int64 = 0
    private(set) var overflowFrames: Int64 = 0
    private(set) var trimmedFrames: Int64 = 0

    deinit {
        destroy()
    }

    func configure(
        sampleRate: Int,
        channels: Int,
        capacitySeconds: Double,
        primeSeconds: Double,
        trimAboveSeconds: Double,
        trimToSeconds: Double
    ) {
        destroy()

        self.sampleRate = sampleRate
        self.channels = channels
        self.capacityFrames = max(Int(Double(sampleRate) * capacitySeconds), 1)
        self.bytesPerFrame = channels * MemoryLayout<Float>.size
        self.primeFrames = min(Int(Double(sampleRate) * primeSeconds), capacityFrames)
        self.trimAboveFrames = min(Int(Double(sampleRate) * trimAboveSeconds), capacityFrames)
        self.trimToFrames = min(Int(Double(sampleRate) * trimToSeconds), trimAboveFrames)
        self.priming = true
        self.underruns = 0
        self.overflowFrames = 0
        self.trimmedFrames = 0

        guard channels > 0, bytesPerFrame > 0 else { return }
        let capacityBytes = capacityFrames * bytesPerFrame
        ring = MVAudioRingCreate(UInt32(capacityBytes))
        if ring == nil {
            NSLog("[Audio] TPCircularBuffer allocation failed (%d bytes)", capacityBytes)
            return
        }
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * channels)
    }

    private func destroy() {
        if let ring {
            MVAudioRingDestroy(ring)
            self.ring = nil
        }
        scratch?.deallocate()
        scratch = nil
    }

    func write(_ samples: UnsafePointer<Float>, frames: Int) {
        guard let ring, frames > 0, bytesPerFrame > 0 else { return }
        let requested = frames * bytesPerFrame
        let written = Int(MVAudioRingWrite(ring, UnsafeRawPointer(samples), UInt32(requested)))
        if written < requested {
            overflowFrames += Int64((requested - written) / bytesPerFrame)
        }
    }

    func read(
        into buffers: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        isSilence: UnsafeMutablePointer<ObjCBool>
    ) {
        guard let ring, let scratch, channels > 0, bytesPerFrame > 0 else {
            outputSilence(buffers, isSilence: isSilence)
            return
        }

        var availableFrames = Int(MVAudioRingAvailableBytes(ring)) / bytesPerFrame

        if priming {
            if availableFrames < primeFrames {
                outputSilence(buffers, isSilence: isSilence)
                return
            }
            priming = false
        }

        // Trim on the consumer thread only. Advancing the producer side would
        // break the single-producer contract of the ring.
        if availableFrames > trimAboveFrames {
            let dropFrames = availableFrames - trimToFrames
            MVAudioRingSkip(ring, UInt32(dropFrames * bytesPerFrame))
            trimmedFrames += Int64(dropFrames)
            availableFrames = trimToFrames
        }

        let framesToRead = min(frames, availableFrames)
        if framesToRead > 0 {
            _ = MVAudioRingRead(ring, UnsafeMutableRawPointer(scratch), UInt32(framesToRead * bytesPerFrame))
        }

        // Deinterleave into the non-interleaved AudioBufferList.
        for (channel, buffer) in buffers.enumerated() {
            guard let output = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for index in 0..<frames {
                if index < framesToRead, channel < channels {
                    output[index] = scratch[index * channels + channel]
                } else {
                    output[index] = 0
                }
            }
        }

        if availableFrames < frames {
            underruns += 1
            priming = true
        }
        isSilence.pointee = ObjCBool(framesToRead == 0)
    }

    private func outputSilence(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        isSilence: UnsafeMutablePointer<ObjCBool>
    ) {
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        isSilence.pointee = true
    }

    var bufferedMilliseconds: Double {
        guard let ring, sampleRate > 0, bytesPerFrame > 0 else { return 0 }
        let frames = Double(MVAudioRingAvailableBytes(ring)) / Double(bytesPerFrame)
        return frames * 1000 / Double(sampleRate)
    }
}
