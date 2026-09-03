import erikaNative from 'liberika_ohos.so';

export enum ErikaImageErrorReason {
  UnsupportedPlatform = 1,
  UnsupportedFormat = 2,
  Corrupt = 3,
  Source = 4,
  Network = 5,
  Cancelled = 6,
  ResourceLimit = 7,
  Renderer = 8,
  Internal = 9,
  Busy = 10,
}

export enum ErikaImageDecodeBackend {
  Unknown = 0,
  Software = 1,
  Hardware = 2,
}

export enum ErikaImageDynamicRange {
  Unknown = 0,
  Sdr = 1,
  Hdr10Pq = 2,
  Hlg = 3,
  UltraHdrGainMap = 4,
}

export class ErikaImageException extends Error {
  readonly reason: ErikaImageErrorReason;

  constructor(reason: ErikaImageErrorReason, message: string) {
    super(message);
    this.reason = reason;
  }
}

export interface ErikaImageMetadata {
  width: number;
  height: number;
  bitDepth: number;
  primaries: number;
  transfer: number;
  matrix: number;
  colorRange: number;
  sourceDynamicRange: ErikaImageDynamicRange;
  decodeBackend: ErikaImageDecodeBackend;
}

export interface ErikaImageCapabilities {
  sdrDecodeSupported: boolean;
  /** The native XComponent path exists; this does not assert display HDR. */
  hdrSurfaceSupported: boolean;
  networkSourceSupported: boolean;
  activeBackend: string;
  maxEncodedBytes: number;
  maxSourcePixels: number;
  maxSdrOutputPixels: number;
  maxConcurrentDecodes: number;
  maxActiveHdrImages: number;
}

export interface ErikaImageDiagnostics {
  queued: number;
  inflight: number;
  decodeCount: number;
  queuedCancelled: number;
  nativeHandleCount: number;
  hdrHandleCount: number;
  activeBackend: string;
}

export interface ErikaImageOutputStatus {
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
  sourceDynamicRange: ErikaImageDynamicRange;
  activeDynamicRange: ErikaImageDynamicRange;
  /** True only after the native renderer presented this frame as HDR. */
  hdrOutputConfirmed: boolean;
}

export interface ErikaHdrImageSurfaceOptions {
  surfaceId: BigInt;
  width: number;
  height: number;
  scale?: number;
}

export class ErikaImageSource {
  readonly path: string;
  readonly cacheKey: string;

  private constructor(path: string, cacheKey: string) {
    this.path = path;
    this.cacheKey = cacheKey;
  }

  static file(path: string, cacheKey: string = path): ErikaImageSource {
    if (path.length === 0 || path.startsWith('http://') || path.startsWith('https://')) {
      throw new ErikaImageException(
        ErikaImageErrorReason.Source,
        'Static image v1 requires an application-cached local file',
      );
    }
    return new ErikaImageSource(path, cacheKey);
  }
}

export interface ErikaImageDecodeRequest {
  source: ErikaImageSource;
  cacheWidth?: number;
  cacheHeight?: number;
}

interface ErikaNativeImageResponse {
  ok: boolean;
  status: number;
  kind?: number;
  error?: string;
  value?: ESObject;
}

interface ErikaNativeSdrImage {
  metadata: ErikaImageMetadata;
  width: number;
  height: number;
  rowBytes: number;
  rgba: Uint8Array;
}

interface ErikaNativeHdrImage {
  metadata: ErikaImageMetadata;
  imageId: BigInt;
}

interface ErikaNativeImageModule {
  nativeGetImageCapabilities(): ErikaImageCapabilities;
  nativeGetImageDiagnostics(): ErikaImageDiagnostics;
  nativeDecodeSdrImage(
    operationId: BigInt,
    path: string,
    cacheWidth: number,
    cacheHeight: number,
  ): Promise<ESObject>;
  nativeDecodeHdrImage(
    operationId: BigInt,
    path: string,
    cacheWidth: number,
    cacheHeight: number,
  ): Promise<ESObject>;
  nativeCancelImageDecode(operationId: BigInt): boolean;
  nativeAttachHdrImageSurface(
    imageId: BigInt,
    surfaceId: BigInt,
    surfaceGeneration: BigInt,
    width: number,
    height: number,
    scale: number,
  ): Promise<ErikaNativeImageResponse>;
  nativeResizeHdrImageSurface(
    imageId: BigInt,
    surfaceGeneration: BigInt,
    width: number,
    height: number,
    scale: number,
  ): Promise<ErikaNativeImageResponse>;
  nativeRenderHdrImageSurface(
    imageId: BigInt,
    surfaceGeneration: BigInt,
  ): Promise<ErikaNativeImageResponse>;
  nativeDetachHdrImageSurface(
    imageId: BigInt,
    surfaceGeneration: BigInt,
  ): Promise<ErikaNativeImageResponse>;
  nativeDestroyHdrImage(imageId: BigInt): Promise<ErikaNativeImageResponse>;
}

