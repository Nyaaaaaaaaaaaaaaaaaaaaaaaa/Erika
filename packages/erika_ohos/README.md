# erika

Native ArkTS/HarmonyOS NEXT SDK powered by Erika. This package is independent of
Flutter and exposes the Erika presenter through an ArkTS-friendly API.

The supported package target is HarmonyOS NEXT arm64 (API 18+, built with API
20). The package contains the native
N-API bridge and the matching `liberika_capi.so` runtime. A host application
provides an `XComponent` surface id through `attachSurface()`. Native
DisplaySoloist drives rendering from VSync.

## Installation

```sh
ohpm install erika
```

## Usage

The package owns the native presenter, while the ArkTS host owns the
`XComponent` lifecycle. Attach the surface when it becomes available, resize
it when the host reports a new `SurfaceRect`, and dispose the player when the
surface is destroyed:

```ts
import { ErikaNativeResponse, ErikaPlayer } from 'erika';

class ErikaSurfaceController extends XComponentController {
  private readonly player: ErikaPlayer = new ErikaPlayer();
  private attached: boolean = false;
  private pendingUri: string = '';

  onSurfaceCreated(surfaceId: string): void {
    console.info(`Erika XComponent surface created: ${surfaceId}`);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    if (!this.attached) {
      this.player.attachSurface({
        surfaceId: BigInt(surfaceId),
        width: rect.surfaceWidth,
        height: rect.surfaceHeight,
        scale: 1.0,
      });
      this.attached = true;
    } else {
      this.player.resizeSurface(rect.surfaceWidth, rect.surfaceHeight);
    }
    this.startPendingUri();
  }

  onSurfaceDestroyed(_surfaceId: string): void {
    if (this.attached) {
      this.player.detachSurface();
      this.attached = false;
    }
    this.player.dispose();
  }

  open(uri: string): void {
    this.pendingUri = uri;
    this.startPendingUri();
  }

  private startPendingUri(): void {
    if (!this.attached || this.pendingUri.length === 0) {
      return;
    }
    const uri: string = this.pendingUri;
    this.pendingUri = '';
    this.player.open(uri);
    this.player.play();
  }
}
```

Use the controller with an ArkUI surface. The controller queues `open()` until
the first surface size callback has attached the native window, so the host can
call it from `onLoad()`. Rendering starts automatically after surface attach:

```ts
@Entry
@Component
struct VideoPage {
  private readonly surfaceController: ErikaSurfaceController =
    new ErikaSurfaceController();

  build() {
    XComponent({
      id: 'erika-surface',
      type: XComponentType.SURFACE,
      controller: this.surfaceController,
    })
      .width('100%')
      .height('100%')
      .onLoad(() => {
        this.surfaceController.open('https://example.com/video.mp4');
      });
  }
}
```

`renderTick()` remains a compatibility/debug hook; applications do not need a
timer or frame callback. `getHdrCapabilities()` reports negotiated window and
VSync support, while `pollEvent()` emits de-duplicated complete output status
snapshots. `audioOnlyTick()` remains API-compatible for an AV1 session's ancillary
audio path; standalone audio-only input is rejected by this AV1/AVIF-specialized
fork.

## Static images

Static AVIF/HEIF/JPEG decoding is separate from `ErikaPlayer`. It decodes one
frame without creating playback state, a timeline, VSync, event polling, or an
audio path. Version 0.2 accepts an application-cached local file only; keep
network download, authentication, encoded-file caching, and same-key
single-flight in the host app. `ErikaImageSource.cacheKey` is the host's stable
cache identity; the low-level decoder does not retain a decoded PixelMap cache.
`cacheWidth`/`cacheHeight` bound the retained NV12/P010 planes. Source and SDR
output admission both support up to 32 Mi pixels. The software decoder can still
transiently materialize the admitted source frame before repacking it.

For an SDR list or thumbnail, request the actual display size so native decode
and conversion stay within the bounded image queue and output limits:

```ts
import { ErikaImageDecoder, ErikaImageSource } from 'erika';

const operation = ErikaImageDecoder.decodeSdr({
  source: ErikaImageSource.file(cachePath, revisionKey),
  cacheWidth: 720,
});

// operation.cancel() removes queued work or asks an active decode to stop.
const image = await operation.promise;
console.info(
  `decoded ${image.width}x${image.height}, rowBytes=${image.rowBytes}`,
);
// image.rgba is RGBA8888 for the host's PixelMap/image cache.
```

HDR details retain one decoded native frame and attach it directly to an
`XComponent` surface. One `ErikaHdrDecodedImage` has one surface owner at a
time. `detachSurface()` must finish before the XComponent releases its surface,
and `dispose()` waits for native detach/destruction before releasing the image.
Await attach, resize, render, detach, and dispose in lifecycle order rather than
issuing overlapping host calls:

```ts
import {
  ErikaHdrDecodedImage,
  ErikaImageDecoder,
  ErikaImageSource,
} from 'erika';

let detail: ErikaHdrDecodedImage | undefined = await
  ErikaImageDecoder.decodeHdr({
    source: ErikaImageSource.file(cachePath, revisionKey),
  }).promise;

const status = await detail.attachSurface({
  surfaceId: BigInt(surfaceId),
  width: rect.surfaceWidth,
  height: rect.surfaceHeight,
  scale: 1.0,
});

// This is the only positive HDR signal. Capability flags merely report that
// the native XComponent path exists.
if (status.hdrOutputConfirmed) {
  console.info('HDR frame was presented');
}

// onSurfaceChanged:
await detail.resizeSurface(rect.surfaceWidth, rect.surfaceHeight);
await detail.renderSurface();

// onSurfaceDestroyed / page teardown:
await detail.detachSurface();
await detail.dispose();
detail = undefined;
```

`ErikaImageDecoder.capabilities()` reports the route and hard resource limits;
it does not claim that the current display is HDR. The current standalone image
decoder backend is software. The native boundary permits one active HDR image
reservation (including a queued/running HDR decode), so dispose the current
detail before decoding another and inspect `diagnostics().hdrHandleCount` when
profiling lifecycle behavior. `hdrOutputConfirmed` becomes true only after a
successful native present. PQ is presented as PQ and HLG is converted by the
renderer for the negotiated HDR output; failed or SDR output remains explicit
in `ErikaImageOutputStatus`. The HarmonyOS static surface currently publishes a
nominal 1000-nit mastering/MaxCLL envelope and 400-nit MaxFALL; per-source AVIF
mastering metadata is not yet propagated to the window.

## HTTP options

For HTTP(S) playback, `open` accepts per-request headers and a read-ahead
window:

```ts
this.player.open('https://example.com/video.mp4', {
  httpHeaders: {
    'Authorization': 'Bearer token',
    'Referer': 'https://example.com/',
  },
  httpReadAheadBytes: 16 * 1024 * 1024,
});
```

Headers are used for HEAD, Range GET, and prefetch requests. A positive
`httpReadAheadBytes` overrides `ERIKA_HTTP_READAHEAD_BYTES`; zero or omission
uses that environment variable when set, otherwise the 2 MiB default. These
options are ignored for local files.

The package is licensed under MPL-2.0. See `THIRD_PARTY_NOTICES.md` for the
licenses of the bundled native dependencies.
