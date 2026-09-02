import erikaNative from 'liberika_ohos.so';

export interface ErikaNativeResponse {
  ok: boolean;
  status: number;
  error?: string;
  value?: ESObject;
}

export interface ErikaSurfaceOptions {
  surfaceId: BigInt;
  width: number;
  height: number;
  scale?: number;
}

export enum ErikaOutputMode {
  Sdr = 0,
  Auto = 3,
  PreferHdr = 4,
}

export enum ErikaDynamicRange {
  Unknown = 0,
  Sdr = 1,
  Hdr10Pq = 2,
  Hlg = 3,
  UltraHdrGainMap = 4,
}

export interface ErikaOutputStatus {
  requestedMode: number;
  activeEncoding: number;
  surfaceFormat: number;
  nativeDataSpace: number;
  requestedHeadroom: number;
  activeHeadroom: number;
  activeHeadroomKnown: boolean;
  extendedLinearActive: boolean;
  fallbackReason: number;
  fallbackCount: number;
  dataSpaceFailures: number;
  headroomUpdates: number;
  extendedLinearFrames: number;
  sourceDynamicRange: ErikaDynamicRange;
  activeDynamicRange: ErikaDynamicRange;
  hdrOutputConfirmed: boolean;
}

export interface ErikaHdrCapabilities {
  known: boolean;
  supportedDynamicRanges: Array<ErikaDynamicRange>;
  hdrSurfaceSupported: boolean;
  tenBitSurfaceSupported: boolean;
  hardwareAv1DecodeSupported: boolean;
  hardwareAv1DecodeKnown: boolean;
  nativeVsyncSupported: boolean;
  fallbackReason: number;
}

export interface ErikaPlayerConfig {
  outputMode?: ErikaOutputMode;
  edrHeadroom?: number;
  upscaler?: number;
}

export interface ErikaOpenOptions {
  httpHeaders?: ESObject;
  httpReadAheadBytes?: number;
}

/**
 * Native ArkTS wrapper around ErikaPresenterHandle.
 *
 * This package does not depend on Flutter. Hosts provide an XComponent surface
 * id to attachSurface(). Native DisplaySoloist drives rendering from display
 * VSync; renderTick() remains only as a compatibility/debug hook.
 */
export class ErikaPlayer {
  private readonly nativeId: number;
  private readonly outputMode: ErikaOutputMode;
  private disposed: boolean = false;
  private lastOutputStatus: string = '';

  constructor(config: ErikaPlayerConfig = {}) {
    const requestedMode: ErikaOutputMode = config.outputMode ?? ErikaOutputMode.Auto;
    this.outputMode = requestedMode === ErikaOutputMode.Sdr
      ? ErikaOutputMode.Sdr
      : requestedMode === ErikaOutputMode.Auto
        ? ErikaOutputMode.Auto
        : ErikaOutputMode.PreferHdr;
    const edrHeadroom: number = config.edrHeadroom ?? 1.0;
    const upscaler: number = config.upscaler ?? 0;
    this.nativeId = erikaNative.nativeCreate(this.outputMode, edrHeadroom, upscaler) as number;
    if (this.nativeId <= 0) {
      throw new Error('Erika player creation failed: ' + (erikaNative.nativeLastError() as string));
    }
  }

  get id(): number {
    return this.nativeId;
  }

  open(uri: string, options: ErikaOpenOptions = {}): ESObject | null {
    const readAhead: number = options.httpReadAheadBytes ?? 0;
    if (!Number.isSafeInteger(readAhead) || readAhead < 0) {
      throw new Error('httpReadAheadBytes must be a non-negative safe integer');
    }
    return this.invokeOrThrow('open', {
      uri: uri,
      httpHeaders: options.httpHeaders,
      httpReadAheadBytes: readAhead > 0 ? readAhead : undefined,
    });
  }

  play(): ESObject | null {
    return this.invokeOrThrow('play');
  }

  pause(): ESObject | null {
    return this.invokeOrThrow('pause');
  }

  stop(): ESObject | null {
    return this.invokeOrThrow('stop');
  }

  close(): ESObject | null {
    return this.invokeOrThrow('close');
  }

  seek(positionMicros: number): ESObject | null {
    return this.invokeOrThrow('seek', { positionMicros: positionMicros });
  }

