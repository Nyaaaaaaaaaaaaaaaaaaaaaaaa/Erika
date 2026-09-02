# HarmonyOS NEXT support contract

Erika 0.2 targets HarmonyOS NEXT 5.1 and newer. API 18 is the minimum
compatible runtime; development and release builds compile and target
HarmonyOS 6 / API 20.

## Locked toolchain

- Flutter OH: `3.41.10-ohos-1.0.1`
- Upstream Flutter base: `3.41.9`
- Dart: `3.11`
- DevEco / HarmonyOS SDK: `6.0.0` (`compileSdkVersion=20`,
  `targetSdkVersion=20`, `compatibleSdkVersion=18`)
- Rust target: `aarch64-unknown-linux-ohos`
- Rust toolchain: `1.92.0` or newer

`ohos` remains the compiler, package-manager, and Rust target identifier. User
documentation calls the product HarmonyOS NEXT; the project does not claim a
generic OpenHarmony compatibility tier.

## Rendering and fallback

The Flutter plugin and standalone ArkTS SDK both attach an `XComponent` /
`OHNativeWindow`. Prefer-HDR output is enabled only after the window accepts
and verifies `RGBA_1010102`, `OH_COLORSPACE_BT2020_PQ_LIMIT`, BT.2020 gamut,
HDR10 static metadata, and HDR/SDR white points. Native DisplaySoloist drives
render ticks from VSync. A failed step explicitly restores RGBA8888/sRGB and
reports a stable fallback reason.

Format, color space, color gamut, HDR metadata type, and HDR10 static metadata
are read back and compared before HDR is advertised. API 18-20 exposes setters
but no NativeWindow getters for the two white-point brightness values, so those
two values are gated by the native setter return codes; all other fields require
readback equality. `nativeDataSpace` is the actual NativeWindow color-space enum
returned by HarmonyOS NEXT, never a locally invented constant.

`hdrOutputConfirmed` means that a decoded HDR frame completed presentation on
that verified HDR path. Source metadata, an HDR-capable device, or an uploaded
HDR resource does not by itself confirm HDR output.

## Media scope

- AV1 PQ/HLG video: Harmony AVCodec hardware decode first, dav1d fallback.
- Static AVIF: single decode; the renderer-owned last frame is retained at EOF.
- Static HEIF: HEVC still-image decode through the packaged FFmpeg fallback.
- Ultra HDR JPEG: JPEG base image is decoded and retained. Until gain-map
  reconstruction lands, it is reported/presented as SDR rather than falsely
  setting `hdrOutputConfirmed`.

## 0.2 migration draft

Cloud/API media metadata and Erika output state are intentionally different
contracts. A service may expose coarse `dynamic_range=sdr|hdr` together with
`hdr_format=pq|hlg|gain_map|null`; the application maps those fields into the
player/output-layer `ErikaDynamicRange` values (`unknown`, `sdr`, `hdr10Pq`,
`hlg`, or `ultraHdrGainMap`). Do not send Erika's detailed enum as the Cloud
`dynamic_range` value or treat the two enums as wire-compatible.

- Prefer `ErikaOutputMode.auto` or `ErikaOutputMode.preferHdr`.
  `appleEdr` and `extendedLinear` remain temporarily as deprecated source
  aliases; platform-specific encoding selection is internal.
- Read `ErikaOutputStatus.sourceDynamicRange`, `activeDynamicRange`, and
  `hdrOutputConfirmed`.
- Subscribe to `ErikaEventKind.outputStatusChanged`; it carries a complete
  output snapshot and suppresses byte-identical consecutive snapshots.
- Call `getHdrCapabilities()` for the negotiated surface and VSync capability.
  Check `hardwareAv1DecodeKnown` before using
  `hardwareAv1DecodeSupported` for resource selection.
- Native C/C++ embedders must rebuild against the 0.2 header because
  `ErikaSurfaceOutputCapabilities` adds `native_data_space`; do not mix a 0.1
  bridge with a 0.2 runtime.

This is the 0.2 release contract. The fork publishes native binaries only to
its GitHub Release; pub.dev, OHPM, ErikaSwift, and production-device acceptance
remain separate and are not implied by the native release.
