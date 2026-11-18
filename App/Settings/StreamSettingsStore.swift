//
//  StreamSettingsStore.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import AVFoundation
import Foundation
import Observation

struct StreamResolution: Hashable, Identifiable {
    var width: Int32
    var height: Int32

    var id: String { "\(width)x\(height)" }

    var title: String { "\(width) × \(height)" }

    var aspectRatio: Double {
        Double(width) / Double(max(height, 1))
    }

    var aspectDescription: String {
        let divisor = Self.gcd(Int(width), Int(height))
        guard divisor > 0 else { return "\(width):\(height)" }
        return "\(Int(width) / divisor):\(Int(height) / divisor)"
    }

    static let p720 = StreamResolution(width: 1280, height: 720)
    static let p1080 = StreamResolution(width: 1920, height: 1080)
    static let p1440 = StreamResolution(width: 2560, height: 1440)
    static let p4k = StreamResolution(width: 3840, height: 2160)

    static let presets: [StreamResolution] = [
        .p720, .p1080, .p1440, .p4k,
        StreamResolution(width: 5120, height: 2880),
        StreamResolution(width: 1920, height: 1200),
        StreamResolution(width: 2560, height: 1600),
        StreamResolution(width: 3440, height: 1440),
        // 32:9 is the side-by-side 3D frame shape (two 16:9 eyes).
        StreamResolution(width: 3840, height: 1080),
        StreamResolution(width: 3840, height: 1600),
        StreamResolution(width: 5120, height: 1440)
    ]

    static func legacy(_ rawValue: String) -> StreamResolution? {
        switch rawValue {
        case "p720": return .p720
        case "p1080": return .p1080
        case "p1440": return .p1440
        case "p4k": return .p4k
        default: return nil
        }
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a)
        var b = abs(b)
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }
}

enum CodecPreference: String, CaseIterable, Identifiable {
    case auto
    case h264
    case hevc
    case av1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        }
    }

    /// HDR10 requires a 10-bit codec. H.264 has no 10-bit profile.
    var supportsHDR: Bool {
        self != .h264
    }
}

enum AudioMode: String, CaseIterable, Identifiable {
    case auto
    case stereo
    case surround51
    case surround71

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .stereo: return String(localized: "Stereo")
        case .surround51: return String(localized: "5.1 Surround")
        case .surround71: return String(localized: "7.1 Surround")
        }
    }
}

@MainActor
@Observable
final class StreamSettingsStore {
    static let shared = StreamSettingsStore()

    private static let legacyStorageKey = "mv.streamSettings.v1"
    private static let migratedKey = "mv.settingsMigratedToCoreData"
    private static let audioModeKey = "mv.audioMode"
    private static let spatialAudioKey = "mv.spatialAudio"
    private static let mouseInputModeKey = "mv.mouseInputMode"
    private static let legacyTouchpadModeKey = "mv.touchpadMode"
    private static let hideChromeDuringMouseKey = "mv.hideChromeDuringMouseInput"
    private static let suppressRestoreTapKey = "mv.suppressRestoreTap"
    private static let stereoSBSKey = "mv.stereoSBS"
    private static let packedSBSInputKey = "mv.packedSBSInput"

    private let dataManager = DataManager()

