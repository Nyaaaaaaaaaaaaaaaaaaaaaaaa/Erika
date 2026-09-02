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
