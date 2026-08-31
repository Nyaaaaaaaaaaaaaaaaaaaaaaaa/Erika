# Erika 平台能力矩阵

本文把“能编译”“CI 构建覆盖”“真机验收”和“有可下载预编译包”分开描述。任何一项为真，都不自动代表其它三项为真。

| 平台 | 主要解码/渲染 | C ABI presenter | CI/产物 | 真机验收状态 |
|---|---|---|---|---|
| macOS | AV1 VideoToolbox/dav1d + Metal | 是 | CI；此 fork 尚无预编译包 | 此 fork 需重新真机验收 |
| iOS | AV1 VideoToolbox/dav1d + Metal | 是 | CI；此 fork 尚无 XCFramework | 此 fork 需重新真机验收 |
| tvOS | AV1 VideoToolbox/dav1d + Metal | 是 | CI；此 fork 尚无 XCFramework | 此 fork 需重新真机验收 |
| Windows x64/ARM64 | AV1 D3D11VA/DXVA2/软解 + D3D11 | 是 | CI；此 fork 尚无预编译包 | 此 fork 需重新真机验收 |
| Android | AV1 MediaCodec/dav1d + wgpu | 是 | CI；此 fork 尚无预编译包 | 此 fork 需重新真机验收 |
| HarmonyOS | AV1 dav1d 软解 + wgpu Vulkan | 是 | 此 fork 尚无预编译包 | 此 fork 需重新真机验收 |
| Linux | 规划中的 wgpu 路径 | 不作为发布承诺 | 无正式预编译发布 | 未验收 |

## surface 与嵌入选择

- Apple：优先 native Metal surface；Flutter 完整播放器优先 window overlay，platform view 用于兼容或诊断。
- Windows：使用 HWND/D3D11 attach，调用方负责窗口生命周期与 display tick。
- Android：SDR 使用 TextureView；extended-linear 输出使用 SurfaceView/Hybrid Composition，能力协商失败明确回退 SDR。
- HarmonyOS：ArkTS 外部纹理提供 `OHNativeWindow`，通过 `erika_presenter_attach_wgpu_surface` attach；平台桥接优先使用 JSON presenter helper。

## 发布前记录

发布说明应写明每个平台的目标 triple、FFmpeg profile、prebuilt tag、C header 版本、CI 结果及真机验收设备。没有真机结论时应标记“待验收”，不要写成“已完全支持”。

视觉媒体范围固定为 AV1 动态视频（MP4/MOV、MKV/WebM、IVF、raw AV1）与单张
静态 AVIF。音频、字幕和弹幕只作为 AV1 播放附属能力。animated AVIF、纯音频和
其它视觉 codec 均不属于兼容承诺。
