# erika_flutter

> AV1/AVIF specialized package は subtitle / danmaku 非対応です。旧 Dart method は
> compatibility のため一時的に残り、呼び出すと明示的に失敗します。

[中文](README.zh.md) | [English](README.md) | [日本語](README.ja.md)

Erika メディア再生エンジン向けの Flutter plugin です。

この plugin は Dart を hot path から外します。

- Dart は低頻度の player command と event stream だけを公開します。
- native plugin は 2 種類の surface を提供します。推奨は `ErikaWindowOverlayVideoView`（macOS/iOS/tvOS は Metal、Windows は D3D11 swapchain）、platform view 用は `ErikaVideoView` です。Android video は native `TextureView` を使います。
- macOS plugin は Erika の dynamic library を読み込みます。
- iOS plugin は Erika の static library を link します。
- tvOS plugin は Erika の static library を link し、Apple TV platform view で Metal layer を host します。
- Windows plugin は Erika C ABI DLL を build して link します。
- Android plugin は ABI ごとに `liberika_capi.so` を build し、`Choreographer` から native surface を駆動します。
- HarmonyOS plugin は Flutter external texture を登録し、その `OHNativeWindow` を Erika に attach して、OHAudio で低レイテンシの PCM 出力を行います。
- Erika は `ErikaPresenterHandle` を通じて playback、rendering、audio、timing、overlay を担当します。

## Video Surfaces

フルプレイヤーの macOS/iOS/tvOS UI では `ErikaWindowOverlayVideoView` を使うのが推奨です。Flutter の layout では矩形領域を予約しつつ、plugin が横に native `CAMetalLayer` を持ち、video を Flutter platform-view compositor の外に置きます。

Windows では `ErikaWindowOverlayVideoView` が window-level の Direct3D 11 swapchain を sibling surface として host し、同じ overlay モデルに従います。

標準的な Flutter platform view が必要な場合は `ErikaVideoView` を使います。Android video surface は native `TextureView` です。plugin は borrowed `Surface`、lifecycle、resize、audio focus、vsync tick を Erika に接続します。

## macOS Setup

macOS CocoaPods build は既定で arm64+x86_64 universal dynamic library を生成します。依存 project は `ERIKA_MACOS_ARCHS=arm64`、`ERIKA_MACOS_ARCHS=x86_64`、または `ERIKA_MACOS_ARCHS=arm64,x86_64` で artifact architecture を選択できます。既定値は `universal` です。prebuilt mode は対応する `macos-arm64`、`macos-x64`、`macos-universal` archive を取得します。ローカル開発では plugin が `dlopen` で Erika を読み込み、`ERIKA_CAPI_DYLIB` で path を上書きできます。

dynamic library を build するには：

```sh
cargo run -p xtask -- deps build --profile lgpl
cargo build -p erika_capi
```

## Prebuilt package と source build

