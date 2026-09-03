# Changelog

## Unreleased

## 0.2.0 - 2026-09-03

- Added standalone decode-once static AVIF paths on Android and iOS: bounded
  SDR external textures and native HDR/EDR surfaces without creating player,
  audio, timeline state, or whole-image RGBA method-channel payloads.
- Added the high-level `ErikaImage.file` API, which inspects decoded metadata,
  selects HDR automatically when supported, and owns cancellation and native
  resource lifetimes.
- Exposed `ErikaImagePolicy` for app-owned source/output limits, parser work,
  timeout, queueing, concurrency, physical-size buckets, cache budget, and
  lifecycle trimming. Source and output limits now support up to 32 Mi pixels.
- Added the HarmonyOS NEXT API 18+ HDR surface contract, API 20 build target,
  DisplaySoloist VSync, explicit SDR fallback, and confirmed-output events.
- Added platform-neutral dynamic-range status/capabilities and `preferHdr`;
  platform-specific output mode spellings are deprecated.
- Added static HEIF and JPEG base-image decode alongside cached static AVIF.

## 0.1.8

- Switched the fork package to AV1 video and static AVIF-only native runtimes.
- Removed subtitle and danmaku support from the packaged runtime.

- Added per-open HTTP read-ahead tuning through `httpReadAheadBytes` on
  Android, Apple platforms, Windows, and OpenHarmony.
- Added a packed-alpha video mode that stores color and alpha side by side,
  reconstructs premultiplied transparency in the GPU renderer, and propagates
  the mode through the C ABI and Flutter platform integrations.
- Added a macOS `ErikaTextureVideoView` backed by IOSurface and Metal for
  Flutter-composited opacity, clipping, transforms, and color filters without
  per-frame CPU pixel readback.
- Added native macOS opacity and overlay compositing for transparent video
  platform views when backdrop-aware blending is required.
- Added Windows DirectComposition presentation for transparent video, with a
  premultiplied-alpha swap chain attached directly to the Flutter HWND and
  native overlay blending/opacity instead of a covering popup window.
- Raised the native playback-rate ceiling to 16× for short-form video effects.

## 0.1.7

- Published `erika_flutter` as a standalone pub.dev package with package-local
  license, changelog, metadata, and runnable iOS and macOS examples.
- Made verified, version-pinned native bundles the default for Android, Apple
  platforms, Windows, and OpenHarmony.
- Split Flutter Android runtimes by ABI so app builds download only the selected
  architecture and omit native-embedder static libraries.
- Added explicit `ERIKA_FORCE_SOURCE_BUILD=1` source builds without silent
  fallback when a prebuilt download or checksum fails.
- Added isolated package and cross-platform consumer validation in GitHub
  Actions.

## 0.1.6

- Added the ArtCNN C4F16 DS denoising and sharpening upscaler.
- Added source-aware SDR and EDR output selection on Apple platforms.
- Moved Android and macOS presentation work off the application UI thread.
- Exposed renderer resource status on Android, Windows, and OpenHarmony.
- Restored Windows system media controls and tightened the OpenHarmony bridge.

See the [repository changelog](https://github.com/Nyaaaaaaaaaaaaaaaaaaaaaaaa/Erika/blob/main/CHANGELOG.md)
for native engine and earlier release details.
