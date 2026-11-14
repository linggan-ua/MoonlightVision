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
        case .auto: return "Auto"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        }
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
        case .auto: return "Auto"
        case .stereo: return "Stereo"
        case .surround51: return "5.1 Surround"
        case .surround71: return "7.1 Surround"
        }
    }
}

@MainActor
@Observable
final class StreamSettingsStore {
    static let shared = StreamSettingsStore()

    private static let storageKey = "mv.streamSettings.v1"

    var resolution: StreamResolution {
        didSet { save() }
    }
    var frameRate: Int {
        didSet { save() }
    }
    var bitrateMbps: Int {
        didSet { save() }
    }
    var codec: CodecPreference {
        didSet { save() }
    }
    var hdrEnabled: Bool {
        didSet { save() }
    }
    var audioMode: AudioMode {
        didSet { save() }
    }
    var mouseMode: MouseTrackingMode {
        didSet { save() }
    }
    var showStats: Bool {
        didSet { save() }
    }
    var framePacing: Bool {
        didSet { save() }
    }
    var framePacingDepth: Int {
        didSet { save() }
    }
    var optimizeGameSettings: Bool {
        didSet { save() }
    }
    var playAudioOnPC: Bool {
        didSet { save() }
    }
    var swapABXY: Bool {
        didSet { save() }
    }
    var multiController: Bool {
        didSet { save() }
    }
    var spatialAudio: Bool {
        didSet { save() }
    }

    private struct Stored: Codable {
        var resolution: String
        var frameRate: Int
        var bitrateMbps: Int
        var codec: String
        var hdrEnabled: Bool
        var audioMode: String
        var mouseMode: String
        var showStats: Bool
        var framePacing: Bool?
        var framePacingDepth: Int?
        var optimizeGameSettings: Bool?
        var playAudioOnPC: Bool?
        var swapABXY: Bool?
        var multiController: Bool?
        var spatialAudio: Bool?
    }

    private init() {
        let stored: Stored? = {
            guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return nil }
            return try? JSONDecoder().decode(Stored.self, from: data)
        }()

        resolution = StreamResolution(rawValue: stored?.resolution ?? "") ?? .p1080
        let frameRateValue = stored?.frameRate ?? 60
        frameRate = [30, 60, 90, 120].contains(frameRateValue) ? frameRateValue : 60
        bitrateMbps = min(max(stored?.bitrateMbps ?? 10, 5), 150)
        codec = CodecPreference(rawValue: stored?.codec ?? "") ?? .auto
        hdrEnabled = stored?.hdrEnabled ?? false
        audioMode = AudioMode(rawValue: stored?.audioMode ?? "") ?? .auto
        mouseMode = MouseTrackingMode(rawValue: stored?.mouseMode ?? "") ?? .relative
        showStats = stored?.showStats ?? true
        framePacing = stored?.framePacing ?? true
        framePacingDepth = min(max(stored?.framePacingDepth ?? 0, 0), 3)
        optimizeGameSettings = stored?.optimizeGameSettings ?? true
        playAudioOnPC = stored?.playAudioOnPC ?? false
        swapABXY = stored?.swapABXY ?? false
        multiController = stored?.multiController ?? false
        spatialAudio = stored?.spatialAudio ?? false
    }

    private func save() {
        let stored = Stored(
            resolution: resolution.rawValue,
            frameRate: frameRate,
            bitrateMbps: bitrateMbps,
            codec: codec.rawValue,
            hdrEnabled: hdrEnabled,
            audioMode: audioMode.rawValue,
            mouseMode: mouseMode.rawValue,
            showStats: showStats,
            framePacing: framePacing,
            framePacingDepth: framePacingDepth,
            optimizeGameSettings: optimizeGameSettings,
            playAudioOnPC: playAudioOnPC,
            swapABXY: swapABXY,
            multiController: multiController,
            spatialAudio: spatialAudio
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    static var maximumOutputChannels: Int {
        Int(AVAudioSession.sharedInstance().maximumOutputNumberOfChannels)
    }
}
