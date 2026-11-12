# 第三方组件与致谢

本仓库以官方 Moonlight 客户端为底座，并使用了若干第三方组件与代码参考。所有归属在本文件中集中声明。

## 核心底座

| 组件 | 位置 | 许可证 |
|---|---|---|
| [moonlight-ios](https://github.com/moonlight-stream/moonlight-ios)（Limelight，Objective-C） | `Vendor/Limelight` | GPL-3.0 + App Store Distribution Exception |
| [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | `Vendor/moonlight-common-c` | GPL-3.0 + App Store Distribution Exception |

两个组件在 `Vendor/` 下各自带有 `LICENSE.txt` 原件。`App/Video/DrawableVideoDecoder.swift` 亦源自 Limelight 的渲染器，保留其版权声明。

App Store Distribution Exception 允许在源代码同样以 GPL 提供的前提下通过应用商店分发。

## 内置第三方库

| 组件 | 位置 | 许可证 |
|---|---|---|
| 环形缓冲实现（原 TPCircularBuffer，已改名） | `App/Audio/MVRingBuffer.{h,c}` | MIT/zlib，© Michael Tyson |
| [libopus](https://opus-codec.org/) | `Vendor/ThirdParty/opus` | BSD-3-Clause |
| [FFmpeg](https://ffmpeg.org/) | `Vendor/ThirdParty/FFmpeg` | LGPL / GPL |
| [OpenSSL](https://www.openssl.org/)（SwiftPM 依赖） | — | Apache-2.0 |

> **注意**：`libopus` 与 `FFmpeg` 在 `Vendor/ThirdParty/` 下只有二进制与头文件，**没有随附许可证文本**。公开发布前应补入各自的 `COPYING`/`LICENSE`。`FFmpeg` 当前已链接但源码中没有直接调用（疑似历史遗留）；`Vendor/ThirdParty/SDL2` 未接入工程，也未使用。

### 环形缓冲实现

文件：`App/Audio/MVRingBuffer.{h,c}`（已改名，原文件名 TPCircularBuffer）。
© Michael Tyson，MIT/zlib 许可。以下是随该代码发布的许可原文，按条款 3 原样保留：

```
This implementation makes use of a virtual memory mapping technique that inserts a virtual copy
of the buffer memory directly after the buffer's end, negating the need for any buffer wrap-around
logic. Clients can simply use the returned memory address as if it were contiguous space.
The implementation is thread-safe in the case of a single producer and single consumer.
Virtual memory technique originally proposed by Philip Howard (http://vrb.slashusr.org/), and
adapted to Darwin by Kurt Revis (http://www.snoize.com,
http://www.snoize.com/Code/PlayBufferedSoundFile.tar.gz)
This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.
Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:
1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

## 机器学习模型

| 模型 | 位置 | 许可证 |
|---|---|---|
| Depth Anything V2（Small F16） | `App/Realtime3D/Models/DepthAnythingV2SmallF16P6.mlpackage` | Apache-2.0（见同目录 `DepthAnythingV2-LICENSE.txt`） |
| ZipDepth | `App/Realtime3D/Models/ZipDepth768x416.mlpackage` | MIT，© Fabio Tosi（见同目录 `ZipDepth-LICENSE.txt`） |

## 协议与文档

- NVIDIA GameStream 协议实现来自 moonlight-common-c，见其目录内说明。
- 本地化文案为独立撰写。

---

如果你的代码被使用而未在此列名，请提 issue 补充。

---

# Third-Party Components & Acknowledgements

This repository is built on the official Moonlight client and uses several third-party components and code references. All attribution is declared here.

## Core

| Component | Location | License |
|---|---|---|
| [moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) (Limelight, Objective-C) | `Vendor/Limelight` | GPL-3.0 + App Store Distribution Exception |
| [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | `Vendor/moonlight-common-c` | GPL-3.0 + App Store Distribution Exception |

Each component ships its own `LICENSE.txt` under `Vendor/`. `App/Video/DrawableVideoDecoder.swift` is derived from the Limelight renderer and keeps its copyright notice.

The App Store Distribution Exception allows App Store distribution provided the source is also made available under the GPL.

## Bundled Libraries

| Component | Location | License |
|---|---|---|
| Ring buffer implementation (originally TPCircularBuffer, renamed) | `App/Audio/MVRingBuffer.{h,c}` | MIT/zlib, © Michael Tyson |
| [libopus](https://opus-codec.org/) | `Vendor/ThirdParty/opus` | BSD-3-Clause |
| [FFmpeg](https://ffmpeg.org/) | `Vendor/ThirdParty/FFmpeg` | LGPL / GPL |
| [OpenSSL](https://www.openssl.org/) (SwiftPM dependency) | — | Apache-2.0 |

> **Note**: `libopus` and `FFmpeg` ship only as binaries and headers under `Vendor/ThirdParty/`, **without their license texts**. Add each project's `COPYING`/`LICENSE` before a public release. `FFmpeg` is linked but not called directly from the source (likely historical); `Vendor/ThirdParty/SDL2` is not integrated or used.

### Ring Buffer Implementation

File: `App/Audio/MVRingBuffer.{h,c}` (renamed; originally TPCircularBuffer).
© Michael Tyson, MIT/zlib. The license text below is kept verbatim as clause 3 requires:

```
This implementation makes use of a virtual memory mapping technique that inserts a virtual copy
of the buffer memory directly after the buffer's end, negating the need for any buffer wrap-around
logic. Clients can simply use the returned memory address as if it were contiguous space.
The implementation is thread-safe in the case of a single producer and single consumer.
Virtual memory technique originally proposed by Philip Howard (http://vrb.slashusr.org/), and
adapted to Darwin by Kurt Revis (http://www.snoize.com,
http://www.snoize.com/Code/PlayBufferedSoundFile.tar.gz)
This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.
Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:
1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

## Machine-Learning Models

| Model | Location | License |
|---|---|---|
| Depth Anything V2 (Small F16) | `App/Realtime3D/Models/DepthAnythingV2SmallF16P6.mlpackage` | Apache-2.0 (see `DepthAnythingV2-LICENSE.txt` in the same directory) |
| ZipDepth | `App/Realtime3D/Models/ZipDepth768x416.mlpackage` | MIT, © Fabio Tosi (see `ZipDepth-LICENSE.txt` in the same directory) |

## Protocol & Documentation

- The NVIDIA GameStream protocol implementation comes from moonlight-common-c; see the notes in its directory.
- Localized copy is written independently.

---

If your code is used but not listed here, please open an issue so it can be added.