    var resolution: StreamResolution = .p1080 {
        didSet { save() }
    }
    var frameRate: Int = 60 {
        didSet { save() }
    }
    var bitrateMbps: Int = 10 {
        didSet { save() }
    }
    var codec: CodecPreference = .auto {
        didSet { save() }
    }
    var hdrEnabled: Bool = false {
        didSet { save() }
    }
    var audioMode: AudioMode = .auto {
        didSet { save() }
    }
    var mouseMode: MouseTrackingMode = .relative {
        didSet { save() }
    }
    var mouseInputMode: MouseInputMode = .touchscreenGCMouse {
        didSet {
            UserDefaults.standard.set(mouseInputMode.rawValue, forKey: Self.mouseInputModeKey)
        }
    }
    /// While a physical mouse is connected during a stream, hide the control
    /// ornament, the system cursor, and window resizing so the pointer cannot
    /// wander onto visionOS window chrome.
    var hideChromeDuringMouseInput: Bool = true {
        didSet {
            UserDefaults.standard.set(hideChromeDuringMouseInput, forKey: Self.hideChromeDuringMouseKey)
        }
    }
    /// When the mouse has hidden the controls, make the first gaze tap only
    /// restore them instead of also sending a touch to the host.
    var suppressRestoreTap: Bool = false {
        didSet {
            UserDefaults.standard.set(suppressRestoreTap, forKey: Self.suppressRestoreTapKey)
        }
    }
    var showStats: Bool = true {
        didSet { save() }
    }
    var framePacing: Bool = true {
        didSet { save() }
    }
    var optimizeGameSettings: Bool = true {
        didSet { save() }
    }
    var playAudioOnPC: Bool = false {
        didSet { save() }
    }
    var swapABXY: Bool = false {
        didSet { save() }
    }
    var multiController: Bool = false {
        didSet { save() }
    }
    var spatialAudio: Bool = false {
        didSet { save() }
    }
    /// Present the stream through the window's side-by-side stereo plane.
    /// Mono streams are converted to stereo by the real-time 2D→3D pipeline
    /// (depth model + Metal synthesis); a packed SBS stream is split one half
    /// per eye. The tuning lives in `Realtime3DSettingsStore`.
    var stereoSBS: Bool = false {
        didSet {
            UserDefaults.standard.set(stereoSBS, forKey: Self.stereoSBSKey)
        }
    }
    /// Assert that a very wide (3:1 or wider) stream is already packed
    /// side-by-side instead of a mono frame to convert. Off by default: a
    /// 32:9 frame is still detected automatically; enable this for other
    /// packed sources.
    var packedSBSInput: Bool = false {
        didSet {
            UserDefaults.standard.set(packedSBSInput, forKey: Self.packedSBSInputKey)
        }
    }

    /// Only used for the one-time migration away from the old UserDefaults blob.
    private struct LegacyStored: Codable {
        var resolution: String
        var frameRate: Int
        var bitrateMbps: Int
        var codec: String
        var hdrEnabled: Bool
        var audioMode: String
        var mouseMode: String
        var showStats: Bool
        var framePacing: Bool?
        var optimizeGameSettings: Bool?
        var playAudioOnPC: Bool?
        var swapABXY: Bool?
        var multiController: Bool?
        var spatialAudio: Bool?
    }

    private init() {
        // Core Data's Settings.uniqueId is non-optional. HttpManager uses this
        // fixed the protocol client id, so seed the official settings record with
        // the same value before the first save.
        dataManager.updateUniqueId("0123456789ABCDEF")

        if !UserDefaults.standard.bool(forKey: Self.migratedKey) {
            if let legacy = Self.loadLegacy() {
                apply(legacy)
            } else {
                applyDefaults()
            }
            UserDefaults.standard.set(true, forKey: Self.migratedKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyStorageKey)
            save()
        } else {
            apply(official: dataManager.getSettings())
        }

        if let raw = UserDefaults.standard.string(forKey: Self.mouseInputModeKey),
           let mode = MouseInputMode(rawValue: raw) {
            mouseInputMode = mode
        } else {
            mouseInputMode = UserDefaults.standard.bool(forKey: Self.legacyTouchpadModeKey)
                ? .touchpad
                : .touchscreenGCMouse
        }
        hideChromeDuringMouseInput = UserDefaults.standard.object(forKey: Self.hideChromeDuringMouseKey) as? Bool ?? true
        suppressRestoreTap = UserDefaults.standard.bool(forKey: Self.suppressRestoreTapKey)
        stereoSBS = UserDefaults.standard.bool(forKey: Self.stereoSBSKey)
        packedSBSInput = UserDefaults.standard.bool(forKey: Self.packedSBSInputKey)
    }

    func reset() {
        applyDefaults()
        save()
        stereoSBS = false
        packedSBSInput = false
    }

    // MARK: - Loading

