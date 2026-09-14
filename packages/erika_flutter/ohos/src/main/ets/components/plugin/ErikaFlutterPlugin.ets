import {
  AbilityAware,
  AbilityPluginBinding,
  EventChannel,
  EventSink,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StandardMethodCodec,
  SurfaceTextureEntry,
} from '@ohos/flutter_ohos';
import { common, UIAbility } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { image } from '@kit.ImageKit';
import erikaNative from 'liberika_flutter.so';

interface NativeResponse {
  ok: boolean;
  status: number;
  error?: string;
  value?: ESObject;
}

interface ErikaTexture {
  entry: SurfaceTextureEntry;
  surfaceId: number;
  width: number;
  height: number;
  scale: number;
  playerId: number;
}

interface ErikaImageTexture {
  textureId: number;
  entry: SurfaceTextureEntry;
  surfaceId: number;
  width: number;
  height: number;
  scale: number;
  imageId: number;
  surfaceGeneration: number;
  presentation: string;
}

interface ErikaImageNativeResponse {
  ok: boolean;
  status: number;
  kind?: number;
  error?: string;
  value?: ESObject;
}

interface ErikaImageMetadataValue {
  width: number;
  height: number;
  sourceDynamicRange: number;
}

interface ErikaImageDecodedValue {
  imageId: number;
  metadata: ErikaImageMetadataValue;
}

interface ErikaImageTextureAttachment {
  texture: ErikaImageTexture;
  outputStatus: ESObject;
}

// Keep static-image N-API calls typed independently from the legacy player
// module surface. The declaration file publishes the same signatures to OHPM
// consumers; this local boundary makes plugin implementation type checks
// explicit even when the N-API default import is treated as an untyped module.
interface ErikaImageNativeModule {
  nativeConfigureImagePipeline(
    maxEncodedBytes: number,
    maxSourcePixels: number,
    maxOutputPixels: number,
    maxPacketsBeforeFrame: number,
    decodeTimeoutMillis: number,
    maxQueuedDecodes: number,
    maxConcurrentDecodes: number,
  ): ErikaImageNativeResponse;
  nativeGetImageCapabilities(): ESObject;
  nativeGetImageDiagnostics(): ESObject;
  nativeDecodeImageSurface(
    operationId: number,
    localPath: string,
    cacheWidth: number,
    cacheHeight: number,
  ): Promise<ErikaImageDecodedValue>;
  nativeCancelImageDecode(operationId: number): boolean;
  nativeAttachHdrImageSurface(
    imageId: number,
    surfaceId: number,
    surfaceGeneration: number,
    width: number,
    height: number,
    scale: number,
    preferHdr: boolean,
  ): Promise<ErikaImageNativeResponse>;
  nativeResizeHdrImageSurface(
    imageId: number,
    surfaceGeneration: number,
    width: number,
    height: number,
    scale: number,
  ): Promise<ErikaImageNativeResponse>;
  nativeDetachHdrImageSurface(
    imageId: number,
    surfaceGeneration: number,
  ): Promise<ErikaImageNativeResponse>;
  nativeDestroyHdrImage(imageId: number): Promise<ErikaImageNativeResponse>;
}

const erikaImageNative: ErikaImageNativeModule =
  erikaNative as ErikaImageNativeModule;

interface ErikaMediaMetadata {
  title: string;
  artist?: string;
  album?: string;
  artwork?: Uint8Array;
}

interface ErikaMediaState {
  playbackState: number;
  positionMicros: number;
  durationMicros: number;
  playbackRate: number;
}

interface ErikaMediaNavigation {
  previousEnabled: boolean;
  nextEnabled: boolean;
}

const PLAYER_CHANNEL: string = 'erika_flutter/player';
const EVENT_CHANNEL: string = 'erika_flutter/events';
const EVENT_POLL_INTERVAL_MS: number = 50;
const STATE_CHANGED_EVENT_KIND: number = 1;
const DURATION_CHANGED_EVENT_KIND: number = 2;
const POSITION_CHANGED_EVENT_KIND: number = 3;
const SYSTEM_MEDIA_NAVIGATION_EVENT_KIND: number = 13;
const OUTPUT_STATUS_CHANGED_EVENT_KIND: number = 14;
const PLAYING_STATE: number = 3;
const PAUSED_STATE: number = 4;
const STOPPED_STATE: number = 5;
const CLOSED_STATE: number = 6;
const ERROR_STATE: number = 7;

