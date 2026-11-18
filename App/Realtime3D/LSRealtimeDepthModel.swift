//
//  LSRealtimeDepthModel.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

/// 实时 3D 可选的深度模型。两个模型都随包发布，用户在影院控制面板切换，
/// 选择持久化在 `LSTheaterDisplaySettings`。
///
/// 2026-10-08 Mac 实测（M1 Pro ANE，同批测试帧）：
/// - Depth Anything V2 Small（518×392）：28.4ms/帧，深度更锐利；
/// - ZipDepth（768×416，ECCV 2026，MIT）：4.7ms/帧，与 DA V2 Small 的深度
///   相关性 +0.93~0.97、边缘略软；输入 16:9 原生（1.846）。
nonisolated enum LSRealtimeDepthModel: String, CaseIterable, Sendable, Equatable {
    /// 切换前的既有模型，也是默认值（真机对比验证前不改默认行为）。
    case depthAnythingV2Small
    /// 轻量卷积模型，速度约 6 倍，输入更大且 16:9 原生。
    case zipDepth

    static let `default`: LSRealtimeDepthModel = .depthAnythingV2Small

    /// 包内 `.mlmodelc` 资源名。
    var resourceName: String {
        switch self {
        case .depthAnythingV2Small: return "DepthAnythingV2SmallF16P6"
        case .zipDepth: return "ZipDepth768x416"
        }
    }

    /// 模型声明的固定输入尺寸。渲染器要在模型加载完成前就按它分配模型输入与
    /// 深度缓冲，所以是声明值；`LSRealtimeDepthModelSpecTests` 核对包内模型的
    /// 实际声明与这里一致。
    var inputWidth: Int {
        switch self {
        case .depthAnythingV2Small: return 518
        case .zipDepth: return 768
        }
    }

    var inputHeight: Int {
        switch self {
        case .depthAnythingV2Small: return 392
        case .zipDepth: return 416
        }
    }

    /// 控制面板卡片标题（同时是本地化 key）。
    var tileTitle: String {
        switch self {
        case .depthAnythingV2Small: return "Depth Anything V2"
        case .zipDepth: return "ZipDepth"
        }
    }

    /// 控制面板卡片图标。
    var tileSystemImage: String {
        switch self {
        case .depthAnythingV2Small: return "wand.and.stars"
        case .zipDepth: return "bolt"
        }
    }

    /// 日志用的显示名。
    var displayName: String {
        switch self {
        case .depthAnythingV2Small: return "Depth Anything V2 Small"
        case .zipDepth: return "ZipDepth"
        }
    }
}