    private static func loadLegacy() -> LegacyStored? {
        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey) else { return nil }
        return try? JSONDecoder().decode(LegacyStored.self, from: data)
    }

    private func applyDefaults() {
        resolution = .p1080
        frameRate = 60
        bitrateMbps = 10
        codec = .auto
        hdrEnabled = false
        audioMode = .auto
        mouseMode = .relative
        mouseInputMode = .touchscreenGCMouse
        hideChromeDuringMouseInput = true
        suppressRestoreTap = false
        showStats = true
        framePacing = true
        optimizeGameSettings = true
        playAudioOnPC = false
        swapABXY = false
        multiController = false
        spatialAudio = false
        stereoSBS = false
        packedSBSInput = false
    }

    private func apply(_ legacy: LegacyStored) {
        resolution = StreamResolution.legacy(legacy.resolution) ?? .p1080
        frameRate = min(max(legacy.frameRate, 1), 240)
        bitrateMbps = min(max(legacy.bitrateMbps, 1), 1000)
        codec = CodecPreference(rawValue: legacy.codec) ?? .auto
        hdrEnabled = legacy.hdrEnabled
        audioMode = AudioMode(rawValue: legacy.audioMode) ?? .auto
        mouseMode = MouseTrackingMode(rawValue: legacy.mouseMode) ?? .relative
        showStats = legacy.showStats
        framePacing = legacy.framePacing ?? true
        optimizeGameSettings = legacy.optimizeGameSettings ?? true
        playAudioOnPC = legacy.playAudioOnPC ?? false
        swapABXY = legacy.swapABXY ?? false
        multiController = legacy.multiController ?? false
        spatialAudio = legacy.spatialAudio ?? false
    }

    private func apply(official: TemporarySettings?) {
        guard let official else {
            applyDefaults()
            return
        }

        let width = Int(official.width?.intValue ?? 1920)
        let height = Int(official.height?.intValue ?? 1080)
        resolution = StreamResolution(
            width: Int32(min(max(width, 160), 7680)),
            height: Int32(min(max(height, 120), 4320))
        )

        let storedFrameRate = Int(official.framerate?.intValue ?? 60)
        frameRate = min(max(storedFrameRate, 1), 240)
        bitrateMbps = min(max(Int(official.bitrate?.intValue ?? 10000) / 1000, 1), 1000)
        codec = CodecPreference(officialValue: Int(official.preferredCodecValue()))
        hdrEnabled = official.enableHdr
        mouseMode = official.absoluteTouchMode ? .absolute : .relative
        showStats = official.statsOverlay
        framePacing = official.useFramePacing
        optimizeGameSettings = official.optimizeGames
        playAudioOnPC = official.playAudioOnPC
        swapABXY = official.swapABXYButtons
        multiController = official.multiController
        audioMode = AudioMode(rawValue: UserDefaults.standard.string(forKey: Self.audioModeKey) ?? "") ?? .auto
        spatialAudio = UserDefaults.standard.bool(forKey: Self.spatialAudioKey)
    }

    // MARK: - Saving

    private func save() {
        dataManager.saveSettings(
            withBitrate: bitrateMbps * 1000,
            framerate: frameRate,
            height: Int(resolution.height),
            width: Int(resolution.width),
            audioConfig: Self.audioConfigValue(for: audioMode),
            onscreenControls: 0,
            optimizeGames: optimizeGameSettings,
            multiController: multiController,
            swapABXYButtons: swapABXY,
            audioOnPC: playAudioOnPC,
            preferredCodec: codec.officialValue,
            useFramePacing: framePacing,
            enableHdr: hdrEnabled,
            btMouseSupport: true,
            absoluteTouchMode: mouseMode == .absolute,
            statsOverlay: showStats
        )
        UserDefaults.standard.set(audioMode.rawValue, forKey: Self.audioModeKey)
        UserDefaults.standard.set(spatialAudio, forKey: Self.spatialAudioKey)
    }

    private static func audioConfigValue(for mode: AudioMode) -> Int {
        switch mode {
        case .auto, .stereo:
            return (0x3 << 16) | (2 << 8) | 0xCA
        case .surround51:
            return (0x3F << 16) | (6 << 8) | 0xCA
        case .surround71:
            return (0x63F << 16) | (8 << 8) | 0xCA
        }
    }

    static var maximumOutputChannels: Int {
        Int(AVAudioSession.sharedInstance().maximumOutputNumberOfChannels)
    }
}

private extension CodecPreference {
    init(officialValue: Int) {
        switch officialValue {
        case 1: self = .h264
        case 2: self = .hevc
        case 3: self = .av1
        default: self = .auto
        }
    }

    var officialValue: UInt32 {
        switch self {
        case .auto: return 0
        case .h264: return 1
        case .hevc: return 2
        case .av1: return 3
        }
    }
}
