[中文](../README.md) | [English](README.en.md) | [日本語](README.ja.md)

# Erika

> 「GOOD！私はErika、NipaPlayにおいてmdk、video player、libmpv、media kitに次ぐ5番目のプレイヤーカーネルです。」
> 「あなたを数えても、プレイヤーカーネルは4つだけ！」

**NipaPlay の自社開発再生コア。** Rust 実装、組み込み可能、デコードからレンダリングまで一手に引き受けます。

> 名前の由来は『うみねこのなく頃に』の探偵 **古戸ヱリカ**。
> そして [NipaPlay](https://github.com/AimesSoft/NipaPlay-Reload) は『ひぐらしのなく頃に』の古手梨花の口癖「にぱー☆」から——コミュニティではみんな「梨花」と呼んでいます。
> 一方は表舞台のプレイヤー、もう一方は舞台裏のエンジン。同じ世界から生まれた、表裏一体の存在です。

ホストアプリケーションはレンダリングサーフェスの提供と再生コマンドの送信のみを行い、デコード、タイミング同期、映像レンダリング、音声出力はすべて Erika 内部で完結します。

## この fork のメディア範囲

`Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika` は既存の crate、C ABI、Flutter/ArkTS
package 名、cross-platform rendering interface を維持し、visual media を次に限定します。

- MP4/MOV、Matroska/MKV、WebM、IVF、raw AV1/OBU の動的 AV1 video。
- 単一の静的 primary image の AVIF。animated AVIF と image sequence は互換性対象外で、EOF 後も decode 済み image を surface に保持します。
- 音声のみ AV1 playback の付随機能です。字幕と弾幕は specialized runtime から削除済みです。audio-only media と他の visual codec は拒否します。

## 機能

- **AV1 hardware decode** -- VideoToolbox (macOS/iOS/tvOS)、D3D11VA/DXVA2 (Windows)、MediaCodec (Android)。利用不可時は AV1 software decode へ fallbackし、HarmonyOS は dav1d を直接選択
- **ゼロコピーレンダリング** -- CVPixelBuffer → MTLTexture (Apple)、D3D11VA texture interop (Windows)、MediaCodec Surface → AHardwareBuffer/Vulkan (Android)。software frame は明示的な CPU upload を使用
- **HDR/EDR 出力** -- Apple EDR、Windows HDR10、Android FP16 extended-linear scRGB negotiation と明示的な SDR fallback
- **Metal ネイティブレンダラー** -- YCbCr サンプリング、色空間変換、トーンマッピングを単一レンダーパスで実行 (macOS/iOS/tvOS)
- **Direct3D 11 ネイティブレンダラー** -- Windows: D3D11VA ゼロコピーテクスチャ相互運用、YCbCr サンプリング、HDR10 出力
- **ニューラル超解像** -- ArtCNN によるアニメ輝度 2x 超解像。Metal、D3D11、wgpu/Vulkan compute で render pipeline に統合
- **音声出力** -- CoreAudio (macOS) / AudioQueue (iOS/tvOS) / WASAPI (Windows) / AAudio (Android) / OHAudio (HarmonyOS)、f32 PCM リングバッファ、音声クロック同期
- **互換境界** -- 旧 subtitle/danmaku C ABI symbol は link compatibility のため残りますが `PlayerError` を返し、parser/layout/renderer 実装は含みません
- **再生エンジン** -- play / pause / stop / seek / 再生速度制御、音声マスタークロック同期、vsync 量子化フレームスケジューリング
- **C ABI** -- 不透明ハンドル設計で、C / C++ / Swift / Dart FFI / 任意の FFI 対応言語から呼び出し可能。正確なエクスポート集合は `erika.h` を参照
- **Flutter プラグイン** -- macOS + iOS + tvOS + Windows + Android + HarmonyOS の native view / Texture embedding と platform-native high-dynamic-range surface path
- **wgpu バックエンド** -- Android の playback、overlay、capture、bounded Vulkan/GLES recovery は利用可能。HarmonyOS は Vulkan で動作し、OHNativeWindow で present して OHNativeBuffer を zero-copy import します。Linux は引き続き計画中

## クイックスタート

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

// ディスプレイティック毎に:
ErikaPresenterStats stats;
erika_presenter_render_tick(presenter, host_time, &stats);
```

### Flutter

```dart
final player = ErikaPlayer();
await player.open('/path/to/video.mp4');
await player.play();

// 推奨: フルプレイヤー UI では Erika のネイティブ Metal レイヤーを使います。
ErikaWindowOverlayVideoView(player: player)

// 互換/診断: Flutter platform view 埋め込みも引き続き利用できます。
ErikaVideoView(player: player)
```

### Flutter パッケージ

この fork は pub.dev package と prebuilt runtime をまだ公開していません。
source checkout から `ERIKA_FORCE_SOURCE_BUILD=1` で利用してください。prebuilt script の
既定 repository は `Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika` で、
`ERIKA_PREBUILT_REPOSITORY` により上書きできます。organization が対応 asset を公開するまで
prebuilt mode は明示的に失敗し、upstream の full-codec binary へ fallback しません。

### OpenHarmony パッケージ

この fork は OHPM package をまだ公開していません。`packages/erika_ohos` の source を
組み込んでください。同名の upstream package はこの fork の AV1/AVIF-only contract を持ちません。

このパッケージは Flutter に依存しません。`ErikaPlayer` API と
`XComponent` サーフェスの設定は
[OpenHarmony パッケージガイド](../packages/erika_ohos/README.md)を参照してください。

## C ABI インターフェースファミリー

異なる組み込みシナリオに対応する二つの C ABI エントリーポイントファミリーを提供します：

| ファミリー | ユースケース | レンダリング |
|-----------|-------------|-------------|
| `ErikaHandle` | ホストが独自のレンダーループを管理 | ホストがフレームデータを取得 |
| `ErikaPresenterHandle` | Erika が再生スタック全体を管理 | ホストはサーフェスを提供し `render_tick` を駆動 |

ヘッダー: [`crates/erika_capi/include/erika.h`](../crates/erika_capi/include/erika.h)

## プラットフォームサポート

| プラットフォーム | デコード | レンダリング | 音声 | 状態 |
|----------------|---------|-------------|------|------|
| macOS 14+ | AV1 VideoToolbox / dav1d | Metal | CoreAudio | **利用可能** |
| iOS 16+ | AV1 VideoToolbox / dav1d | Metal | AudioQueue | **利用可能** |
| tvOS 13+ (Apple TV) | AV1 VideoToolbox / dav1d | Metal | AudioQueue | **利用可能** |
| Windows 10+ | AV1 D3D11VA/DXVA2 / software | Direct3D 11 | WASAPI | **利用可能** |
| Linux | -- | wgpu (計画中) | -- | 計画中 |
| Android 8+ | AV1 MediaCodec / dav1d | wgpu (Vulkan + GLES fallback) | AAudio | **利用可能**。この fork の実機 acceptance は未実施 |
| HarmonyOS API 18+ | AV1 dav1d software decode | wgpu (Vulkan) | OHAudio | **利用可能**。この fork の実機 acceptance は未実施 |

## リポジトリ構成

```
crates/erika              コア再生ライブラリ
crates/erika_capi         C ABI エクスポート層
crates/erika_ffmpeg_sys   FFmpeg 低レベルバインディング
packages/erika_flutter    Flutter プラグイン (macOS + iOS + tvOS + Windows + Android + HarmonyOS)
packages/erika_ohos       OpenHarmony ArkTS / OHPM パッケージ
examples/                 検証・デモプログラム
xtask/                    ネイティブ依存関係ビルドオーケストレーション
docs/                     アーキテクチャと組み込みドキュメント
```

## ドキュメント

- [アーキテクチャ](../docs/architecture.ja.md) — エンジン設計、レンダーバックエンド、プラットフォーム対応
- [C ABI リファレンス](../docs/capi_reference.ja.md) — 全エクスポート関数、ステータスコード、所有権とスレッド規約
- [組み込みガイド](../docs/integration.ja.md) — C/C++/Win32/Swift など非 Flutter ホストへの組み込み
- [ビルドガイド](../docs/building.ja.md) — xtask、native 依存、クロスコンパイル
- [Flutter 組み込み](../docs/flutter_embedding.ja.md)
- [リリースとプリビルドバイナリ](../docs/releasing.md) — プラットフォーム別 `erika_capi` ライブラリの配布とパッケージング（英語）
- [コントリビュート / 開発者ガイド](../CONTRIBUTING.ja.md) — リポジトリ構成、スレッドモデル、プラットフォームバックエンドの追加

## ビルド

### 前提条件

- Rust 1.92+
- Xcode Command Line Tools (macOS/iOS/tvOS)
- MSVC ツールチェーン + Windows SDK (Windows、ターゲット `x86_64-pc-windows-msvc`)
- Android SDK + NDK r29 と対象 Android ABI の Rust target
- DevEco Studio OpenHarmony Native SDK と Rust の `aarch64-unknown-linux-ohos` target
- CMake, pkg-config

### ネイティブ依存関係のビルド

```sh
# FFmpeg のビルド (LGPL プロファイル)
cargo run -p xtask -- deps build --profile lgpl

# AV1/AVIF native dependency のビルド
cargo run -p xtask -- deps build --profile lgpl

# 依存関係の状態確認
cargo run -p xtask -- deps status
```

### コンパイルとテスト

```sh
cargo build -p erika
cargo test --workspace
```

### 再生パスの検証

```sh
# macOS
export SAMPLE="/path/to/video.mp4"
cargo run -p macos_native_demo -- "$SAMPLE"
cargo run -p macos_native_demo -- --smoke-seconds 3 "$SAMPLE"

# Windows
cargo run -p windows_native_demo -- "%SAMPLE%"
```

## ライセンス

Rust ワークスペース: [MPL-2.0](../LICENSE)

ネイティブ依存関係のビルドプロファイルとライセンス境界は `xtask` を通じて独立管理されます。
