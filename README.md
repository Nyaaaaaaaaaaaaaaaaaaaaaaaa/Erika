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

这是 `Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika` 的专用分支，保留 Erika
现有 crate、C ABI、Flutter/ArkTS 包名和跨平台渲染接口，媒体边界如下：

- AV1 视频在各平台保留支持，容器包括 MP4/MOV、Matroska/MKV、WebM、IVF 和 raw AV1/OBU。
- Android 启用 MediaCodec 后端：AV1、H.264、HEVC、MPEG-2、MPEG-4、VP8、VP9。
- iOS、macOS、tvOS 启用 FFmpeg 8.1.2 的 VideoToolbox 后端：AV1、H.263、H.264、HEVC、MPEG-1、MPEG-2、MPEG-4、ProRes、VP9。
- HarmonyOS 启用 AVCodec 映射：AV1、H.263、H.264、HEVC、MPEG-2、MPEG-4、VP8、VP9。
- 上述平台同时启用对应的码流解析和常见容器解封装；Windows 的动态视频范围仍为 AV1。
- 静态图像保留 AVIF、HEIF/HEIC、JPEG 支持，解码后的图像保留在渲染表面；动画及图像序列不作兼容承诺。
- 音频仅作为视频播放的附属能力，不支持纯音频输入；字幕和弹幕能力已从专用内核删除。

具体 codec profile、尺寸和输出格式是否可用，由设备解码器初始化、解码及渲染结果决定。
系统路径不可用时尝试已编译的软件解码器；AV1 软件解码使用 dav1d。没有可用路径时通过现有错误通道报错。
这不代表设备支持任意格式，也不保证所有 profile 都能硬件解码或零拷贝呈现。PNG、WebP 等未列出的输入不在支持范围内。

## 特性

- **平台解码** — VideoToolbox (macOS/iOS/tvOS)、AV1 D3D11VA/DXVA2 (Windows)、MediaCodec (Android) 与 AVCodec (HarmonyOS)，按上文范围使用设备能力并保留软件回退
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

此 fork 的 0.2.0 尚未发布 pub.dev；请从本仓库依赖 Flutter package。`v0.2.0`
开始提供经过校验的组织内预编译原生库，包脚本默认从
`Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika` 下载，也可通过
`ERIKA_PREBUILT_REPOSITORY` 覆盖。只有调试 Erika 源码时才设置
`ERIKA_FORCE_SOURCE_BUILD=1`，预编译失败不会回退下载上游全格式二进制。

上游 pub.dev 包不代表本 fork 上述按平台区分的媒体边界。

### HarmonyOS NEXT package

此 fork 尚未发布 OHPM 包；请从 `packages/erika_ohos` 源码集成。上游同名
OHPM 包不代表本 fork 上述按平台区分的媒体边界。

See the [HarmonyOS NEXT package guide](packages/erika_ohos/README.md) for the
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
| macOS 14+ | VideoToolbox / 已编译的软件解码器（范围见上文） | Metal | CoreAudio | **可用**；新增格式待真机验收 |
| iOS 16+ | VideoToolbox / 已编译的软件解码器（范围见上文） | Metal | AudioQueue | **可用**；新增格式待真机验收 |
| tvOS 13+ (Apple TV) | VideoToolbox / 已编译的软件解码器（范围见上文） | Metal | AudioQueue | **可用**；新增格式待真机验收 |
| Windows 10+ | AV1 D3D11VA/DXVA2 / software | Direct3D 11 | WASAPI | **可用** |
| Linux | — | wgpu (planned) | — | 规划中 |
| Android 8+ | MediaCodec（codec 范围见上文）/ 现有软件解码器 | wgpu (Vulkan + GLES fallback) | AAudio | **可用** |
| HarmonyOS NEXT 5.1 / API 18+ | AVCodec / 已编译的软件解码器（范围见上文） | XComponent + OHNativeWindow，10-bit PQ / SDR 回退，DisplaySoloist VSync | OHAudio | **源码与构建链已接入**；新增格式及 HDR 真机验收待执行 |

## 仓库结构

```
crates/erika              核心播放库
crates/erika_capi         C ABI 导出层
crates/erika_ffmpeg_sys   FFmpeg 底层 bindings
packages/erika_flutter    Flutter 插件 (macOS + iOS + tvOS + Windows + Android + HarmonyOS)
packages/erika_ohos       HarmonyOS NEXT ArkTS / OHPM package
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
- [HarmonyOS NEXT 支持契约](docs/harmonyos-next.md) — API 18 下限、API 20 构建、HDR 与 0.2 迁移
- [平台能力矩阵](docs/platform_matrix.zh.md) — 区分可编译、CI 覆盖、真机验收与预编译发布
- [发布与预编译产物](docs/releasing.md) — 各平台预编译 `erika_capi` 库下载与打包(英文)
- [贡献 / 开发者指南](CONTRIBUTING.zh.md) — 仓库布局、线程模型、新增平台后端

## 构建

### 前置依赖

- Rust 1.92+
- Xcode Command Line Tools (macOS/iOS/tvOS)
- MSVC 工具链 + Windows SDK (Windows，target `x86_64-pc-windows-msvc`)
- Android SDK + NDK r29，以及对应 Android Rust target
- DevEco Studio HarmonyOS 6 / API 20 SDK（兼容 API 18），以及 Rust `aarch64-unknown-linux-ohos` target
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
