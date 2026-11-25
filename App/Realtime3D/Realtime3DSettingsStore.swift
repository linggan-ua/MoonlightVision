//
//  Realtime3DSettingsStore.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//
//  Persisted settings for the real-time 2D→3D mode: scheme, depth strength,
//  convergence, model selection, maps/s override and eye swap.
//

import Foundation
import SwiftUI

final class Realtime3DSettingsStore: ObservableObject {
    static let shared = Realtime3DSettingsStore()

    @Published var isEnabled: Bool { didSet { save() } }
    @Published var scheme: LSRealtimeStereoScheme { didSet { save() } }
    /// 0…1; per-eye shift = depthStrength × 1.5 % of the picture width.
    @Published var depthStrength: Float { didSet { save() } }
    /// −1…+1; 0 puts the screen plane at the middle of the depth range.
    @Published var convergence: Float { didSet { save() } }
    /// nil = use the scheme's default model.
    @Published var model: LSRealtimeDepthModel? { didSet { save() } }
    /// maps/s override; nil = scheme default, 0 = unlimited.
    @Published var depthRate: Double? { didSet { save() } }
    @Published var swapsEyes: Bool { didSet { save() } }
    /// Debug: show the normalized depth map instead of the stereoscopic image.
    @Published var showsDepth: Bool { didSet { save() } }
    /// Debug: colorize the depth preview instead of drawing it in grayscale.
    @Published var colorDepth: Bool { didSet { save() } }

    /// Called after any persisted value changes (the stream view applies it).
    var onChange: (() -> Void)?

    private enum Key {
        static let enabled = "realtime3D.enabled"
        static let scheme = "realtime3D.scheme"
        static let depth = "realtime3D.depthStrength"
        static let convergence = "realtime3D.convergence"
        static let model = "realtime3D.model"
        static let rate = "realtime3D.depthRate"
        static let swapsEyes = "realtime3D.swapsEyes"
        static let showsDepth = "realtime3D.showsDepth"
        static let colorDepth = "realtime3D.colorDepth"
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        let storedScheme = defaults.string(forKey: Key.scheme)
            .flatMap(LSRealtimeStereoScheme.init(rawValue:)) ?? .default
        scheme = storedScheme
        let storedDepth = defaults.object(forKey: Key.depth) as? Float
        depthStrength = storedDepth ?? storedScheme.defaultDepthStrength
        convergence = defaults.object(forKey: Key.convergence) as? Float ?? 0
        model = defaults.string(forKey: Key.model)
            .flatMap(LSRealtimeDepthModel.init(rawValue:))
        if defaults.object(forKey: Key.rate) == nil {
            depthRate = nil
        } else {
            depthRate = defaults.double(forKey: Key.rate)
        }
        swapsEyes = defaults.bool(forKey: Key.swapsEyes)
        showsDepth = defaults.bool(forKey: Key.showsDepth)
        colorDepth = defaults.bool(forKey: Key.colorDepth)
    }

    /// Current configuration handed to the renderer/decoder.
    var settings: LSRealtime3DSettings {
        LSRealtime3DSettings(
            isEnabled: isEnabled,
            depthStrength: depthStrength,
            convergence: convergence,
            swapsEyes: swapsEyes,
            showsDepth: showsDepth,
            colorDepth: colorDepth,
            scheme: scheme,
            model: model,
            depthRate: depthRate
        )
    }

    /// Balanced preset = the scheme's default (Quest: model default).
    var balancedDepth: Float { scheme.defaultDepthStrength }
    /// Quest's presets are the model default ∓3 steps; one step is 0.1 %/eye,
    /// i.e. 0.2 of our depthStrength scale (100 % = 1.5 %/eye).
    var comfortDepth: Float { max(balancedDepth - 0.2, 0.05) }
    var strongDepth: Float { min(balancedDepth + 0.2, 1.0) }
    /// Values above the model default get the "harder on the eyes" warning.
    var exceedsComfortDefault: Bool { depthStrength > balancedDepth + 0.001 }

    func applyPreset(_ preset: Realtime3DPreset) {
        switch preset {
        case .comfort: depthStrength = comfortDepth
        case .balanced: depthStrength = balancedDepth
        case .strong: depthStrength = strongDepth
        }
    }

    func resetTuning() {
        resetDepth()
        resetConvergence()
    }

    /// Back to the scheme's default depth for a fresh install.
    func resetDepth() {
        depthStrength = balancedDepth
    }

    /// Zero puts the screen plane at the middle of the depth range.
    func resetConvergence() {
        convergence = 0
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(scheme.rawValue, forKey: Key.scheme)
        defaults.set(depthStrength, forKey: Key.depth)
        defaults.set(convergence, forKey: Key.convergence)
        if let model {
            defaults.set(model.rawValue, forKey: Key.model)
        } else {
            defaults.removeObject(forKey: Key.model)
        }
        if let depthRate {
            defaults.set(depthRate, forKey: Key.rate)
        } else {
            defaults.removeObject(forKey: Key.rate)
        }
        defaults.set(swapsEyes, forKey: Key.swapsEyes)
        defaults.set(showsDepth, forKey: Key.showsDepth)
        defaults.set(colorDepth, forKey: Key.colorDepth)
        onChange?()
    }
}

enum Realtime3DPreset: String, CaseIterable, Identifiable {
    case comfort
    case balanced
    case strong

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .comfort: return "realtime3d_preset_comfort"
        case .balanced: return "realtime3d_preset_balanced"
        case .strong: return "realtime3d_preset_strong"
        }
    }

    /// Which preset a depth value corresponds to. `nil` means the slider sits
    /// between presets, i.e. a custom value.
    static func matching(depth: Float, store: Realtime3DSettingsStore) -> Realtime3DPreset? {
        let tolerance: Float = 0.005
        if abs(depth - store.comfortDepth) <= tolerance { return .comfort }
        if abs(depth - store.balancedDepth) <= tolerance { return .balanced }
        if abs(depth - store.strongDepth) <= tolerance { return .strong }
        return nil
    }
}

/// Thread-safe activation flag. The decoder's per-frame settings provider runs
/// on the VideoToolbox output thread, so it cannot read the main-actor session
/// model directly.
nonisolated final class Realtime3DActivationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    var isActive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return active
        }
        set {
            lock.lock()
            active = newValue
            lock.unlock()
        }
    }
}

extension Realtime3DSettingsStore {
    /// Settings snapshot with the live activation flag, for the decoder.
    func settings(active: Bool) -> LSRealtime3DSettings {
        LSRealtime3DSettings(
            isEnabled: active,
            depthStrength: depthStrength,
            convergence: convergence,
            swapsEyes: swapsEyes,
            showsDepth: showsDepth,
            colorDepth: colorDepth,
            scheme: scheme,
            model: model,
            depthRate: depthRate
        )
    }
}
