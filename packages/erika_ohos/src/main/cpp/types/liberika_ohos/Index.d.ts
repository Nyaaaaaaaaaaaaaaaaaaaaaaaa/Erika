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

export interface ErikaNativeSdrImage {
  metadata: ErikaNativeImageMetadata;
  width: number;
  height: number;
  rowBytes: number;
  rgba: Uint8Array;
}

export interface ErikaNativeHdrImage {
  metadata: ErikaNativeImageMetadata;
  imageId: BigInt;
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
  maxSdrOutputPixels: number;
  maxConcurrentDecodes: number;
  maxActiveHdrImages: number;
}

export interface ErikaNativeImageDiagnostics {
  queued: number;
  inflight: number;
  decodeCount: number;
  queuedCancelled: number;
  nativeHandleCount: number;
  hdrHandleCount: number;
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

export const nativeCreate: (
  outputMode: number,
  headroom: number,
  upscaler: number,
) => number;
export const nativeLastError: () => string | null;
export const nativeDestroy: (playerId: number) => void;
export const nativeInvoke: (
  playerId: number,
  method: string,
  argumentsJson: string,
) => string;
export const nativeRegisterSubtitleMemoryFont: (
  playerId: number,
  bytes: Uint8Array,
) => Array<number>;
export const nativeAttachSurface: (
  playerId: number,
  surfaceId: BigInt,
  width: number,
  height: number,
  scale: number,
) => number;
export const nativeResizeSurface: (
  playerId: number,
  width: number,
  height: number,
  scale: number,
) => number;
export const nativeDetachSurface: (playerId: number) => number;
export const nativeRenderTick: (
  playerId: number,
  timeSeconds: number,
) => string;
export const nativePollEvent: (playerId: number) => string | null;
export const nativeGetHdrCapabilitiesJson: (playerId: number) => string;
export const nativeAudioOnlyTick: (playerId: number) => number;
export const nativeCaptureFrame: (
  playerId: number,
  width: number,
  height: number,
) => Uint8Array | null;

export const nativeGetImageCapabilities: () => ErikaNativeImageCapabilities;
export const nativeGetImageDiagnostics: () => ErikaNativeImageDiagnostics;
export const nativeDecodeSdrImage: (
  operationId: BigInt,
  localPath: string,
  cacheWidth: number,
  cacheHeight: number,
) => Promise<ErikaNativeSdrImage>;
export const nativeDecodeHdrImage: (
  operationId: BigInt,
  localPath: string,
) => Promise<ErikaNativeHdrImage>;
export const nativeCancelImageDecode: (operationId: BigInt) => boolean;
export const nativeAttachHdrImageSurface: (
  imageId: BigInt,
  surfaceId: BigInt,
  surfaceGeneration: BigInt,
  width: number,
  height: number,
  scale: number,
) => Promise<ErikaNativeImageResponse<ErikaNativeImageOutputStatus>>;
export const nativeResizeHdrImageSurface: (
  imageId: BigInt,
  surfaceGeneration: BigInt,
  width: number,
  height: number,
  scale: number,
) => Promise<ErikaNativeImageResponse<ErikaNativeImageOutputStatus>>;
export const nativeRenderHdrImageSurface: (
  imageId: BigInt,
  surfaceGeneration: BigInt,
) => Promise<ErikaNativeImageResponse<ErikaNativeImageOutputStatus>>;
export const nativeDetachHdrImageSurface: (
  imageId: BigInt,
  surfaceGeneration: BigInt,
) => Promise<ErikaNativeImageResponse>;
export const nativeDestroyHdrImage: (
  imageId: BigInt,
) => Promise<ErikaNativeImageResponse>;
