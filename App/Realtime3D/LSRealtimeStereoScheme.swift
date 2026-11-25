//
//  LSRealtimeStereoScheme.swift
//  MoonlightVision
//
//  Created by Linggan-ua.
//

import Foundation

/// 实时 3D 的可切换方案（预设）。一个方案决定整条链路的算法组合：深度模型、
/// 视差合成、时域/切镜策略与投递调度。
///
/// **面板顺序 = 这里的声明顺序 = 按效果排序**（遮挡视差优先，其次平滑视差；
/// 同一合成内深度刷新越新越前），跟「省电」顺序相反。
///
/// 命名对照（2026-10-08 定稿改名，rawValue 不变、已存设置不受影响）：
///
/// | 面板显示 | rawValue（持久化键） |
/// | --- | --- |
/// | ZipDepth · 遮挡视差 逐帧 | fusion |
/// | ZipDepth · 遮挡视差 30/s | moonlightOptimized |
/// | ZipDepth · 遮挡视差 20/s | moonlightVerbatim |
/// | ZipDepth · 平滑视差 | legacyZipDepth |
/// | DA V2 · 平滑视差 | legacyDepthAnything |
///
/// 「平滑视差」= 自研合成（限斜率膨胀 + 固定点逆映射，不出空洞、边缘靠拉伸）；
/// 「遮挡视差」= 可见性合成（逐行遮挡求根 + 牛顿精修）；后缀是深度刷新档。
nonisolated enum LSRealtimeStereoScheme: String, CaseIterable, Sendable, Equatable {
    /// 面板第 1（效果最好）：遮挡视差 + 深度逐帧。
    /// rawValue 保持 `fusion` 以兼容已保存的方案选择。
    case fusion
    /// 面板第 2：遮挡视差 + 深度上限 30 maps/s（省电档）。
    case moonlightOptimized
    /// 面板第 3：遮挡视差、较柔和的轮廓——深度网格 1/4 画面、B 样条读深、
    /// 20 maps/s、带推理预算治理（最省）。
    case moonlightVerbatim
    /// 面板第 4：平滑视差 + ZipDepth（对照用）。原名 `.legacyZipDepth`。
    case legacyZipDepth
    /// 面板第 5：平滑视差 + Depth Anything V2（深度边最锐但推理慢，对照用）。
    /// 原名 `.legacyDepthAnything`。2026-10-11 前曾是全新安装的默认方案。
    case legacyDepthAnything

    /// 默认方案（全新安装与存量重置迁移都用它）：面板第 1、效果最好的
    /// 「ZipDepth · 遮挡视差 逐帧」。2026-10-11 由 `.legacyDepthAnything`
    /// 改来——存量用户的旧方案选择在 LSTheaterDisplaySettings 里一次性
    /// 作废重置为它，此后尊重用户在面板里的选择。
    static let `default`: LSRealtimeStereoScheme = .fusion

    /// 面板里可选的方案（全部已落地，顺序即上面的声明顺序）。
    static var implementedCases: [LSRealtimeStereoScheme] { allCases.filter(\.isImplemented) }

    var isImplemented: Bool { true }

    /// 方案默认的深度模型（遮挡视差三档都用 ZipDepth）。
    var depthModel: LSRealtimeDepthModel {
        switch self {
        case .legacyDepthAnything: return .depthAnythingV2Small
        case .fusion, .moonlightOptimized, .moonlightVerbatim, .legacyZipDepth: return .zipDepth
        }
    }

    /// 合成轴：可见性 gather + 牛顿精修（遮挡视差）或限斜率膨胀 + 固定点逆映射
    /// （平滑视差）。
    var usesVisibilityGather: Bool {
        switch self {
        case .fusion, .moonlightOptimized, .moonlightVerbatim: return true
        case .legacyZipDepth, .legacyDepthAnything: return false
        }
    }

    /// gather 之后的牛顿精修步数（他们的原值 2）。
    var gatherRefinementSteps: UInt32 { usesVisibilityGather ? 2 : 0 }

    /// 精修时深度沿行用三次 B 样条读：复刻他们的低分辨率深度读取。
    /// 我们的工作网格更细，只有完全照搬的方案需要。
    var gatherUsesCubicDepthRead: Bool { self == .moonlightVerbatim }

    /// 时域轴：真实时间一阶平均的时间常数（秒；0 = 老链路的按像素变化加权）。
    var temporalTauSeconds: Double { usesVisibilityGather ? 0.030 : 0 }

    /// 切镜轴：两级判定（jump + confirmed）。平滑视差用单一亮度阈值。
    var usesTwoStageCut: Bool { usesVisibilityGather }

    /// 深度速率上限（maps/s；0 = 不限，逐帧提交）。逐帧档 60；30/s 省电档；
    /// 20/s 是照搬他们的默认值。
    var depthRateCapPerSecond: Double {
        switch self {
        case .legacyDepthAnything, .legacyZipDepth: return 0
        case .fusion: return 60
        case .moonlightOptimized: return 30
        case .moonlightVerbatim: return 20
        }
    }

    /// 深度速率是否走「推理预算」治理（照搬档；他们的 governor 看显示节奏，
    /// 我们看推理耗时——见 governedDepthRate）。
    var usesDepthRateGovernor: Bool { self == .moonlightVerbatim }

    /// 工作网格（深度场与偏移图）长边的分母：照搬档用他们的低分辨率深度
    /// （画面长边的 1/4，夹到 [256, 960]），其余方案用统一的 960。
    var workingGridDivisor: Double { self == .moonlightVerbatim ? 4 : 1 }

    /// 全新安装时该方案的默认深度强度。遮挡视差三档与「ZipDepth · 平滑视差」用
    /// 40 %（每眼 0.6 % 画宽）；「DA V2 · 平滑视差」
    /// 用 15 %——它是对照档，深度更锐，弱一点更耐看。
    var defaultDepthStrength: Float {
        switch self {
        case .legacyDepthAnything: return 0.15
        case .fusion, .moonlightOptimized, .moonlightVerbatim, .legacyZipDepth: return 0.4
        }
    }

    /// 全新安装时该方案的默认汇聚。
    var defaultConvergence: Float { 0 }

    /// 深度滑条 reset 按钮写入的值（与全新安装默认一致；真机对比后若需要单独的
    /// 推荐值，再与 defaultDepthStrength 拆开）。
    var resetDepthStrength: Float { defaultDepthStrength }

    /// 汇聚滑条 reset 按钮写入的值。
    var resetConvergence: Float { 0 }

    /// 按方案算工作网格长边。
    static func workingMaximumSide(frameLongSide: Int, divisor: Double) -> Int {
        guard divisor > 1 else { return 960 }
        let quarter = Int((Double(frameLongSide) / divisor).rounded())
        return min(max(quarter, 256), 960)
    }

    /// 推理预算治理（纯函数）：最近 8 次推理的中位超过上限周期的 0.8 → 上限减半
    /// （下限 10/s）；最近 8 次全部低于上限周期的 0.4 → 逐级恢复（不超过方案上限）。
    static func governedDepthRate(current: Double, schemeCap: Double,
                                  recentSeconds: [Double]) -> Double {
        guard schemeCap > 0, recentSeconds.count >= 8 else { return current }
        let window = Array(recentSeconds.suffix(8))
        let capInterval = 1.0 / current
        let median = window.sorted()[window.count / 2]
        if median > capInterval * 0.8 {
            return max(current / 2, 10)
        }
        if window.allSatisfy({ $0 < (1.0 / schemeCap) * 0.4 }) {
            return min(current * 2, schemeCap)
        }
        return current
    }

    /// 真实时间一阶平均的权重：α = 1 − e^(−dt/τ)，depthTauAlpha 同式
    /// （纯函数，便于单测）。
    static func temporalAlpha(dt: Double, tau: Double) -> Float {
        guard tau > 0, dt.isFinite else { return 1 }
        return Float(1 - exp(-max(dt, 0) / tau))
    }

    /// 距上次提交是否已经过一个速率上限周期（纯函数，便于单测）。
    static func depthSubmissionDue(elapsed: Double, capPerSecond: Double) -> Bool {
        guard capPerSecond > 0 else { return true }
        return elapsed >= 1.0 / capPerSecond
    }

    /// 控制面板卡片标题（同时是本地化 key）：前半是深度模型，后半是合成链路与
    /// 刷新档位。改名对照见类型文档。
    var tileTitle: String {
        switch self {
        case .fusion: return "ZipDepth · Occlusion Per-Frame"
        case .moonlightOptimized: return "ZipDepth · Occlusion 30/s"
        case .moonlightVerbatim: return "ZipDepth · Occlusion 20/s"
        case .legacyZipDepth: return "ZipDepth · Smooth Parallax"
        case .legacyDepthAnything: return "DA V2 · Smooth Parallax"
        }
    }

    /// 控制面板卡片图标：五个方案统一用立体（3D）图标——差异由名字表达，
    /// 图标只负责"这是实时 3D"。
    var tileSystemImage: String { "cube.transparent" }

    /// 日志用的显示名（与卡片标题同口径）。
    var displayName: String {
        switch self {
        case .fusion: return "ZipDepth · occlusion per-frame"
        case .moonlightOptimized: return "ZipDepth · occlusion 30/s"
        case .moonlightVerbatim: return "ZipDepth · occlusion 20/s"
        case .legacyZipDepth: return "ZipDepth · smooth parallax"
        case .legacyDepthAnything: return "DA V2 · smooth parallax"
        }
    }
}