plugin は既定で `Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika` から現在の version に対応する `v0.2.0` native library を download し、SHA-256 を検証します。asset が無い場合や検証に失敗した場合は明示的に error となり、upstream full-codec binary へ fallback しません。local source の検証では `ERIKA_FORCE_SOURCE_BUILD=1` を設定してください。`ERIKA_PREBUILT_REPOSITORY=owner/repo` で上書きできます。custom `ERIKA_PREBUILT_TAG` の single-ABI build には対応する `ERIKA_PREBUILT_SHA256` が必要です。Android multi-ABI build では `ERIKA_PREBUILT_SHA256_ARM64_V8A`、`ERIKA_PREBUILT_SHA256_ARMEABI_V7A`、`ERIKA_PREBUILT_SHA256_X86_64`、`ERIKA_PREBUILT_SHA256_X86` を ABI ごとに指定します。詳細は [release guide](https://github.com/Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika/blob/main/docs/releasing.ja.md) を参照してください。
Android は要求された ABI ごとに約 20–22MB の runtime archive だけを download し、4 ABI combined C API bundle や static library は取得しません。

source build の architecture は macOS では `ERIKA_MACOS_ARCHS=arm64|x86_64|universal`、Windows では `ERIKA_WINDOWS_ARCH=x64|arm64`、Android では `ERIKA_ANDROID_ABIS=arm64-v8a,armeabi-v7a,x86_64,x86` で選択します。native library を直接 build する場合、`xtask --target`、`ERIKA_NATIVE_TARGET`、`cargo build --target` は同じ target にしてください。詳細は [build guide](https://github.com/Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika/blob/main/docs/building.ja.md) を参照してください。

macOS plugin は Now Playing を通じてタイトル、アーティスト、アルバム、artwork、再生状態、timeline を公開し、Remote Command Center からの再生、一時停止、停止、seek を処理します。

## iOS Setup

iOS の CocoaPod script phase が、Xcode build 中に Erika の native dependency と C ABI static library を自動 build します。対応する iOS target の Rust toolchain が必要です。

- `rustup target add aarch64-apple-ios`

host app では、Xcode の Signing & Capabilities で **Background Modes > Audio, AirPlay, and Picture in Picture** を有効にするか、`Info.plist` の `UIBackgroundModes` に `audio` を追加してください。player は Now Playing 情報と再生 control を Control Center に登録します。タイトル、アーティスト、アルバム、エンコード済み artwork bytes を表示するには `ErikaMediaMetadata` を指定してください。

バックグラウンド再生はデフォルトで無効です。バックグラウンドで音声を継続する場合は、`ErikaPlayer(allowBackgroundPlayback: true)` を指定してください。host app で上記の Background Mode が有効でない場合、この option を指定しても iOS はバックグラウンド再生の継続を保証しません。

```dart
final player = ErikaPlayer(
  allowBackgroundPlayback: true,
);

final artwork = await rootBundle.load('assets/cover.jpg');
await player.open(
  mediaUrl,
  metadata: ErikaMediaMetadata(
    title: 'タイトル',
    artist: 'アーティスト',
    album: 'アルバム',
    artwork: artwork.buffer.asUint8List(),
  ),
);
await player.play();
```

`allowBackgroundPlayback` は player 作成時の option であり、native player の作成後には変更できません。`false` の場合、App がバックグラウンドに入ると再生を一時停止し、foreground に戻っても一時停止状態を維持します。`true` の場合、バックグラウンドでは動画 decode を停止して音声のみを継続し、App が active になると動画を再開します。Control Center から再生、一時停止、再生位置の変更ができます。artwork には raw pixel ではなく、JPEG や PNG など `UIImage` が対応する形式の完全な encoded image bytes を指定してください。

## System Media の前後移動

playlist app は active item に応じて system media panel の前へ・次へ button を有効に
できます。Erika 自身は次の media item を選択せず、
`systemMediaNavigationRequested` event を発行するため、Dart を playlist の唯一の
source of truth にできます。active item が変わるたびに capability を更新してください。

```dart
import 'dart:async';

import 'package:erika_flutter/erika_flutter.dart';

class PlaylistController {
  final ErikaPlayer player = ErikaPlayer(allowBackgroundPlayback: true);
  final List<({String title, String url})> items = <({String title, String url})>[
    (title: 'エピソード 1', url: 'https://example.com/episode-1.mp4'),
    (title: 'エピソード 2', url: 'https://example.com/episode-2.mp4'),
  ];

  StreamSubscription<ErikaPlayerEvent>? subscription;
  int index = 0;
  bool switching = false;

  Future<void> initialize() async {
    subscription = player.events.listen((ErikaPlayerEvent event) async {
      if (event.kind != ErikaEventKind.systemMediaNavigationRequested) {
        return;
      }
      switch (event.systemMediaCommand) {
        case ErikaSystemMediaCommand.previous:
          await openAt(index - 1);
        case ErikaSystemMediaCommand.next:
          await openAt(index + 1);
        case null:
          break;
      }
    });
    await openAt(0);
  }

  Future<void> openAt(int newIndex) async {
    if (switching || newIndex < 0 || newIndex >= items.length) {
      return;
    }
    switching = true;
    await player.setSystemMediaNavigation(
      previousEnabled: false,
      nextEnabled: false,
    );
    try {
      final item = items[newIndex];
      await player.open(
        item.url,
        metadata: ErikaMediaMetadata(title: item.title),
      );
      await player.play();
      index = newIndex;
    } finally {
      switching = false;
      await player.setSystemMediaNavigation(
        previousEnabled: index > 0,
        nextEnabled: index + 1 < items.length,
      );
    }
  }

  Future<void> dispose() async {
    await subscription?.cancel();
    await player.dispose();
  }
}
```

capability は既定で無効で、iOS、tvOS、macOS、Android、Windows、HarmonyOS に対応します。
item の切り替え中は両方の button を一時的に無効化して重複 request を拒否し、切り替え
成功後に index、metadata、capability を更新してください。この API が通知するのは
`previous` と `next` のみです。再生、一時停止、停止、seek は引き続き各 platform の
native system-media integration が直接処理します。

## tvOS Setup

tvOS の CocoaPod script phase が、Apple TV 実機または simulator 向けの native
dependency と C ABI static library を Xcode build 中に自動 build します。Rust の
tvOS target は tier 3 のため、source component 付き nightly が必要です：

- `rustup toolchain install nightly --component rust-src`

script は現在の Xcode SDK と architecture から `aarch64-apple-tvos`、
`aarch64-apple-tvos-sim`、または `x86_64-apple-tvos` を選び、
`-Z build-std=std,panic_abort` で compile します。

## Windows Setup

Windows plugin（`ErikaFlutterPluginCApi`）は CMake build 中に `build_erika_runtime.cmake` で Erika C ABI runtime（`erika_capi.dll`）を build し、CMake generator の x64 または ARM64 architecture に自動追従して DLL を app の隣に配置します。依存 project は CMake cache の `ERIKA_WINDOWS_ARCH=x64|arm64` または環境変数 `ERIKA_WINDOWS_ARCH` で明示的に選択できます。高度な用途では `ERIKA_NATIVE_TARGET=x86_64-pc-windows-msvc|aarch64-pc-windows-msvc` も指定できます。必要なもの：

- 対応する MSVC target の Rust toolchain（`rustup target add x86_64-pc-windows-msvc` または `rustup target add aarch64-pc-windows-msvc`）
- Visual Studio Build Tools の x64/ARM64 C++ tools + Windows SDK
- `third_party/dist/<target>/` に build 済みの native dependency（リポジトリの `xtask deps build` フロー）

plugin が Erika checkout を自動検出できない場合は `ERIKA_REPO_ROOT` を設定してください。

Windows plugin は System Media Transport Controls（SMTC）を通じてタイトル、アーティスト、アルバム、artwork、再生状態、timeline を公開し、system の再生、一時停止、seek を処理します。C++/WinRT を含む Windows SDK が必要で、必要な WinRT system library は plugin が自動的に link します。

## Android Setup

Android Gradle build は Erika の `xtask` で native dependency を構築し、選択した ABI 向けに Cargo で `erika_capi` を build します。Android API 26 以降、Android NDK、対応する Rust target が必要です。生成される `jniLibs` には `liberika_capi.so` と ABI に対応する NDK の `libc++_shared.so` が含まれます。既定は arm64 と x86_64 で、`-PerikaAndroidAbis=arm64-v8a,x86_64` または `ERIKA_ANDROID_ABIS` で変更できます。

Android の `content://` media/subtitle URI は `ContentResolver` で開いて detach し、provider の offset/length を含む所有権付き `fd://` source として Erika に渡します。

Android は MediaSession と media notification を使って lock screen、Bluetooth、system media control に接続します。`allowBackgroundPlayback: true` の場合は `mediaPlayback` foreground Service を起動し、video decode を停止したままバックグラウンドで音声を継続します。plugin Manifest には foreground service と Android 13+ の notification permission が宣言されていますが、host app は product flow に応じて `POST_NOTIFICATIONS` runtime permission を要求する必要があります。permission が拒否された場合も media session は動作しますが、notification の表示は Android version と system policy に依存します。

Android minimum は API 26 のままです。対応する API level では video output を
SDR に統一します。

## HarmonyOS Setup

HarmonyOS module には DevEco Studio の OpenHarmony Native SDK が必要です。CMake は
既定で `liberika_capi.so` を download、検証し、`liberika_flutter.so` と一緒に package
します。Rust の `aarch64-unknown-linux-ohos` target は
`ERIKA_FORCE_SOURCE_BUILD=1` を明示した source build でのみ必要です。

HarmonyOS は AVSession を通じて metadata、artwork、再生状態、位置、再生速度を公開し、system の再生、一時停止、停止、seek command を処理します。

HarmonyOS では `ErikaVideoView` を使ってください。Flutter external texture を登録し、
その texture surface を `OHNativeWindow` として取得して、wgpu Vulkan で描画します。
音声は OHAudio の interleaved f32 PCM です。

この AV1/AVIF 専用 fork は HarmonyOS で hardware category の `video/av1` AVCodec
capability のみを照会し、coded size を検証してから返された codec name で decoder
を作成します。system 推奨の software AVCodec は選択せず、capability 不在、size
非対応、open/runtime failure の場合は直接 dav1d へ fallback します。Surface output
は NativeBuffer/Vulkan、AVCodec buffer output と dav1d は CPU upload を使います。
この hardware 方針は video のみです。static AVIF は別の software decode で
SDR RGBA を生成し、`ErikaFileImage` を Flutter の `Image` に渡して表示します。
static HDR surface は提供しません。`maximumDecodeExtent` で decode 後の物理
サイズを制限し、download と disk cache は application 側で管理します。

## HTTP ヘッダー

HTTP(S) video を再生する場合は、`httpHeaders` で request header を渡せます：

```dart
await player.open(
  'https://example.com/video.mp4',
  httpHeaders: <String, String>{
    'Authorization': 'Bearer token',
    'Referer': 'https://example.com/',
  },
);
```

header は HEAD、Range GET、prefetch request とともに送信され、HTTP(S) URL にだけ適用されます。
`content://` と local file の再生では header は無視されます。Authorization や Cookie などの
機密値を application log に出力しないでください。

playback engine 自身が生成する header は merge されず reject されます：`Range`、`Host`、
`Content-Length`、`Transfer-Encoding`、`Connection`（大文字小文字を区別しない）は `open` を
throw させます。HTTP field として不正な名前や値も同様です。同梱の native library が
0.1.3 以前の prebuilt（HTTP header 対応より前）の場合、header 付きの `open` は黙って
header を捨てずに throw します。

header が適用されるのは media source だけです。外部 subtitle track と danmaku sidecar は
まだ header なしで取得されます。

## HTTP 先読みウィンドウ

`httpReadAheadBytes` で、1 回の HTTP(S) open に対する先読みウィンドウを調整できます：

```dart
await player.open(
  'https://example.com/video.mp4',
  httpReadAheadBytes: 16 * 1024 * 1024,
);
```

正の値は `ERIKA_HTTP_READAHEAD_BYTES` を上書きします。null または 0 の場合は、環境変数が
あればその値を、なければ native の 2 MiB 既定値を使います。local file では無視されます。
0.1.7 以前の native library には options entry point がないため、この設定を指定すると
黙って破棄せず、説明付きの error を throw します。

## SDR Video Output

`ErikaPlayer` は常に native SDR 出力を要求します。HDR encoded AV1 source も source colour metadata に従って decode し、SDR に tone-map して再生します。Android は通常の `erika_flutter/video_view` TextureView を使います。Flutter API に HDR output mode、headroom、HDR capability switch はありません。

## Upscaler

作成時に ArtCNN を選択することも、runtime で切り替えることもできます。

```dart
final player = ErikaPlayer(upscaler: ErikaUpscalerMode.artCnnC4F16Ds);
await player.setUpscaler(ErikaUpscalerMode.artCnnC4F16Ds);
```

`ErikaUpscalerMode.off` で無効化します。`player.getUpscalerStatus()` では要求モード、実行 backend、fallback 回数、upscaled frame 数、最近の GPU timing を確認できます。Apple は Metal、Android は planar と MediaCodec Surface frame の両方で wgpu/Vulkan compute を使います。GLES 3.0 は通常再生を維持し、明示的な `inactive` fallback を報告します。
