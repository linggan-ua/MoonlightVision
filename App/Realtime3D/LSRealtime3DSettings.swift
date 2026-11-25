//
//  LSRealtime3DSettings.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

nonisolated struct LSRealtime3DSettings: Equatable, Sendable {
    static let disabled = LSRealtime3DSettings(
        isEnabled: false,
        depthStrength: 0.65,
        convergence: 0,
        swapsEyes: false,
        showsDepth: false,
        colorDepth: false
    )

    let isEnabled: Bool
    let depthStrength: Float
    let convergence: Float
    let swapsEyes: Bool
    /// Debug: draw the normalized depth map instead of the stereo image.
    let showsDepth: Bool
    /// Debug: colorize the depth preview (turbo colormap) instead of grayscale.
    let colorDepth: Bool
    /// 3D 方案（预设）：决定链路的算法组合，并给出默认深度模型。
    let scheme: LSRealtimeStereoScheme
    /// 深度模型覆盖（nil = 用方案默认）。管线测试与后续方案的模型对比用；
    /// 面板不给它单独的入口，避免和方案各说各话。
    let modelOverride: LSRealtimeDepthModel?
    /// 用户指定的深度刷新上限（maps/s；nil = 用方案默认，0 = 不限）。
    /// 方案决定算法，用户仍可单独限速。
    let depthRateOverride: Double?

    /// 本帧实际使用的深度模型。
    var model: LSRealtimeDepthModel { modelOverride ?? scheme.depthModel }

    /// 本帧实际使用的深度刷新上限。
    var effectiveDepthRateCap: Double {
        depthRateOverride ?? scheme.depthRateCapPerSecond
    }

    init(
        isEnabled: Bool,
        depthStrength: Float,
        convergence: Float,
        swapsEyes: Bool,
        showsDepth: Bool = false,
        colorDepth: Bool = false,
        scheme: LSRealtimeStereoScheme = .default,
        model: LSRealtimeDepthModel? = nil,
        depthRate: Double? = nil
    ) {
        self.isEnabled = isEnabled
        self.depthStrength = min(max(depthStrength, 0), 1)
        self.convergence = min(max(convergence, -1), 1)
        self.swapsEyes = swapsEyes
        self.showsDepth = showsDepth
        self.colorDepth = colorDepth
        self.scheme = scheme
        self.modelOverride = model
        self.depthRateOverride = depthRate.map { max($0, 0) }
    }
}
