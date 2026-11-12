# Vendored sources

本目录只包含从上游复制进来的第三方代码与二进制库。所有版本与来源记录在此，升级时按此核对。

## Limelight（官方 moonlight-ios 核心）

- 上游：https://github.com/moonlight-stream/moonlight-ios
- Commit：`02dc9780496eeeac6d01c8bbdccb8b6fe71ef28a`（2026-09-26）
- 复制范围：`Crypto`、`Database`、`Input`、`Network`、`Stream`、`Utility`、`Limelight.xcdatamodeld`、`Limelight-Prefix.pch`、`AppDelegate.h/.m`
- 未复制：storyboards、`Images.xcassets`、`Font`、`ViewControllers`、X1Kit（新 app 层不使用 UIKit 流界面，也不需要 X1 鼠标）
- 许可：GPL-3.0 + App Store Distribution Exception（见 `Limelight/LICENSE.txt`）

## moonlight-common-c

- 上游：https://github.com/moonlight-stream/moonlight-common-c
- Commit：`f900dd4767759c7b9d0e93bcea666b55c69ea62f`（moonlight-ios 固定版本）
- 包含 `src/`、`enet/`（含其子模块）、`nanors/`
- 编译排除：`src/ConnectionTester.c`（独立测试程序）

## FFmpeg

- 设备版与模拟器版均已构建：`ThirdParty/FFmpeg/lib/visionOS`（platform visionOS）与 `lib/visionOS-Sim`（platform visionOS Simulator），arm64 / minos 27.0，均来自 FFmpeg rev `3f890fbf`（2023-11）。
- 以 `libavcodec.xcframework`、`libavformat.xcframework`、`libavutil.xcframework` 提供（含 device + simulator 切片）。
- 配置：`--disable-everything` + AV1 decoder + flv muxer，无外部依赖。
- 头文件：60.32.102 / 58.31.100（`ThirdParty/FFmpeg/include`）。

## opus

- 设备版与模拟器版：opus v1.4，arm64 / minos 27.0，以 `libopus.xcframework` 提供（device platform 11 + simulator platform 12）。

## 音频

- 不使用上游的 CoreAudio 栈，也不链接 SDL2。音频由 `App/Audio/StreamAudioRenderer.swift` 全新实现：`AVAudioEngine` + `AVAudioSourceNode`，立体声/5.1/7.1，visionOS `intendedSpatialExperience`，100 ms ring / 20 ms prime / 60→30 ms trim，包含配置变化、中断和媒体服务重置后的恢复。
- `Connection.m` 的 `ArInit/ArStart/ArStop/ArCleanup/ArDecodeAndPlaySample` 通过生成的 `MoonlightVision-Swift.h` 调用 `MVStreamAudioRenderer`。
- `Vendor/Limelight/Audio` 已删除；`ThirdParty/SDL2` 仅保留作历史参考，不参与构建。

## OpenSSL

- Swift Package Manager：`https://github.com/krzyzanowskim/OpenSSL`，`from: 3.6.3000`（上游 PR #635 起支持 visionOS；解析到 3.6.5000，包含 visionsimulator 切片）。

## 部署目标

- `XROS_DEPLOYMENT_TARGET = 27.0`（FFmpeg/opus 的 device/simulator 切片均为 minos 27.0）。
- 同时支持真机（`xros`）与模拟器（`xrsimulator`）。

---

# Vendored sources (English)

This directory contains only third-party code and binary libraries copied from upstream. Versions and origins are recorded here; check them when upgrading.

## Limelight (official moonlight-ios core)

- Upstream: https://github.com/moonlight-stream/moonlight-ios
- Commit: `02dc9780496eeeac6d01c8bbdccb8b6fe71ef28a` (2026-09-26)
- Copied: `Crypto`, `Database`, `Input`, `Network`, `Stream`, `Utility`, `Limelight.xcdatamodeld`, `Limelight-Prefix.pch`, `AppDelegate.h/.m`
- Not copied: storyboards, `Images.xcassets`, `Font`, `ViewControllers`, X1Kit (the new app layer does not use the UIKit stream UI and does not need the X1 mouse)
- License: GPL-3.0 + App Store Distribution Exception (see `Limelight/LICENSE.txt`)

## moonlight-common-c

- Upstream: https://github.com/moonlight-stream/moonlight-common-c
- Commit: `f900dd4767759c7b9d0e93bcea666b55c69ea62f` (the revision pinned by moonlight-ios)
- Contains `src/`, `enet/` (with its submodules), `nanors/`
- Excluded from the build: `src/ConnectionTester.c` (standalone test program)

## FFmpeg

- Device and simulator builds: `ThirdParty/FFmpeg/lib/visionOS` (platform visionOS) and `lib/visionOS-Sim` (platform visionOS Simulator), arm64 / minos 27.0, both from FFmpeg rev `3f890fbf` (2023-11).
- Shipped as `libavcodec.xcframework`, `libavformat.xcframework` and `libavutil.xcframework` (device + simulator slices).
- Configuration: `--disable-everything` + AV1 decoder + flv muxer, no external dependencies.
- Headers: 60.32.102 / 58.31.100 (`ThirdParty/FFmpeg/include`).

## opus

- Device and simulator: opus v1.4, arm64 / minos 27.0, shipped as `libopus.xcframework` (device platform 11 + simulator platform 12).

## Audio

- The upstream CoreAudio stack is not used and SDL2 is not linked. Audio is a fresh implementation in `App/Audio/StreamAudioRenderer.swift`: `AVAudioEngine` + `AVAudioSourceNode`, stereo/5.1/7.1, the visionOS `intendedSpatialExperience`, a 100 ms ring / 20 ms prime / 60→30 ms trim, and recovery after configuration changes, interruptions and media-service resets.
- `ArInit/ArStart/ArStop/ArCleanup/ArDecodeAndPlaySample` in `Connection.m` call `MVStreamAudioRenderer` through the generated `MoonlightVision-Swift.h`.
- `Vendor/Limelight/Audio` has been removed; `ThirdParty/SDL2` is kept for historical reference only and is not part of the build.

## OpenSSL

- Swift Package Manager: `https://github.com/krzyzanowskim/OpenSSL`, `from: 3.6.3000` (visionOS supported since upstream PR #635; resolves to 3.6.5000, including a visionsimulator slice).

## Deployment Target

- `XROS_DEPLOYMENT_TARGET = 27.0` (the FFmpeg/opus device and simulator slices are all minos 27.0).
- Supported on both device (`xros`) and simulator (`xrsimulator`).