  setPlaybackRate(rate: number): ESObject | null {
    return this.invokeOrThrow('setPlaybackRate', { rate: rate });
  }

  setVolume(volume: number): ESObject | null {
    return this.invokeOrThrow('setVolume', { volume: volume });
  }

  attachSurface(options: ErikaSurfaceOptions): void {
    const scale: number = options.scale ?? 1.0;
    const status: number = erikaNative.nativeAttachSurface(
      this.nativeId,
      options.surfaceId,
      options.width,
      options.height,
      scale,
    ) as number;
    this.checkStatus(status, 'attachSurface');
  }

  resizeSurface(width: number, height: number, scale: number = 1.0): void {
    const status: number = erikaNative.nativeResizeSurface(
      this.nativeId,
      width,
      height,
      scale,
    ) as number;
    this.checkStatus(status, 'resizeSurface');
  }

  detachSurface(): void {
    const status: number = erikaNative.nativeDetachSurface(this.nativeId) as number;
    this.checkStatus(status, 'detachSurface');
  }

  renderTick(timeSeconds: number): ErikaNativeResponse {
    this.ensureAlive();
    const raw: string = erikaNative.nativeRenderTick(this.nativeId, timeSeconds) as string;
    return JSON.parse(raw) as ErikaNativeResponse;
  }

  getOutputStatus(): ErikaOutputStatus {
    const status: ErikaOutputStatus = this.invokeOrThrow('getOutputStatus') as ErikaOutputStatus;
    status.requestedMode = this.outputMode;
    return status;
  }

  getHdrCapabilities(): ErikaHdrCapabilities {
    this.ensureAlive();
    const raw: string = erikaNative.nativeGetHdrCapabilitiesJson(this.nativeId) as string;
    return JSON.parse(raw) as ErikaHdrCapabilities;
  }

  audioOnlyTick(): void {
    this.ensureAlive();
    const status: number = erikaNative.nativeAudioOnlyTick(this.nativeId) as number;
    this.checkStatus(status, 'audioOnlyTick');
  }

  pollEvent(): ESObject | null {
    this.ensureAlive();
    const raw: ESObject = erikaNative.nativePollEvent(this.nativeId);
    if (raw === null || raw === undefined) {
      const outputStatus: ErikaOutputStatus = this.getOutputStatus();
      const serialized: string = JSON.stringify(outputStatus);
      if (serialized === this.lastOutputStatus) {
        return null;
      }
      this.lastOutputStatus = serialized;
      return {
        playerId: this.nativeId,
        kind: 14,
        outputStatus: outputStatus,
      };
    }
    return JSON.parse(raw as string) as ESObject;
  }

  captureFrame(width: number, height: number): Uint8Array | null {
    this.ensureAlive();
    return erikaNative.nativeCaptureFrame(this.nativeId, width, height) as Uint8Array | null;
  }

  registerSubtitleMemoryFont(bytes: Uint8Array): number {
    this.ensureAlive();
    const result: ESObject = erikaNative.nativeRegisterSubtitleMemoryFont(this.nativeId, bytes);
    const status: number = Number((result as Array<ESObject>)[0]);
    this.checkStatus(status, 'registerSubtitleMemoryFont');
    return Number((result as Array<ESObject>)[1]);
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    erikaNative.nativeDestroy(this.nativeId);
    this.disposed = true;
  }

  private invokeOrThrow(method: string, args: ESObject = {}): ESObject | null {
    const response: ErikaNativeResponse = this.invokeRaw(method, args);
    if (!response.ok) {
      throw new Error(response.error ?? ('Erika native method failed: ' + method));
    }
    return response.value ?? null;
  }

  private invokeRaw(method: string, args: ESObject): ErikaNativeResponse {
    this.ensureAlive();
    const raw: string = erikaNative.nativeInvoke(
      this.nativeId,
      method,
      JSON.stringify(args),
    ) as string;
    return JSON.parse(raw) as ErikaNativeResponse;
  }

  private checkStatus(status: number, operation: string): void {
    if (status !== 0) {
      throw new Error(operation + ' failed (' + status + '): ' +
        (erikaNative.nativeLastError() as string));
    }
  }

  private ensureAlive(): void {
    if (this.disposed) {
      throw new Error('ErikaPlayer has been disposed');
    }
  }
}