const erikaImageNative: ErikaNativeImageModule =
  erikaNative as ErikaNativeImageModule;

function imageError(error: ESObject, fallback: string): ErikaImageException {
  const reason: ErikaImageErrorReason = Number(error.kind ?? 9) as ErikaImageErrorReason;
  return new ErikaImageException(reason, String(error.message ?? fallback));
}

function responseValue<T>(response: ErikaNativeImageResponse, fallback: string): T {
  if (!response.ok) {
    throw new ErikaImageException(
      Number(response.kind ?? 9) as ErikaImageErrorReason,
      response.error ?? fallback,
    );
  }
  return response.value as T;
}

function checkResponse(response: ErikaNativeImageResponse, fallback: string): void {
  if (!response.ok) {
    throw new ErikaImageException(
      Number(response.kind ?? 9) as ErikaImageErrorReason,
      response.error ?? fallback,
    );
  }
}

export class ErikaImageDecodeOperation<T> {
  readonly promise: Promise<T>;
  private readonly operationId: BigInt;
  private completed: boolean = false;

  constructor(operationId: BigInt, nativePromise: Promise<ESObject>, convert: (value: ESObject) => T) {
    this.operationId = operationId;
    this.promise = nativePromise.then(
      (value: ESObject): T => {
        this.completed = true;
        return convert(value);
      },
      (error: ESObject): T => {
        this.completed = true;
        throw imageError(error, 'Erika static image decode failed');
      },
    );
  }

  cancel(): boolean {
    if (this.completed) {
      return false;
    }
    return erikaImageNative.nativeCancelImageDecode(this.operationId);
  }
}

export class ErikaSdrDecodedImage {
  readonly metadata: ErikaImageMetadata;
  readonly width: number;
  readonly height: number;
  readonly rowBytes: number;
  readonly rgba: Uint8Array;

  constructor(nativeImage: ErikaNativeSdrImage) {
    this.metadata = nativeImage.metadata;
    this.width = nativeImage.width;
    this.height = nativeImage.height;
    this.rowBytes = nativeImage.rowBytes;
    this.rgba = nativeImage.rgba;
  }
}

export class ErikaHdrDecodedImage {
  readonly imageId: BigInt;
  readonly metadata: ErikaImageMetadata;
  private nextSurfaceGeneration: number = 0;
  private surfaceGeneration: BigInt = BigInt(0);
  private disposed: boolean = false;
  private disposePromise?: Promise<void>;

  constructor(nativeImage: ErikaNativeHdrImage) {
    this.imageId = nativeImage.imageId;
    this.metadata = nativeImage.metadata;
  }

  attachSurface(options: ErikaHdrImageSurfaceOptions): Promise<ErikaImageOutputStatus> {
    this.ensureAlive();
    const scale: number = options.scale ?? 1.0;
    this.nextSurfaceGeneration += 1;
    const generation: BigInt = BigInt(this.nextSurfaceGeneration);
    this.surfaceGeneration = generation;
    const nativePromise = erikaImageNative.nativeAttachHdrImageSurface(
      this.imageId,
      options.surfaceId,
      generation,
      options.width,
      options.height,
      scale,
    );
    return nativePromise.then(
      (response: ErikaNativeImageResponse): ErikaImageOutputStatus =>
        responseValue<ErikaImageOutputStatus>(response, 'Unable to attach HDR image surface'),
      (error: ESObject): ErikaImageOutputStatus => {
        throw imageError(error, 'Unable to attach HDR image surface');
      },
    );
  }

  resizeSurface(width: number, height: number, scale: number = 1.0): Promise<ErikaImageOutputStatus> {
    this.ensureSurface();
    return erikaImageNative.nativeResizeHdrImageSurface(
      this.imageId,
      this.surfaceGeneration,
      width,
      height,
      scale,
    ).then(
      (response: ErikaNativeImageResponse): ErikaImageOutputStatus =>
        responseValue<ErikaImageOutputStatus>(response, 'Unable to resize HDR image surface'),
      (error: ESObject): ErikaImageOutputStatus => {
        throw imageError(error, 'Unable to resize HDR image surface');
      },
    );
  }

