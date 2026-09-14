export const nativeCreate: (outputMode: number, headroom: number, upscaler: number) => Promise<number>;
export const nativeDestroy: (playerId: number) => Promise<void>;
export const nativeInvoke: (playerId: number, method: string, args: string) => Promise<string>;
export const nativeRegisterSubtitleMemoryFont: (playerId: number, bytes: Uint8Array) => Promise<Array<number>>;
export const nativeAttachSurface: (playerId: number, surfaceId: number, width: number, height: number, scale: number) => Promise<number>;
export const nativeResizeSurface: (playerId: number, width: number, height: number, scale: number) => Promise<number>;
export const nativeDetachSurface: (playerId: number) => Promise<number>;
export const nativeRenderTick: (playerId: number, timestamp: number) => Promise<string>;
export const nativePollEvent: (playerId: number) => Promise<string | null>;
export const nativeGetHdrCapabilitiesJson: (playerId: number) => Promise<string>;
export const nativeCaptureFrame: (playerId: number, width: number, height: number) => Promise<Uint8Array | null>;

export interface ErikaNativeImageMetadata {
  width: number;
  height: number;
  bitDepth: number;
  primaries: number;
  transfer: number;
  matrix: number;
  colorRange: number;
  sourceDynamicRange: number;
  decodeBackend: number;
}

export interface ErikaNativeRetainedImage {
  metadata: ErikaNativeImageMetadata;
  imageId: number;
}

export interface ErikaNativeSdrImage {
  metadata: ErikaNativeImageMetadata;
  width: number;
  height: number;
  rowBytes: number;
  rgba: Uint8Array;
}

export interface ErikaNativeImageResponse<T = undefined> {
  ok: boolean;
  status: number;
  kind?: number;
  error?: string;
  value?: T;
}

export interface ErikaNativeImageCapabilities {
  sdrDecodeSupported: boolean;
  hdrSurfaceSupported: boolean;
  networkSourceSupported: boolean;
  activeBackend: string;
  maxEncodedBytes: number;
  maxSourcePixels: number;
  maxOutputPixels: number;
  maxSdrOutputPixels: number;
  maxConcurrentDecodes: number;
  maxActiveImageSurfaces: number;
  maxActiveHdrImages: number;
}

export interface ErikaNativeImageDiagnostics {
  queued: number;
  inflight: number;
  decodeCount: number;
  queuedCancelled: number;
  nativeHandleCount: number;
  hdrHandleCount: number;
  retainedImageHandleCount: number;
  activeBackend: string;
}

export interface ErikaNativeImageOutputStatus {
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
  sourceDynamicRange: number;
  activeDynamicRange: number;
  hdrOutputConfirmed: boolean;
}

export const nativeConfigureImagePipeline: (
  maxEncodedBytes: number,
  maxSourcePixels: number,
  maxOutputPixels: number,
  maxPacketsBeforeFrame: number,
  decodeTimeoutMillis: number,
  maxQueuedDecodes: number,
  maxConcurrentDecodes: number,
) => ErikaNativeImageResponse;
export const nativeGetImageCapabilities: () => ErikaNativeImageCapabilities;
export const nativeGetImageDiagnostics: () => ErikaNativeImageDiagnostics;
export const nativeDecodeSdrImage: (
  operationId: number,
  localPath: string,
  cacheWidth: number,
  cacheHeight: number,
) => Promise<ErikaNativeSdrImage>;
export const nativeDecodeHdrImage: (
  operationId: number,
  localPath: string,
  cacheWidth: number,
  cacheHeight: number,
) => Promise<ErikaNativeRetainedImage>;
export const nativeDecodeImageSurface: (
  operationId: number,
  localPath: string,
  cacheWidth: number,
  cacheHeight: number,
) => Promise<ErikaNativeRetainedImage>;
export const nativeCancelImageDecode: (operationId: number) => boolean;
export const nativeAttachHdrImageSurface: (
  imageId: number,
  surfaceId: number,
  surfaceGeneration: number,
  width: number,
  height: number,
  scale: number,
  preferHdr?: boolean,
) => Promise<ErikaNativeImageResponse<ErikaNativeImageOutputStatus>>;
export const nativeResizeHdrImageSurface: (
  imageId: number,
  surfaceGeneration: number,
  width: number,
  height: number,
  scale: number,
) => Promise<ErikaNativeImageResponse<ErikaNativeImageOutputStatus>>;
export const nativeRenderHdrImageSurface: (
  imageId: number,
  surfaceGeneration: number,
) => Promise<ErikaNativeImageResponse<ErikaNativeImageOutputStatus>>;
export const nativeDetachHdrImageSurface: (
  imageId: number,
  surfaceGeneration: number,
) => Promise<ErikaNativeImageResponse>;
export const nativeDestroyHdrImage: (
  imageId: number,
) => Promise<ErikaNativeImageResponse>;
