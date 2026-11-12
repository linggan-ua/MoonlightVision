# MoonlightVision

visionOS 原生的 Moonlight（Sunshine / GameStream）客户端，基于官方 `moonlight-ios` 的 Limelight 核心重写。

## 功能

- **主机与串流**：mDNS 自动发现、手动添加、PIN 配对、应用列表与封面缓存、启动/恢复应用（含 host busy）、Wake-on-LAN、隐藏应用、断线重连与前后台守卫。
- **视频**：H.264 / HEVC / AV1，VideoToolbox 解码；HDR10（PQ / BT.2020）随流格式切换；窗口内曲面屏；SBS 3D 与实时 2D→3D（ANE 深度模型 + Metal 立体合成）；抗闪烁 mipmap。
- **音频**：AVAudioEngine + Opus 解码，立体声 / 5.1 / 7.1，空间音频开关。
- **输入**：手柄、物理键盘、GCMouse 指针捕获、整屏触控板、注视捏合触摸、虚拟键盘（PC 布局 + IME + 常用快捷键）。

## 构建

需要 **visionOS 27 SDK**。

```bash
xcodegen generate          # 由 project.yml 生成工程
open "Moonlight Vision.xcodeproj"
```

签名前请在 `project.yml` 填入你自己的 `DEVELOPMENT_TEAM`，并按需修改 `PRODUCT_BUNDLE_IDENTIFIER`。

命令行构建：

```bash
xcodebuild -project "Moonlight Vision.xcodeproj" -scheme "Moonlight Vision" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

## 底座

| 组件 | 版本 |
|---|---|
| `moonlight-stream/moonlight-ios` | `02dc978`（2026-09-26） |
| `moonlight-stream/moonlight-common-c` | `f900dd47` |
| 许可证 | GPL-3.0 + App Store Distribution Exception |

第三方组件与代码参考的归属见 [CREDITS.md](CREDITS.md)。

---

# MoonlightVision (English)

A native visionOS Moonlight client (Sunshine / GameStream), rebuilt on the Limelight core from the official `moonlight-ios`.

## Features

- **Hosts & streaming**: mDNS auto-discovery, manual add, PIN pairing, app list and cover cache, launch/resume apps (including host busy), Wake-on-LAN, hidden apps, reconnect and background/foreground guards.
- **Video**: H.264 / HEVC / AV1 via VideoToolbox; HDR10 (PQ / BT.2020) follows the stream format; in-window curved screen; SBS 3D and real-time 2D→3D (ANE depth model + Metal stereo synthesis); anti-shimmer mipmap.
- **Audio**: AVAudioEngine + Opus decoding, stereo / 5.1 / 7.1, spatial audio toggle.
- **Input**: gamepad, hardware keyboard, GCMouse pointer capture, full-screen touchpad, gaze-pinch touch, virtual keyboard (PC layout + IME + common shortcuts).

## Build

Requires the **visionOS 27 SDK**.

```bash
xcodegen generate          # generate the project from project.yml
open "Moonlight Vision.xcodeproj"
```

Before signing, fill in your own `DEVELOPMENT_TEAM` in `project.yml` and adjust `PRODUCT_BUNDLE_IDENTIFIER` as needed.

Command-line build:

```bash
xcodebuild -project "Moonlight Vision.xcodeproj" -scheme "Moonlight Vision" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
```

## Base

| Component | Version |
|---|---|
| `moonlight-stream/moonlight-ios` | `02dc978` (2026-09-26) |
| `moonlight-stream/moonlight-common-c` | `f900dd47` |
| License | GPL-3.0 + App Store Distribution Exception |

Third-party components and code references are credited in [CREDITS.md](CREDITS.md).
