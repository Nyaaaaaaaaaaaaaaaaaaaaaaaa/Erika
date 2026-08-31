[English](readme/README.en.md) | [日本語](readme/README.ja.md)

# Erika

> 「GOOD！我是Erika，是NipaPlay里继mdk、video player、libmpv、media kit之后的第五个播放器内核。」
> 「即便算上你，也只有四个播放器内核！」

**NipaPlay 的自研播放内核。** Rust 实现，可嵌入，从解码到渲染一手包办。

> 名字取自《海猫鸣泣之时》的侦探 **古戸ヱリカ**。
> 而 [NipaPlay](https://github.com/AimesSoft/NipaPlay-Reload) 来自《寒蝉鸣泣之时》古手梨花的口癖「にぱー☆」——社区里大家都叫她「梨花」。
> 一个是台前的播放器，一个是幕后的引擎。同出一脉，互为表里。

宿主应用只需提供一个渲染表面并发送播放命令——解码、时序同步、音视频渲染和音频输出均由 Erika 内部完成，不经过宿主的渲染管线。

## 此 fork 的媒体边界

这是 `Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika` 的 AV1 / AVIF 专用分支，保留 Erika
现有 crate、C ABI、Flutter/ArkTS 包名和跨平台渲染接口，但只接受下列视觉媒体：

- AV1 动态视频：MP4/MOV、Matroska/MKV、WebM、IVF 和 raw AV1/OBU；
- AVIF：单张静态主图，首帧呈现后保留在渲染表面；animated AVIF 和 image sequence 不作兼容承诺；
- 音频仅作为 AV1 播放的附属能力，不代表支持纯音频文件；字幕和弹幕能力已从专用内核删除。

H.264、HEVC/HEIC、VP8/VP9、MPEG、JPEG、PNG、WebP 和纯音频输入会通过
现有错误通道被明确拒绝。

## 特性

- **AV1 硬件加速解码** — VideoToolbox (macOS/iOS/tvOS)、D3D11VA/DXVA2 (Windows)、MediaCodec (Android) 与硬件类别 AVCodec (HarmonyOS)，不可用时明确回退 dav1d
- **零拷贝渲染** — Apple CVPixelBuffer → MTLTexture、Windows D3D11VA 纹理互操作、Android MediaCodec Surface → AHardwareBuffer/Vulkan、HarmonyOS AVCodec Surface → NativeBuffer/Vulkan；buffer 输出和软件帧走明确的 CPU upload
- **HDR/EDR 输出** — Apple EDR、Windows HDR10，以及 Android FP16 extended-linear scRGB 协商与明确 SDR 回退
- **原生 Metal 渲染器** — YCbCr 采样、色彩空间转换和 tone mapping，一次 render pass 完成 (macOS/iOS/tvOS)
- **原生 Direct3D 11 渲染器** — Windows: D3D11VA 零拷贝纹理互操作、YCbCr 采样和 HDR10 输出
- **AI 超分** — ArtCNN 动漫亮度 2x 神经超分，支持 Metal、D3D11 与 wgpu/Vulkan compute，仅处理亮度并接入渲染管线
- **音频输出** — CoreAudio (macOS) / AudioQueue (iOS/tvOS) / WASAPI (Windows) / AAudio (Android) / OHAudio (HarmonyOS)，f32 PCM ring buffer，音频时钟同步
- **兼容边界** — 旧 C ABI 的字幕/弹幕符号为保持二进制兼容而保留，但统一返回 `PlayerError`，不包含解析、排版或渲染实现
- **播放引擎** — play / pause / stop / seek / 倍速，音频主时钟同步，vsync 量化调度
- **C ABI** — opaque handle 设计，可从 C / C++ / Swift / Dart FFI / 任何 FFI 语言调用；以 `erika.h` 中的导出声明为准
- **Flutter 插件** — macOS + iOS + tvOS + Windows + Android + HarmonyOS 原生视图/Texture 嵌入
- **wgpu 后端** — Android 播放、overlay、截图与 Vulkan/GLES 恢复路径可用；HarmonyOS 走 Vulkan，用 OHNativeWindow 呈现、OHNativeBuffer 零拷贝导入；Linux 仍在规划中

## 快速开始

### Rust

```rust
use erika::{Player, PlayerConfig, MediaRequest};

let player = Player::new(PlayerConfig::default())?;
player.open(MediaRequest::file("/path/to/video.mp4"))?;
player.play()?;
```

### C ABI

```c
#include "erika.h"

ErikaPresenterHandle *presenter = erika_presenter_create();
erika_presenter_attach_metal_layer(presenter, (uint64_t)layer, w, h, scale);
erika_presenter_open(presenter, "/path/to/video.mp4");
erika_presenter_play(presenter);

// 每个显示帧回调:
ErikaPresenterStats stats;
erika_presenter_render_tick(presenter, host_time, &stats);
```

### Flutter

```dart
final player = ErikaPlayer();
await player.open('/path/to/video.mp4');
await player.play();

// 推荐：完整播放器 UI 在 macOS/iOS/tvOS 使用原生 window overlay / 挖空路径
ErikaWindowOverlayVideoView(player: player)

// 兼容/诊断：Flutter platform view 路径
ErikaVideoView(player: player)
```

### Flutter package

此 fork 尚未发布 pub.dev 或预编译二进制。请从本仓库源码依赖并设置
`ERIKA_FORCE_SOURCE_BUILD=1`；包脚本的预编译默认仓库是
`Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika`，也可通过 `ERIKA_PREBUILT_REPOSITORY`
覆盖。组织发布对应资产之前，预编译模式会明确失败，不会回退下载上游全格式二进制。

上游 pub.dev 包不代表本 fork 的 AV1/AVIF 支持边界。

### OpenHarmony package

此 fork 尚未发布 OHPM 包；请从 `packages/erika_ohos` 源码集成。上游同名
OHPM 包不代表本 fork 的 AV1/AVIF 支持边界。

See the [OpenHarmony package guide](packages/erika_ohos/README.md) for the
`ErikaPlayer` API and `XComponent` surface setup.

### Swift package

此 fork 尚未发布 Swift 包，也不会向 `AimesSoft/ErikaSwift` 写入。上游
`ErikaSwift` 的预编译 XCFramework 是全格式版本，不属于此 fork 的分发渠道。

## C ABI 接口族

Erika 提供两组 C ABI 入口，适配不同嵌入场景：

| 接口族 | 适用场景 | 渲染方式 |
|--------|----------|----------|
| `ErikaHandle` | 宿主自己管理渲染循环 | 宿主拉取帧数据 |
| `ErikaPresenterHandle` | Erika 托管完整播放栈 | 宿主只需提供 surface 并驱动 `render_tick` |

头文件: [`crates/erika_capi/include/erika.h`](crates/erika_capi/include/erika.h)

## 平台支持

| 平台 | 解码 | 渲染 | 音频 | 状态 |
|------|------|------|------|------|
| macOS 14+ | AV1 VideoToolbox / dav1d | Metal | CoreAudio | **可用** |
| iOS 16+ | AV1 VideoToolbox / dav1d | Metal | AudioQueue | **可用** |
| tvOS 13+ (Apple TV) | AV1 VideoToolbox / dav1d | Metal | AudioQueue | **可用** |
| Windows 10+ | AV1 D3D11VA/DXVA2 / software | Direct3D 11 | WASAPI | **可用** |
| Linux | — | wgpu (planned) | — | 规划中 |
| Android 8+ | AV1 MediaCodec / dav1d | wgpu (Vulkan + GLES fallback) | AAudio | **可用** |
| HarmonyOS API 18+ | AV1 硬件 AVCodec / dav1d | wgpu (Vulkan) | OHAudio | **可用**；硬件路径仍需真机验收 |

## 仓库结构

```
crates/erika              核心播放库
crates/erika_capi         C ABI 导出层
crates/erika_ffmpeg_sys   FFmpeg 底层 bindings
packages/erika_flutter    Flutter 插件 (macOS + iOS + tvOS + Windows + Android + HarmonyOS)
packages/erika_ohos       OpenHarmony ArkTS / OHPM package
examples/                 验证与演示程序
xtask/                    原生依赖构建编排
docs/                     架构与嵌入文档
```

## 文档

- [架构总览](docs/architecture.zh.md) — 引擎设计、渲染后端、平台支持
- [C ABI 参考手册](docs/capi_reference.zh.md) — 全部导出函数、状态码、所有权与线程约定
- [原生接入指南](docs/integration.zh.md) — C/C++/Win32/Swift 等非 Flutter 宿主的端到端嵌入
- Swift SDK — 此 fork 尚未发布；不会向上游 `AimesSoft/ErikaSwift` 写入
- [构建与依赖指南](docs/building.zh.md) — xtask、native 依赖、交叉编译
- [Flutter 嵌入](docs/flutter_embedding.zh.md)
- [平台能力矩阵](docs/platform_matrix.zh.md) — 区分可编译、CI 覆盖、真机验收与预编译发布
- [发布与预编译产物](docs/releasing.md) — 各平台预编译 `erika_capi` 库下载与打包(英文)
- [贡献 / 开发者指南](CONTRIBUTING.zh.md) — 仓库布局、线程模型、新增平台后端

## 构建

### 前置依赖

- Rust 1.92+
- Xcode Command Line Tools (macOS/iOS/tvOS)
- MSVC 工具链 + Windows SDK (Windows，target `x86_64-pc-windows-msvc`)
- Android SDK + NDK r29，以及对应 Android Rust target
- DevEco Studio OpenHarmony Native SDK，以及 Rust `aarch64-unknown-linux-ohos` target
- CMake, pkg-config

### 构建原生依赖

```sh
# 构建 FFmpeg (LGPL profile)
cargo run -p xtask -- deps build --profile lgpl

# 查看依赖状态
cargo run -p xtask -- deps status
```

### 编译与测试

```sh
cargo build -p erika
cargo test --workspace
```

### 验证播放路径

```sh
# macOS
export SAMPLE="/path/to/video.mp4"
cargo run -p macos_native_demo -- "$SAMPLE"
cargo run -p macos_native_demo -- --smoke-seconds 3 "$SAMPLE"

# Windows
cargo run -p windows_native_demo -- "%SAMPLE%"
```

## 许可证

Rust workspace: [MPL-2.0](LICENSE)

原生依赖通过 `xtask` 独立管理构建 profile 和许可证边界。
