//
//  StreamRestartSettings.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

/// Settings that only take effect when the stream reconnects. The live settings
/// panel captures one of these when it opens and compares on close.
struct StreamRestartSettings: Equatable {
    var width: Int32
    var height: Int32
    var frameRate: Int
    var bitrateMbps: Int
    var codec: String
    var hdrEnabled: Bool
    var framePacing: Bool
    var audioMode: String
    var optimizeGameSettings: Bool
    var playAudioOnPC: Bool
    var multiController: Bool

    @MainActor
    init(_ settings: StreamSettingsStore = .shared) {
        width = settings.resolution.width
        height = settings.resolution.height
        frameRate = settings.frameRate
        bitrateMbps = settings.bitrateMbps
        codec = settings.codec.rawValue
        hdrEnabled = settings.hdrEnabled
        framePacing = settings.framePacing
        audioMode = settings.audioMode.rawValue
        optimizeGameSettings = settings.optimizeGameSettings
        playAudioOnPC = settings.playAudioOnPC
        multiController = settings.multiController
    }
}