export default class ErikaFlutterPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private binding: FlutterPluginBinding | null = null;
  private ability: UIAbility | null = null;
  private methodChannel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null;
  private players: Set<number> = new Set();
  private outputModes: Map<number, number> = new Map();
  private textures: Map<number, ErikaTexture> = new Map();
  // Static-image textures are intentionally independent of video textures.
  // An image surface owns an ErikaImageHandle, not an ErikaPlayer.
  private imageTextures: Map<number, ErikaImageTexture> = new Map();
  private imageTextureByImageId: Map<number, number> = new Map();
  private imageIds: Set<number> = new Set();
  private nextImageSurfaceGeneration: number = 1;
  private mediaMetadata: Map<number, ErikaMediaMetadata> = new Map();
  private mediaStates: Map<number, ErikaMediaState> = new Map();
  private mediaNavigation: Map<number, ErikaMediaNavigation> = new Map();
  private currentPlayerId: number = 0;
  private currentSession: avSession.AVSession | null = null;
  private sessionPromise: Promise<avSession.AVSession | null> | null = null;
  private sessionGeneration: number = 0;
  private eventTimer: number = -1;
  private lastOutputStatus: Map<number, string> = new Map();

  getUniqueClassName(): string {
    return 'ErikaFlutterPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.binding = binding;
    const messenger = binding.getBinaryMessenger();
    this.methodChannel = new MethodChannel(
      messenger,
      PLAYER_CHANNEL,
      StandardMethodCodec.INSTANCE,
    );
    this.methodChannel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(
      messenger,
      EVENT_CHANNEL,
      StandardMethodCodec.INSTANCE,
    );
    this.eventChannel.setStreamHandler({
      onListen: (_args: ESObject, sink: EventSink): void => {
        this.eventSink = sink;
        this.drainAllEvents();
      },
      onCancel: (_args: ESObject): void => {
        this.eventSink = null;
      },
    });
    this.startEventLoop();
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.stopEventLoop();
    this.imageTextures.forEach((texture: ErikaImageTexture, textureId: number): void => {
      // nativeDestroyHdrImage synchronously claims the image session before
      // its asynchronous worker releases the retained OHNativeWindow. Keep
      // that ownership handoff ahead of unregistering Flutter's texture.
      this.destroyImageQuietly(texture.imageId);
      this.binding?.getTextureRegistry()?.unregisterTexture(textureId);
    });
    this.imageTextures.clear();
    this.imageTextureByImageId.clear();
    this.imageIds.forEach((imageId: number): void => this.destroyImageQuietly(imageId));
    this.imageIds.clear();
    this.textures.forEach((texture: ErikaTexture, textureId: number): void => {
      if (texture.playerId > 0) {
        erikaNative.nativeDetachSurface(texture.playerId);
      }
      this.binding?.getTextureRegistry()?.unregisterTexture(textureId);
    });
    this.textures.clear();
    this.players.forEach((playerId: number): void => {
      erikaNative.nativeDestroy(playerId);
    });
    this.players.clear();
    this.outputModes.clear();
    this.mediaMetadata.clear();
    this.mediaStates.clear();
    this.mediaNavigation.clear();
    this.lastOutputStatus.clear();
    this.currentPlayerId = 0;
    this.destroyAVSession();
    this.methodChannel?.setMethodCallHandler(null);
    this.eventChannel?.setStreamHandler(null);
    this.methodChannel = null;
    this.eventChannel = null;
    this.eventSink = null;
    this.binding = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.ability = binding.getAbility();
  }

  onDetachedFromAbility(): void {
    this.ability = null;
    this.destroyAVSession();
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const args: Map<string, ESObject> = call.args as Map<string, ESObject>;
    if (call.method === 'configureImagePipeline') {
      this.configureImagePipeline(args, result);
      return;
    }
    if (call.method === 'getImageCapabilities') {
      this.getImageCapabilities(result);
      return;
    }
    if (call.method === 'getImageDiagnostics') {
      this.getImageDiagnostics(result);
      return;
    }
    if (call.method === 'decodeImage') {
      this.decodeImage(args, result);
      return;
    }
    if (call.method === 'decodeSdrTexture') {
      this.decodeSdrTexture(args, result);
      return;
    }
    if (call.method === 'decodeHdrImage') {
      this.decodeHdrImage(args, result);
      return;
    }
    if (call.method === 'cancelImageDecode') {
      this.cancelImageDecode(args, result);
      return;
    }
    if (call.method === 'disposeSdrTexture') {
      this.disposeSdrTexture(args, result);
      return;
    }
    if (call.method === 'disposeHdrImage') {
      this.disposeHdrImage(args, result);
      return;
    }
    if (call.method === 'createHdrImageTexture') {
      this.createHdrImageTexture(args, result);
      return;
    }
    if (call.method === 'resizeHdrImageTexture') {
      this.resizeHdrImageTexture(args, result);
      return;
    }
    if (call.method === 'releaseHdrImageTexture') {
      this.releaseHdrImageTexture(args, result);
      return;
    }
    if (call.method === 'create') {
      this.createPlayer(args, result);
      return;
    }
    if (call.method === 'dispose') {
      this.disposePlayer(args, result);
      return;
    }
    if (call.method === 'createTexture') {
      this.createTexture(args, result);
      return;
    }
    if (call.method === 'resizeTexture') {
      this.resizeTexture(args, result);
      return;
    }
    if (call.method === 'releaseTexture') {
      this.releaseTexture(args, result);
      return;
    }
    if (call.method === 'attachView') {
      this.attachView(args, result);
      return;
    }
    if (call.method === 'detachView') {
      this.detachView(args, result);
      return;
    }
    if (call.method === 'screenshot') {
      this.captureFrame(args, result);
      return;
    }
    if (call.method === 'setMediaMetadata') {
      this.setMediaMetadata(args, result);
      return;
    }
    if (call.method === 'setSystemMediaNavigation') {
      this.setSystemMediaNavigation(args, result);
      return;
    }
    if (call.method === 'open') {
      this.openPlayer(args, result);
      return;
    }
    if (call.method === 'registerSubtitleMemoryFont') {
      this.registerSubtitleMemoryFont(args, result);
      return;
    }
    if (call.method === 'getHdrCapabilities') {
      this.getHdrCapabilities(args, result);
      return;
    }
    if (this.isNativePlayerMethod(call.method)) {
      this.invokePlayer(call.method, args, result);
      return;
    }
    result.notImplemented();
  }

  private configureImagePipeline(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    const response = erikaImageNative.nativeConfigureImagePipeline(
      this.numberArg(args, 'maxEncodedBytes', 0),
      this.numberArg(args, 'maxSourcePixels', 0),
      this.numberArg(args, 'maxOutputPixels', 0),
      this.numberArg(args, 'maxPacketsBeforeFrame', 0),
      this.numberArg(args, 'decodeTimeoutMillis', 0),
      this.numberArg(args, 'maxQueuedDecodes', 0),
      this.numberArg(args, 'maxConcurrentDecodes', 0),
    );
    if (!response.ok) {
      result.error(
        'ERIKA_IMAGE_ERROR',
        response.error ?? 'Unable to configure the Erika image pipeline',
        { kind: response.kind ?? 9 },
      );
      return;
    }
    result.success(null);
  }

  private getImageCapabilities(result: MethodResult): void {
    // hdrSurfaceSupported asserts that the native Texture/OHNativeWindow path
    // exists. It deliberately does not promise display HDR: the render result
    // is the only source of hdrOutputConfirmed.
    result.success(erikaImageNative.nativeGetImageCapabilities());
  }

  private getImageDiagnostics(result: MethodResult): void {
    const diagnostics = erikaImageNative.nativeGetImageDiagnostics();
    let sdrTextureCount = 0;
    this.imageTextures.forEach((texture: ErikaImageTexture): void => {
      if (texture.presentation === 'sdr') {
        sdrTextureCount += 1;
      }
    });
    diagnostics.sdrTextureCount = sdrTextureCount;
    diagnostics.platformViewCount = 0;
    result.success(diagnostics);
  }

  private decodeImage(args: Map<string, ESObject>, result: MethodResult): void {
    this.decodeImageSurface(args, result, 0);
  }

  private decodeSdrTexture(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    this.decodeImageSurface(args, result, 1);
  }

  private decodeHdrImage(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    this.decodeImageSurface(args, result, 2);
  }

  // decodeMode: 0 = automatic from decoded metadata, 1 = forced SDR,
  // 2 = explicitly retained HDR surface. Every mode retains one native image
  // session because Flutter Texture presentation needs an OHNativeWindow; the
  // native bridge therefore admits one active static surface, including SDR
  // fallback. C++ owns decode cancellation and native handles; this layer owns
  // only Flutter textures.
  private decodeImageSurface(
    args: Map<string, ESObject>,
    result: MethodResult,
    decodeMode: number,
  ): void {
    const operationId = this.numberArg(args, 'operationId', 0);
    const pathValue = args.get('path');
    const path = typeof pathValue === 'string' ? pathValue : '';
    const width = Math.max(0, Math.trunc(this.numberArg(args, 'cacheWidth', 0)));
    const height = Math.max(0, Math.trunc(this.numberArg(args, 'cacheHeight', 0)));
    if (operationId <= 0 || path.length === 0 || width < 0 || height < 0) {
      result.error(
        'ERIKA_IMAGE_ERROR',
        'operationId, path, and cache dimensions are invalid',
        { kind: 4 },
      );
      return;
    }
    const nativePromise = erikaImageNative.nativeDecodeImageSurface(
      operationId,
      path,
      width,
      height,
    );
    nativePromise.then(
      (decoded: ErikaImageDecodedValue): void => {
        const imageId = Math.trunc(decoded.imageId);
        const metadata = decoded.metadata as ErikaImageMetadataValue;
        if (imageId <= 0 || metadata === undefined || metadata === null) {
          result.error(
            'ERIKA_IMAGE_ERROR',
            'HarmonyOS NEXT returned an invalid static image session',
            { kind: 9 },
          );
          return;
        }
        this.imageIds.add(imageId);
        const sourceIsHdr = metadata.sourceDynamicRange >= 2;
        const deliverHdr = decodeMode === 2 ||
          (decodeMode === 0 && sourceIsHdr);
        if (deliverHdr) {
          result.success(this.imagePayload(
            metadata,
            'hdr',
            imageId,
            0,
            width,
            height,
          ));
          return;
        }
        this.createImageTexture(
          imageId,
          Math.max(1, width),
          Math.max(1, height),
          1.0,
          false,
          'sdr',
        ).then(
          (attachment: ErikaImageTextureAttachment): void => {
            result.success(this.imagePayload(
              metadata,
              'sdr',
              0,
              attachment.texture.textureId,
              attachment.texture.width,
              attachment.texture.height,
            ));
          },
          (_error: ESObject): void => {
            result.error(
              'ERIKA_IMAGE_ERROR',
              'Unable to attach the HarmonyOS NEXT SDR image texture',
              { kind: 8 },
            );
          },
        );
      },
      (_error: ESObject): void => {
        result.error(
          'ERIKA_IMAGE_ERROR',
          'Unable to decode the HarmonyOS NEXT static image',
          { kind: 9 },
        );
      },
    );
  }

  private cancelImageDecode(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    const operationId = this.numberArg(args, 'operationId', 0);
    result.success(
      operationId > 0 &&
        erikaImageNative.nativeCancelImageDecode(operationId),
    );
  }

  private disposeSdrTexture(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    const textureId = this.numberArg(args, 'textureId', -1);
    const texture = this.imageTextures.get(textureId);
    if (!texture) {
      result.success(null);
      return;
    }
    this.disposeImage(texture.imageId, result);
  }

  private disposeHdrImage(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    this.disposeImage(this.numberArg(args, 'imageId', 0), result);
  }

  private disposeImage(imageId: number, result: MethodResult): void {
    if (imageId <= 0) {
      result.success(null);
      return;
    }
    const nativePromise = erikaImageNative.nativeDestroyHdrImage(
      imageId,
    );
    nativePromise.then(
      (response: ErikaImageNativeResponse): void => {
        if (!response.ok) {
          result.error(
            'ERIKA_IMAGE_ERROR',
            response.error ?? 'Unable to dispose the static image',
            { kind: response.kind ?? 8 },
          );
          return;
        }
        this.removeImageTextureForImage(imageId);
        this.imageIds.delete(imageId);
        result.success(null);
      },
      (_error: ESObject): void => {
        result.error(
          'ERIKA_IMAGE_ERROR',
          'Unable to dispose the HarmonyOS NEXT static image',
          { kind: 8 },
        );
      },
    );
  }

  private createHdrImageTexture(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    const imageId = this.numberArg(args, 'imageId', 0);
    if (imageId <= 0 || !this.imageIds.has(imageId)) {
      result.error('ERIKA_IMAGE_ERROR', 'Unknown HDR image session', { kind: 4 });
      return;
    }
    if (this.imageTextureByImageId.has(imageId)) {
      result.error(
        'ERIKA_IMAGE_ERROR',
        'HDR image is already attached to a Flutter texture',
        { kind: 10 },
      );
      return;
    }
    const width = Math.max(1, Math.trunc(this.numberArg(args, 'width', 1)));
    const height = Math.max(1, Math.trunc(this.numberArg(args, 'height', 1)));
    const scale = Math.max(0.1, this.numberArg(args, 'scale', 1.0));
    this.createImageTexture(
      imageId,
      width,
      height,
      scale,
      true,
      'hdr',
    ).then(
      (attachment: ErikaImageTextureAttachment): void => {
        result.success({
          textureId: attachment.texture.textureId,
          outputStatus: attachment.outputStatus,
        });
      },
      (_error: ESObject): void => {
        result.error(
          'ERIKA_IMAGE_ERROR',
          'Unable to attach the HarmonyOS NEXT HDR image texture',
          { kind: 8 },
        );
      },
    );
  }

  private resizeHdrImageTexture(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    const textureId = this.numberArg(args, 'textureId', -1);
    const imageId = this.numberArg(args, 'imageId', 0);
    const texture = this.imageTextures.get(textureId);
    if (!texture || texture.imageId !== imageId || texture.presentation !== 'hdr') {
      result.error('ERIKA_IMAGE_ERROR', 'Unknown HDR image texture', { kind: 4 });
      return;
    }
    texture.width = Math.max(1, Math.trunc(this.numberArg(args, 'width', texture.width)));
    texture.height = Math.max(1, Math.trunc(this.numberArg(args, 'height', texture.height)));
    texture.scale = Math.max(0.1, this.numberArg(args, 'scale', texture.scale));
    this.binding?.getTextureRegistry()?.setTextureBufferSize(
      textureId,
      texture.width,
      texture.height,
    );
    const nativePromise = erikaImageNative.nativeResizeHdrImageSurface(
      imageId,
      texture.surfaceGeneration,
      texture.width,
      texture.height,
      texture.scale,
    );
    nativePromise.then(
      (response: ErikaImageNativeResponse): void => {
        if (!response.ok) {
          this.destroyImageAfterSurfaceFailure(imageId).then((): void => {
            result.error(
              'ERIKA_IMAGE_ERROR',
              response.error ?? 'Unable to resize the HDR image texture',
              { kind: response.kind ?? 8 },
            );
          });
          return;
        }
        result.success({ outputStatus: response.value ?? {} });
      },
      (_error: ESObject): void => {
        this.destroyImageAfterSurfaceFailure(imageId).then((): void => {
          result.error(
            'ERIKA_IMAGE_ERROR',
            'Unable to resize the HarmonyOS NEXT HDR image texture',
            { kind: 8 },
          );
        });
      },
    );
  }

  private releaseHdrImageTexture(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    const imageId = this.numberArg(args, 'imageId', 0);
    const textureId = this.numberArg(args, 'textureId', -1);
    const texture = this.imageTextures.get(textureId);
    // The Dart widget can finish an old asynchronous attach after it has been
    // replaced. A stale release must never detach a newer image if Flutter
    // ever reuses a texture id.
    if (!texture || imageId <= 0 || texture.imageId !== imageId) {
      result.success(null);
      return;
    }
    const nativePromise = erikaImageNative.nativeDetachHdrImageSurface(
      texture.imageId,
      texture.surfaceGeneration,
    );
    nativePromise.then(
      (_response: ErikaImageNativeResponse): void => {
        this.removeImageTexture(texture);
        result.success(null);
      },
      (_error: ESObject): void => {
        // Destruction may have won the race. The Flutter texture still belongs
        // to this bridge and must be released exactly once.
        this.removeImageTexture(texture);
        result.success(null);
      },
    );
  }

  private async createImageTexture(
    imageId: number,
    width: number,
    height: number,
    scale: number,
    preferHdr: boolean,
    presentation: string,
  ): Promise<ErikaImageTextureAttachment> {
    const registry = this.binding?.getTextureRegistry();
    if (!registry) {
      throw new Error('TextureRegistry is unavailable');
    }
    const textureId = registry.getTextureId();
    const entry = registry.registerTexture(textureId);
    registry.setTextureBufferSize(textureId, width, height);
    const texture: ErikaImageTexture = {
      textureId: textureId,
      entry: entry,
      surfaceId: entry.getSurfaceId(),
      width: width,
      height: height,
      scale: scale,
      imageId: imageId,
      surfaceGeneration: this.nextImageSurfaceGeneration++,
      presentation: presentation,
    };
    try {
      const response = await erikaImageNative.nativeAttachHdrImageSurface(
        imageId,
        texture.surfaceId,
        texture.surfaceGeneration,
        width,
        height,
        scale,
        preferHdr,
      );
      if (!response.ok) {
        throw new Error(response.error ?? 'Unable to attach static image surface');
      }
      this.imageTextures.set(textureId, texture);
      this.imageTextureByImageId.set(imageId, textureId);
      return {
        texture: texture,
        outputStatus: response.value ?? {},
      };
    } catch (error) {
      registry.unregisterTexture(textureId);
      // Do not report an attach failure until the retained native session has
      // released its one static-surface slot; Dart can then immediately start
      // the explicit SDR fallback without racing the old image.
      await this.destroyImageAfterSurfaceFailure(imageId);
      throw error;
    }
  }

  private imagePayload(
    metadata: ErikaImageMetadataValue,
    presentation: string,
    imageId: number,
    textureId: number,
    width: number,
    height: number,
  ): ESObject {
    const payload: ESObject = {
      presentation: presentation,
      sourceWidth: metadata.width,
      sourceHeight: metadata.height,
      sourceDynamicRange: metadata.sourceDynamicRange,
    };
    if (presentation === 'hdr') {
      payload.imageId = imageId;
    } else {
      payload.textureId = textureId;
      payload.width = width;
      payload.height = height;
    }
    return payload;
  }

  private removeImageTextureForImage(imageId: number): void {
    const textureId = this.imageTextureByImageId.get(imageId);
    if (textureId === undefined) {
      return;
    }
    const texture = this.imageTextures.get(textureId);
    if (texture !== undefined) {
      this.removeImageTexture(texture);
    } else {
      this.imageTextureByImageId.delete(imageId);
    }
  }

  private removeImageTexture(texture: ErikaImageTexture): void {
    const textureId = texture.textureId;
    if (this.imageTextures.get(textureId) === texture) {
      this.imageTextures.delete(textureId);
    }
    if (this.imageTextureByImageId.get(texture.imageId) === textureId) {
      this.imageTextureByImageId.delete(texture.imageId);
    }
    this.binding?.getTextureRegistry()?.unregisterTexture(textureId);
  }

  private async destroyImageAfterSurfaceFailure(imageId: number): Promise<void> {
    try {
      await erikaImageNative.nativeDestroyHdrImage(imageId);
    } catch (_) {
      // Native teardown is still authoritative during an engine shutdown or a
      // concurrent caller disposal. Local texture/map cleanup is idempotent.
    }
    this.removeImageTextureForImage(imageId);
    this.imageIds.delete(imageId);
  }

  private destroyImageQuietly(imageId: number): void {
    if (imageId <= 0) {
      return;
    }
    this.imageIds.delete(imageId);
    const operation = erikaImageNative.nativeDestroyHdrImage(
      imageId,
    );
    operation.catch((): void => {});
  }

  private createPlayer(args: Map<string, ESObject>, result: MethodResult): void {
    const outputMode = this.numberArg(args, 'outputMode', 0);
    const headroom = this.numberArg(
      args,
      'edrHeadroom',
      outputMode === 2 || outputMode === 4 ? 4.0 : 1.0,
    );
    const upscaler = this.numberArg(args, 'upscaler', 0);
    const playerId = erikaNative.nativeCreate(outputMode, headroom, upscaler) as number;
    if (playerId <= 0) {
      result.error(
        'ERIKA_ERROR',
        'Erika HarmonyOS NEXT presenter creation failed: ' +
          (erikaNative.nativeLastError() as string),
        null,
      );
      return;
    }
    this.players.add(playerId);
    this.outputModes.set(
      playerId,
      outputMode === 0 ? 0 : outputMode === 3 ? 3 : 4,
    );
    this.mediaStates.set(playerId, {
      playbackState: 0,
      positionMicros: 0,
      durationMicros: 0,
      playbackRate: 1.0,
    });
    this.mediaNavigation.set(playerId, {
      previousEnabled: false,
      nextEnabled: false,
    });
    result.success(playerId);
  }

  private disposePlayer(args: Map<string, ESObject>, result: MethodResult): void {
    const playerId = this.numberArg(args, 'playerId', 0);
    this.textures.forEach((texture: ErikaTexture): void => {
      if (texture.playerId === playerId) {
        erikaNative.nativeDetachSurface(playerId);
        texture.playerId = 0;
      }
    });
    if (this.players.delete(playerId)) {
      erikaNative.nativeDestroy(playerId);
    }
    this.mediaMetadata.delete(playerId);
    this.mediaStates.delete(playerId);
    this.mediaNavigation.delete(playerId);
    this.outputModes.delete(playerId);
    this.lastOutputStatus.delete(playerId);
    if (this.currentPlayerId === playerId) {
      this.currentPlayerId = 0;
      this.deactivateAVSession();
    }
    result.success(null);
  }

  private openPlayer(args: Map<string, ESObject>, result: MethodResult): void {
    const metadataValue: ESObject = args.get('metadata');
    let metadata: ErikaMediaMetadata | null = null;
    if (metadataValue !== undefined && metadataValue !== null) {
      metadata = this.parseMediaMetadata(metadataValue);
      if (metadata === null) {
        result.error('INVALID_ARGUMENT', 'metadata.title is required', null);
        return;
      }
    }
    const playerId = this.numberArg(args, 'playerId', 0);
    const nativeArgs: Map<string, ESObject> = new Map<string, ESObject>(args);
    nativeArgs.delete('metadata');
    if (!this.invokePlayerNative('open', nativeArgs, result)) {
      return;
    }
    const state = this.mediaStates.get(playerId);
    if (state !== undefined) {
      state.playbackState = 0;
      state.positionMicros = 0;
      state.durationMicros = 0;
    }
    if (metadata !== null) {
      this.mediaMetadata.set(playerId, metadata);
      if (this.currentPlayerId === playerId) {
        this.publishMediaMetadata(playerId, metadata);
      }
    } else {
      this.mediaMetadata.delete(playerId);
      if (this.currentPlayerId === playerId) {
        this.destroyAVSession();
      }
    }
    if (this.currentPlayerId === playerId) {
      this.publishPlaybackState(playerId);
    }
  }

  private setMediaMetadata(args: Map<string, ESObject>, result: MethodResult): void {
    const playerId = this.numberArg(args, 'playerId', 0);
    if (!this.players.has(playerId)) {
      result.error('ERIKA_ERROR', 'Unknown Erika player ' + playerId, null);
      return;
    }
    const metadata = this.parseMediaMetadata(args.get('metadata'));
    if (metadata === null) {
      result.error('INVALID_ARGUMENT', 'metadata.title is required', null);
      return;
    }
    this.mediaMetadata.set(playerId, metadata);
    result.success(null);
    if (this.currentPlayerId === playerId) {
      this.publishMediaMetadata(playerId, metadata);
    }
  }

  private setSystemMediaNavigation(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    const playerId = this.numberArg(args, 'playerId', 0);
    if (!this.players.has(playerId)) {
      result.error('ERIKA_ERROR', 'Unknown Erika player ' + playerId, null);
      return;
    }
    this.mediaNavigation.set(playerId, {
      previousEnabled: args.get('previousEnabled') === true,
      nextEnabled: args.get('nextEnabled') === true,
    });
    result.success(null);
    const metadata = this.mediaMetadata.get(playerId);
    if (metadata !== undefined && this.currentPlayerId === playerId) {
      this.publishMediaMetadata(playerId, metadata);
    }
  }

  private createTexture(args: Map<string, ESObject>, result: MethodResult): void {
    const registry = this.binding?.getTextureRegistry();
    if (!registry) {
      result.error('NO_TEXTURE_REGISTRY', 'TextureRegistry is unavailable', null);
      return;
    }
    const width = Math.max(1, Math.trunc(this.numberArg(args, 'width', 1)));
    const height = Math.max(1, Math.trunc(this.numberArg(args, 'height', 1)));
    const scale = Math.max(0.1, this.numberArg(args, 'scale', 1.0));
    const textureId = registry.getTextureId();
    const entry = registry.registerTexture(textureId);
    registry.setTextureBufferSize(textureId, width, height);
    this.textures.set(textureId, {
      entry: entry,
      surfaceId: entry.getSurfaceId(),
      width: width,
      height: height,
      scale: scale,
      playerId: 0,
    });
    result.success(textureId);
  }

  private resizeTexture(args: Map<string, ESObject>, result: MethodResult): void {
    const textureId = this.numberArg(args, 'textureId', -1);
    const texture = this.textures.get(textureId);
    if (!texture) {
      result.error('ERIKA_ERROR', 'Unknown Erika texture ' + textureId, null);
      return;
    }
    texture.width = Math.max(1, Math.trunc(this.numberArg(args, 'width', texture.width)));
    texture.height = Math.max(1, Math.trunc(this.numberArg(args, 'height', texture.height)));
    texture.scale = Math.max(0.1, this.numberArg(args, 'scale', texture.scale));
    this.binding?.getTextureRegistry()?.setTextureBufferSize(
      textureId,
      texture.width,
      texture.height,
    );
    if (texture.playerId > 0) {
      const status = erikaNative.nativeResizeSurface(
        texture.playerId,
        texture.width,
        texture.height,
        texture.scale,
      ) as number;
      if (!this.completeStatus(status, result, 'resize HarmonyOS NEXT surface')) {
        return;
      }
    }
    result.success(null);
  }

  private releaseTexture(args: Map<string, ESObject>, result: MethodResult): void {
    const textureId = this.numberArg(args, 'textureId', -1);
    const texture = this.textures.get(textureId);
    if (texture) {
      if (texture.playerId > 0) {
        erikaNative.nativeDetachSurface(texture.playerId);
      }
      this.binding?.getTextureRegistry()?.unregisterTexture(textureId);
      this.textures.delete(textureId);
    }
    result.success(null);
  }

  private attachView(args: Map<string, ESObject>, result: MethodResult): void {
    const playerId = this.numberArg(args, 'playerId', 0);
    const textureId = this.numberArg(args, 'viewId', -1);
    const texture = this.textures.get(textureId);
    if (!this.players.has(playerId) || !texture) {
      result.error('ERIKA_ERROR', 'Unknown Erika player or texture', null);
      return;
    }
    if (texture.playerId > 0 && texture.playerId !== playerId) {
      erikaNative.nativeDetachSurface(texture.playerId);
    }
    const status = erikaNative.nativeAttachSurface(
      playerId,
      texture.surfaceId,
      texture.width,
      texture.height,
      texture.scale,
    ) as number;
    if (!this.completeStatus(status, result, 'attach HarmonyOS NEXT surface')) {
      return;
    }
    texture.playerId = playerId;
    result.success(null);
    this.drainEvents(playerId);
    this.emitOutputStatusIfChanged(playerId);
  }

  private detachView(args: Map<string, ESObject>, result: MethodResult): void {
    const playerId = this.numberArg(args, 'playerId', 0);
    const textureId = this.numberArg(args, 'viewId', -1);
    const texture = this.textures.get(textureId);
    if (!texture || texture.playerId !== playerId) {
      result.success(null);
      return;
    }
    const status = erikaNative.nativeDetachSurface(playerId) as number;
    texture.playerId = 0;
    if (!this.completeStatus(status, result, 'detach HarmonyOS NEXT surface')) {
      return;
    }
    result.success(null);
    this.drainEvents(playerId);
  }

  private captureFrame(args: Map<string, ESObject>, result: MethodResult): void {
    const playerId = this.numberArg(args, 'playerId', 0);
    if (!this.players.has(playerId)) {
      result.error('ERIKA_ERROR', 'Unknown Erika player ' + playerId, null);
      return;
    }

    let fallbackWidth = 0;
    let fallbackHeight = 0;
    this.textures.forEach((texture: ErikaTexture): void => {
      if (texture.playerId === playerId) {
        fallbackWidth = texture.width;
        fallbackHeight = texture.height;
      }
    });
    const width = Math.trunc(this.numberArg(args, 'width', fallbackWidth));
    const height = Math.trunc(this.numberArg(args, 'height', fallbackHeight));
    if (width <= 0 || height <= 0) {
      result.error(
        'ERIKA_ERROR',
        'Screenshot width and height are required before a HarmonyOS NEXT surface is attached',
        null,
      );
      return;
    }

    const bytes = erikaNative.nativeCaptureFrame(
      playerId,
      width,
      height,
    ) as Uint8Array | null;
    result.success(bytes);
  }

  private invokePlayer(
    method: string,
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    if (!this.invokePlayerNative(method, args, result)) {
      return;
    }
    const playerId = this.numberArg(args, 'playerId', 0);
    if (method === 'play') {
      this.currentPlayerId = playerId;
      const metadata = this.mediaMetadata.get(playerId);
      if (metadata !== undefined) {
        this.publishMediaMetadata(playerId, metadata);
      }
      this.publishPlaybackState(playerId);
    } else if (method === 'setPlaybackRate') {
      const state = this.mediaStates.get(playerId);
      if (state !== undefined) {
        state.playbackRate = this.numberArg(args, 'rate', 1.0);
      }
      this.publishPlaybackState(playerId);
    }
  }

  private invokePlayerNative(
    method: string,
    args: Map<string, ESObject>,
    result: MethodResult,
  ): boolean {
    const playerId = this.numberArg(args, 'playerId', 0);
    if (!this.players.has(playerId)) {
      result.error('ERIKA_ERROR', 'Unknown Erika player ' + playerId, null);
      return false;
    }
    const argumentsJson = JSON.stringify(this.mapToObject(args));
    const raw = erikaNative.nativeInvoke(playerId, method, argumentsJson) as string;
    const response = JSON.parse(raw) as NativeResponse;
    if (!response.ok) {
      result.error(
        'ERIKA_ERROR',
        response.error ?? ('Erika native method failed with status ' + response.status),
        response,
      );
      return false;
    }
    if (method === 'getOutputStatus' && response.value !== undefined) {
      response.value.requestedMode = this.outputModes.get(playerId) ?? 0;
    }
    result.success(response.value ?? null);
    this.drainEvents(playerId);
    return true;
  }

  private getHdrCapabilities(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    const playerId = this.numberArg(args, 'playerId', 0);
    if (!this.players.has(playerId)) {
      result.error('ERIKA_ERROR', 'Unknown Erika player ' + playerId, null);
      return;
    }
    const raw = erikaNative.nativeGetHdrCapabilitiesJson(playerId) as string;
    result.success(JSON.parse(raw) as ESObject);
  }

  private parseMediaMetadata(value: ESObject): ErikaMediaMetadata | null {
    if (!(value instanceof Map)) {
      return null;
    }
    const metadata: Map<string, ESObject> = value as Map<string, ESObject>;
    const titleValue: ESObject = metadata.get('title');
    if (typeof titleValue !== 'string' || titleValue.length === 0) {
      return null;
    }
    const parsed: ErikaMediaMetadata = { title: titleValue };
    const artist: ESObject = metadata.get('artist');
    const album: ESObject = metadata.get('album');
    const artwork: ESObject = metadata.get('artwork');
    if (typeof artist === 'string') {
      parsed.artist = artist;
    }
    if (typeof album === 'string') {
      parsed.album = album;
    }
    if (artwork instanceof Uint8Array) {
      parsed.artwork = artwork;
    }
    return parsed;
  }

  private async ensureAVSession(): Promise<avSession.AVSession | null> {
    if (this.currentSession !== null) {
      return this.currentSession;
    }
    if (this.sessionPromise !== null) {
      return this.sessionPromise;
    }
    const context = this.ability?.context as common.UIAbilityContext | undefined;
    if (context === undefined) {
      return null;
    }
    const generation = this.sessionGeneration;
    const promise = this.createAVSession(context, generation);
    this.sessionPromise = promise;
    const session = await promise;
    if (this.sessionPromise === promise) {
      this.sessionPromise = null;
    }
    return session;
  }

  private async createAVSession(
    context: common.UIAbilityContext,
    generation: number,
  ): Promise<avSession.AVSession | null> {
    let session: avSession.AVSession | null = null;
    try {
      session = await avSession.createAVSession(context, 'ErikaVideoPlayer', 'video');
      if (generation !== this.sessionGeneration || this.ability?.context !== context) {
        await session.destroy().catch((): void => {});
        return null;
      }
      this.registerAVSessionCommands(session);
      await session.activate();
      if (generation !== this.sessionGeneration || this.ability?.context !== context) {
        await session.destroy().catch((): void => {});
        return null;
      }
      this.currentSession = session;
      return session;
    } catch (_) {
      await session?.destroy().catch((): void => {});
      return null;
    }
  }

  private registerAVSessionCommands(session: avSession.AVSession): void {
    session.on('play', (): void => this.invokeFromAVSession('play'));
    session.on('pause', (): void => this.invokeFromAVSession('pause'));
    session.on('stop', (): void => this.invokeFromAVSession('stop'));
    session.on('seek', (time: number): void => {
      this.invokeFromAVSession('seek', new Map<string, ESObject>([
        ['positionMicros', time * 1000],
      ]));
    });
    session.on('playPrevious', (): void => this.emitSystemMediaNavigation('previous'));
    session.on('playNext', (): void => this.emitSystemMediaNavigation('next'));
  }

  private emitSystemMediaNavigation(navigation: string): void {
    const playerId = this.currentPlayerId;
    const capabilities = this.mediaNavigation.get(playerId);
    const enabled = navigation === 'previous'
      ? capabilities?.previousEnabled === true
      : capabilities?.nextEnabled === true;
    if (!this.players.has(playerId) || !enabled) {
      return;
    }
    this.eventSink?.success({
      playerId: playerId,
      kind: SYSTEM_MEDIA_NAVIGATION_EVENT_KIND,
      navigation: navigation,
    });
  }

  private invokeFromAVSession(method: string, extra?: Map<string, ESObject>): void {
    const playerId = this.currentPlayerId;
    if (!this.players.has(playerId)) {
      return;
    }
    const args: Map<string, ESObject> =
      extra ?? new Map<string, ESObject>();
    args.set('playerId', playerId);
    const raw = erikaNative.nativeInvoke(
      playerId,
      method,
      JSON.stringify(this.mapToObject(args)),
    ) as string;
    const response = JSON.parse(raw) as NativeResponse;
    if (response.ok) {
      this.drainEvents(playerId);
    }
  }

  private async publishMediaMetadata(
    playerId: number,
    metadata: ErikaMediaMetadata,
  ): Promise<void> {
    const session = await this.ensureAVSession();
    if (session === null || this.currentPlayerId !== playerId ||
      this.mediaMetadata.get(playerId) !== metadata) {
      return;
    }
    const avMetadata: avSession.AVMetadata = {
      assetId: 'erika-' + playerId,
      title: metadata.title,
    };
    const capabilities = this.mediaNavigation.get(playerId);
    if (capabilities?.previousEnabled === true) {
      avMetadata.previousAssetId = 'erika-previous-' + playerId;
    }
    if (capabilities?.nextEnabled === true) {
      avMetadata.nextAssetId = 'erika-next-' + playerId;
    }
    if (metadata.artist !== undefined) {
      avMetadata.artist = metadata.artist;
    }
    if (metadata.album !== undefined) {
      avMetadata.album = metadata.album;
    }
    let mediaImage: image.PixelMap | null = null;
    if (metadata.artwork !== undefined) {
      let source: image.ImageSource | null = null;
      try {
        const bytes = metadata.artwork;
        const artwork = new Uint8Array(bytes.byteLength);
        artwork.set(bytes);
        source = image.createImageSource(artwork.buffer as ArrayBuffer);
        mediaImage = await source.createPixelMap();
        avMetadata.mediaImage = mediaImage;
      } catch (_) {
      } finally {
        await source?.release().catch((): void => {});
      }
    }
    const state = this.mediaStates.get(playerId);
    if (state !== undefined && state.durationMicros > 0) {
      avMetadata.duration = state.durationMicros / 1000.0;
    }
    if (this.currentPlayerId !== playerId || this.mediaMetadata.get(playerId) !== metadata) {
      await mediaImage?.release().catch((): void => {});
      return;
    }
    await session.setAVMetadata(avMetadata).catch((): void => {});
    await mediaImage?.release().catch((): void => {});
  }

  private async publishPlaybackState(playerId: number): Promise<void> {
    const mediaState = this.mediaStates.get(playerId);
    if (mediaState === undefined || this.currentPlayerId !== playerId) {
      return;
    }
    const session = await this.ensureAVSession();
    if (session === null || this.currentPlayerId !== playerId) {
      return;
    }
    await session.activate().catch((): void => {});
    await session.setAVPlaybackState({
      state: this.avPlaybackState(mediaState.playbackState),
      speed: mediaState.playbackState === PLAYING_STATE ? mediaState.playbackRate : 0,
      position: {
        elapsedTime: mediaState.positionMicros / 1000.0,
        updateTime: Date.now(),
      },
      duration: mediaState.durationMicros / 1000.0,
    }).catch((): void => {});
    if (mediaState.playbackState === CLOSED_STATE || mediaState.playbackState === ERROR_STATE) {
      this.deactivateAVSession();
    }
  }

  private avPlaybackState(state: number): avSession.PlaybackState {
    if (state === PLAYING_STATE) {
      return avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    }
    if (state === PAUSED_STATE) {
      return avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    }
    if (state === STOPPED_STATE) {
      return avSession.PlaybackState.PLAYBACK_STATE_STOP;
    }
    if (state === CLOSED_STATE) {
      return avSession.PlaybackState.PLAYBACK_STATE_RELEASED;
    }
    if (state === ERROR_STATE) {
      return avSession.PlaybackState.PLAYBACK_STATE_ERROR;
    }
    return avSession.PlaybackState.PLAYBACK_STATE_PREPARE;
  }

  private deactivateAVSession(): void {
    this.sessionGeneration += 1;
    this.sessionPromise = null;
    this.currentSession?.deactivate().catch((): void => {});
  }

  private destroyAVSession(): void {
    const session = this.currentSession;
    this.sessionGeneration += 1;
    this.currentSession = null;
    this.sessionPromise = null;
    session?.destroy().catch((): void => {});
  }

  private registerSubtitleMemoryFont(
    args: Map<string, ESObject>,
    result: MethodResult,
  ): void {
    const playerId = this.numberArg(args, 'playerId', 0);
    if (!this.players.has(playerId)) {
      result.error('ERIKA_ERROR', 'Unknown Erika player ' + playerId, null);
      return;
    }
    const data = args.get('data') as Uint8Array;
    const response = erikaNative.nativeRegisterSubtitleMemoryFont(
      playerId,
      data,
    ) as Array<number>;
    const status = response[0] ?? 1;
    if (!this.completeStatus(status, result, 'register subtitle memory font')) {
      return;
    }
    result.success(response[1] ?? 0);
  }

  private startEventLoop(): void {
    if (this.eventTimer >= 0) {
      return;
    }
    this.eventTimer = setTimeout((): void => {
      this.eventTimer = -1;
      this.players.forEach((playerId: number): void => {
        this.drainEvents(playerId);
        this.emitOutputStatusIfChanged(playerId);
      });
      this.startEventLoop();
    }, EVENT_POLL_INTERVAL_MS);
  }

  private stopEventLoop(): void {
    if (this.eventTimer >= 0) {
      clearTimeout(this.eventTimer);
      this.eventTimer = -1;
    }
  }

  private emitOutputStatusIfChanged(playerId: number): void {
    const sink = this.eventSink;
    if (!sink) {
      return;
    }
    const raw = erikaNative.nativeInvoke(playerId, 'getOutputStatus', '{}') as string;
    const response = JSON.parse(raw) as NativeResponse;
    if (!response.ok || response.value === undefined) {
      return;
    }
    response.value.requestedMode = this.outputModes.get(playerId) ?? 0;
    const serialized = JSON.stringify(response.value);
    if (this.lastOutputStatus.get(playerId) === serialized) {
      return;
    }
    this.lastOutputStatus.set(playerId, serialized);
    sink.success({
      playerId: playerId,
      kind: OUTPUT_STATUS_CHANGED_EVENT_KIND,
      outputStatus: response.value,
    });
  }

  private drainAllEvents(): void {
    this.players.forEach((playerId: number): void => this.drainEvents(playerId));
  }

  private drainEvents(playerId: number): void {
    const sink = this.eventSink;
    if (!sink) {
      return;
    }
    for (let index = 0; index < 64; index += 1) {
      const raw = erikaNative.nativePollEvent(playerId) as string | null;
      if (raw === null) {
        return;
      }
      const response = JSON.parse(raw) as NativeResponse;
      if (!response.ok || response.value === undefined) {
        return;
      }
      const event: ESObject = response.value;
      event.playerId = playerId;
      this.observeMediaEvent(playerId, event);
      sink.success(event);
    }
  }

  private observeMediaEvent(playerId: number, event: ESObject): void {
    const mediaState = this.mediaStates.get(playerId);
    if (mediaState === undefined) {
      return;
    }
    const kind = typeof event.kind === 'number' ? event.kind as number : 0;
    if (kind === STATE_CHANGED_EVENT_KIND) {
      mediaState.playbackState = typeof event.state === 'number'
        ? event.state as number
        : mediaState.playbackState;
    }
    if (kind === POSITION_CHANGED_EVENT_KIND && typeof event.positionMicros === 'number') {
      mediaState.positionMicros = Math.max(0, event.positionMicros as number);
    }
    if ((kind === DURATION_CHANGED_EVENT_KIND || kind === STATE_CHANGED_EVENT_KIND) &&
      typeof event.durationMicros === 'number') {
      mediaState.durationMicros = Math.max(0, event.durationMicros as number);
    }
    if (this.currentPlayerId !== playerId) {
      return;
    }
    if (kind === DURATION_CHANGED_EVENT_KIND) {
      const metadata = this.mediaMetadata.get(playerId);
      if (metadata !== undefined) {
        this.publishMediaMetadata(playerId, metadata);
      }
    }
    if (kind === STATE_CHANGED_EVENT_KIND || kind === DURATION_CHANGED_EVENT_KIND ||
      kind === POSITION_CHANGED_EVENT_KIND) {
      this.publishPlaybackState(playerId);
    }
  }

  private completeStatus(status: number, result: MethodResult, operation: string): boolean {
    if (status === 0) {
      return true;
    }
    const nativeError = erikaNative.nativeLastError() as string;
    result.error(
      'ERIKA_ERROR',
      operation + ' failed' + (nativeError.length > 0 ? ': ' + nativeError : ''),
      status,
    );
    return false;
  }

  private numberArg(
    args: Map<string, ESObject>,
    name: string,
    fallback: number,
  ): number {
    const value: ESObject = args.get(name);
    return typeof value === 'number' ? value as number : fallback;
  }

  private mapToObject(args: Map<string, ESObject>): ESObject {
    const object: ESObject = {};
    args.forEach((value: ESObject, key: string): void => {
      object[key] = this.jsonValue(value);
    });
    return object;
  }

  private jsonValue(value: ESObject): ESObject {
    if (value instanceof Map) {
      return this.mapToObject(value as Map<string, ESObject>);
    }
    if (Array.isArray(value)) {
      return (value as Array<ESObject>).map(
        (child: ESObject): ESObject => this.jsonValue(child),
      );
    }
    return value;
  }

  private isNativePlayerMethod(method: string): boolean {
    return [
      'open', 'play', 'pause', 'stop', 'close', 'seek',
      'setPlaybackRate', 'setVolume', 'setUpscaler', 'setSubtitleScale',
      'selectSubtitleMemoryFonts', 'clearSubtitleMemoryFonts',
      'getSubtitleMemoryFontStatus',
      'getUpscalerStatus', 'getOutputStatus', 'getPresenterStats',
      'getResourceStatus',
      'addExternalSubtitle', 'removeSubtitleTrack',
      'loadDanmakuFile', 'loadDanmakuJson',
      'addDanmakuTrackFile', 'addDanmakuTrackJson',
      'removeDanmakuTrack', 'setDanmakuTrackEnabled',
      'setDanmakuTrackOffset', 'setDanmakuGlobalOffset',
      'danmakuTracks', 'clearDanmaku', 'setDanmakuEnabled',
      'setDanmakuConfig', 'selectAudioTrack', 'selectSubtitleTrack', 'tracks',
    ].includes(method);
  }
}
