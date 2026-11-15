//
//  StreamSettingsStore.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import AVFoundation
import Foundation
import Observation

enum StreamResolution: String, CaseIterable, Identifiable {
    case p720
    case p1080
    case p1440
    case p4k

    var id: String { rawValue }

    var width: Int32 {
        switch self {
        case .p720: return 1280
        case .p1080: return 1920
        case .p1440: return 2560
        case .p4k: return 3840
        }
    }

    var height: Int32 {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        case .p4k: return 2160
        }
    }

    var title: String {
        switch self {
        case .p720: return "1280 × 720"
        case .p1080: return "1920 × 1080"
        case .p1440: return "2560 × 1440"
        case .p4k: return "3840 × 2160 (4K)"
        }
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
    private static let mouseInputSchemeKey = "mv.mouseInputScheme"
    private static let hideChromeDuringMouseKey = "mv.hideChromeDuringMouseInput"
    private static let suppressRestoreTapKey = "mv.suppressRestoreTap"

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
    var mouseInputScheme: MouseInputScheme = .officialHybrid {
        didSet {
            UserDefaults.standard.set(mouseInputScheme.rawValue, forKey: Self.mouseInputSchemeKey)
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

        mouseInputScheme = MouseInputScheme(
            rawValue: UserDefaults.standard.string(forKey: Self.mouseInputSchemeKey) ?? ""
        ) ?? .officialHybrid
        hideChromeDuringMouseInput = UserDefaults.standard.object(forKey: Self.hideChromeDuringMouseKey) as? Bool ?? true
        suppressRestoreTap = UserDefaults.standard.bool(forKey: Self.suppressRestoreTapKey)
    }

    func reset() {
        applyDefaults()
        save()
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
        mouseInputScheme = .officialHybrid
        hideChromeDuringMouseInput = true
        suppressRestoreTap = false
        showStats = true
        framePacing = true
        optimizeGameSettings = true
        playAudioOnPC = false
        swapABXY = false
        multiController = false
        spatialAudio = false
    }

    private func apply(_ legacy: LegacyStored) {
        resolution = StreamResolution(rawValue: legacy.resolution) ?? .p1080
        frameRate = [30, 60, 90, 120].contains(legacy.frameRate) ? legacy.frameRate : 60
        bitrateMbps = min(max(legacy.bitrateMbps, 5), 150)
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
        resolution = StreamResolution.from(width: width, height: height) ?? .p1080

        let storedFrameRate = Int(official.framerate?.intValue ?? 60)
        frameRate = [30, 60, 90, 120].contains(storedFrameRate) ? storedFrameRate : 60
        bitrateMbps = min(max(Int(official.bitrate?.intValue ?? 10000) / 1000, 5), 150)
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

private extension StreamResolution {
    static func from(width: Int, height: Int) -> StreamResolution? {
        switch (width, height) {
        case (1280, 720): return .p720
        case (1920, 1080): return .p1080
        case (2560, 1440): return .p1440
        case (3840, 2160): return .p4k
        default: return nil
        }
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