  renderSurface(): Promise<ErikaImageOutputStatus> {
    this.ensureSurface();
    return erikaImageNative.nativeRenderHdrImageSurface(
      this.imageId,
      this.surfaceGeneration,
    ).then(
      (response: ErikaNativeImageResponse): ErikaImageOutputStatus =>
        responseValue<ErikaImageOutputStatus>(response, 'Unable to render HDR image surface'),
      (error: ESObject): ErikaImageOutputStatus => {
        throw imageError(error, 'Unable to render HDR image surface');
      },
    );
  }

  detachSurface(): Promise<void> {
    this.ensureAlive();
    const generation: BigInt = this.surfaceGeneration;
    if (generation === BigInt(0)) {
      return Promise.resolve();
    }
    return erikaImageNative.nativeDetachHdrImageSurface(
      this.imageId,
      generation,
    ).then(
      (response: ErikaNativeImageResponse): void => {
        checkResponse(response, 'Unable to detach HDR image surface');
        if (this.surfaceGeneration === generation) {
          this.surfaceGeneration = BigInt(0);
        }
      },
      (error: ESObject): void => {
        throw imageError(error, 'Unable to detach HDR image surface');
      },
    );
  }

  dispose(): Promise<void> {
    if (this.disposed) {
      return Promise.resolve();
    }
    if (this.disposePromise !== undefined) {
      return this.disposePromise;
    }
    const operation = erikaImageNative.nativeDestroyHdrImage(
      this.imageId,
    ).then(
      (response: ErikaNativeImageResponse): void => {
        if (!response.ok) {
          this.disposePromise = undefined;
        }
        checkResponse(response, 'Unable to dispose HDR image');
        this.disposed = true;
        this.surfaceGeneration = BigInt(0);
      },
      (error: ESObject): void => {
        this.disposePromise = undefined;
        throw imageError(error, 'Unable to dispose HDR image');
      },
    );
    this.disposePromise = operation;
    return operation;
  }

  private ensureAlive(): void {
    if (this.disposed) {
      throw new ErikaImageException(
        ErikaImageErrorReason.Source,
        'ErikaHdrDecodedImage has been disposed',
      );
    }
  }

  private ensureSurface(): void {
    this.ensureAlive();
    if (this.surfaceGeneration === BigInt(0)) {
      throw new ErikaImageException(
        ErikaImageErrorReason.Renderer,
        'Attach an XComponent surface before rendering',
      );
    }
  }
}

export class ErikaImageDecoder {
  private static nextOperationId: number = 1;

  static capabilities(): ErikaImageCapabilities {
    return erikaImageNative.nativeGetImageCapabilities();
  }

  static diagnostics(): ErikaImageDiagnostics {
    return erikaImageNative.nativeGetImageDiagnostics();
  }

  static decodeSdr(
    request: ErikaImageDecodeRequest,
  ): ErikaImageDecodeOperation<ErikaSdrDecodedImage> {
    const operationId: BigInt = ErikaImageDecoder.newOperationId();
    const nativePromise: Promise<ESObject> = erikaImageNative.nativeDecodeSdrImage(
      operationId,
      request.source.path,
      request.cacheWidth ?? 0,
      request.cacheHeight ?? 0,
    );
    return new ErikaImageDecodeOperation<ErikaSdrDecodedImage>(
      operationId,
      nativePromise,
      (value: ESObject): ErikaSdrDecodedImage =>
        new ErikaSdrDecodedImage(value as ErikaNativeSdrImage),
    );
  }

  static decodeHdr(
    request: ErikaImageDecodeRequest,
  ): ErikaImageDecodeOperation<ErikaHdrDecodedImage> {
    const operationId: BigInt = ErikaImageDecoder.newOperationId();
    const nativePromise: Promise<ESObject> = erikaImageNative.nativeDecodeHdrImage(
      operationId,
      request.source.path,
      request.cacheWidth ?? 0,
      request.cacheHeight ?? 0,
    );
    return new ErikaImageDecodeOperation<ErikaHdrDecodedImage>(
      operationId,
      nativePromise,
      (value: ESObject): ErikaHdrDecodedImage =>
        new ErikaHdrDecodedImage(value as ErikaNativeHdrImage),
    );
  }

  private static newOperationId(): BigInt {
    const value: number = ErikaImageDecoder.nextOperationId;
    ErikaImageDecoder.nextOperationId += 1;
    return BigInt(value);
  }
}
