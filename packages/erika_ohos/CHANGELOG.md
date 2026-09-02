# Changelog

## 0.2.0 - 2026-09-03

- Added verified 10-bit BT.2020 PQ XComponent output with HDR metadata,
  DisplaySoloist VSync, explicit SDR fallback, and output capability/status APIs.
- Added static HEIF and JPEG base-image decode alongside cached static AVIF.

## 0.1.8

- Added hardware-first AV1/AVIF decoding with dav1d fallback.
- Removed subtitle and danmaku support from the packaged runtime.

- Added HTTP headers and per-open read-ahead tuning to `ErikaPlayer.open`.

## 0.1.7

- Initial ArkTS/OHPM package scaffold.
- Added native N-API presenter bridge for OpenHarmony arm64.
- Added surface attachment, playback control, render ticks, events, screenshots,
  and subtitle memory-font registration.
