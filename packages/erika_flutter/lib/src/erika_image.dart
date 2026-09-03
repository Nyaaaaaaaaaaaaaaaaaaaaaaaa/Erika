import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const MethodChannel _imageChannel = MethodChannel('erika_flutter/player');

enum ErikaImageErrorReason {
  unsupportedPlatform,
  unsupportedFormat,
  corrupt,
  source,
  network,
  cancelled,
  resourceLimit,
  busy,
  renderer,
  internal,
}

final class ErikaImageException implements Exception {
  const ErikaImageException(this.reason, this.message);

  final ErikaImageErrorReason reason;
  final String message;

  @override
  String toString() => 'ErikaImageException($reason, $message)';
}

enum ErikaImageDecodeBackend { unknown, software, hardware }

enum ErikaImagePresentation { sdr, hdr }

/// Application-owned limits for static-image work.
///
/// Erika enforces these limits but does not choose product policy for the app.
/// The defaults may be replaced before decoding starts with
/// [ErikaImagePipeline.configure].
final class ErikaImagePolicy {
  const ErikaImagePolicy({
    this.maxEncodedBytes = 128 * 1024 * 1024,
    this.maxSourcePixels = 32 * 1024 * 1024,
    this.maxOutputPixels = 32 * 1024 * 1024,
    this.maxPacketsBeforeFrame = 256,
    this.decodeTimeout = const Duration(seconds: 15),
    this.maxQueuedDecodes = 8,
    this.maxConcurrentDecodes = 1,
    this.maxIdleTextureBytes = 32 * 1024 * 1024,
    this.trimIdleTexturesOnBackground = true,
    this.decodeDimensionBuckets = const <int>[
      256,
      384,
      512,
      768,
      1024,
      1536,
      2048,
      3072,
      4096,
      6144,
      8192,
    ],
  }) : assert(maxEncodedBytes > 0 && maxEncodedBytes <= 128 * 1024 * 1024),
       assert(maxSourcePixels > 0 && maxSourcePixels <= 32 * 1024 * 1024),
       assert(maxOutputPixels > 0 && maxOutputPixels <= 32 * 1024 * 1024),
       assert(maxPacketsBeforeFrame > 0 && maxPacketsBeforeFrame <= 4096),
       assert(maxQueuedDecodes > 0 && maxQueuedDecodes <= 64),
       assert(maxConcurrentDecodes > 0 && maxConcurrentDecodes <= 4),
       assert(maxIdleTextureBytes >= 0);

  final int maxEncodedBytes;
  final int maxSourcePixels;
  final int maxOutputPixels;
  final int maxPacketsBeforeFrame;
  final Duration decodeTimeout;
  final int maxQueuedDecodes;
  final int maxConcurrentDecodes;
  final int maxIdleTextureBytes;
  final bool trimIdleTexturesOnBackground;

  /// Ascending physical-pixel sizes used to avoid a decode for every small
  /// layout change. An empty list uses the exact requested size.
  final List<int> decodeDimensionBuckets;

  Map<String, Object> _toPlatformMap() => <String, Object>{
    'maxEncodedBytes': maxEncodedBytes,
    'maxSourcePixels': maxSourcePixels,
    'maxOutputPixels': maxOutputPixels,
    'maxPacketsBeforeFrame': maxPacketsBeforeFrame,
    'decodeTimeoutMillis': decodeTimeout.inMilliseconds,
    'maxQueuedDecodes': maxQueuedDecodes,
    'maxConcurrentDecodes': maxConcurrentDecodes,
  };
}

final class ErikaImageCapabilities {
  const ErikaImageCapabilities({
    required this.sdrDecodeSupported,
    required this.hdrSurfaceSupported,
    required this.activeBackend,
    required this.maxEncodedBytes,
    required this.maxSourcePixels,
    required this.maxOutputPixels,
    required this.maxConcurrentDecodes,
  });

  const ErikaImageCapabilities.unsupported()
    : sdrDecodeSupported = false,
      hdrSurfaceSupported = false,
      activeBackend = ErikaImageDecodeBackend.unknown,
      maxEncodedBytes = 0,
      maxSourcePixels = 0,
      maxOutputPixels = 0,
      maxConcurrentDecodes = 0;

  final bool sdrDecodeSupported;
  final bool hdrSurfaceSupported;
  final ErikaImageDecodeBackend activeBackend;
  final int maxEncodedBytes;
  final int maxSourcePixels;
  final int maxOutputPixels;
  final int maxConcurrentDecodes;
}

final class ErikaImageDiagnostics {
  const ErikaImageDiagnostics({
    required this.queued,
    required this.inflight,
    required this.decodeCount,
    required this.singleFlightHits,
    required this.queuedCancelled,
    required this.nativeHandleCount,
    required this.sdrTextureCount,
    required this.idleSdrTextureBytes,
    required this.playerCount,
    required this.platformViewCount,
  });

  final int queued;
  final int inflight;
  final int decodeCount;
  final int singleFlightHits;
  final int queuedCancelled;
  final int nativeHandleCount;
  final int sdrTextureCount;
  final int idleSdrTextureBytes;
  final int playerCount;
  final int platformViewCount;
}

abstract final class ErikaImagePipeline {
  static ErikaImagePolicy _policy = const ErikaImagePolicy();
  static Future<ErikaImageCapabilities>? _capabilities;

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static ErikaImagePolicy get policy => _policy;

  /// Configures native scheduling and decode limits, and Dart texture caching.
  /// Call this before constructing an [ErikaImage].
  static Future<void> configure(ErikaImagePolicy policy) async {
    _validatePolicy(policy);
    if (isSupported) {
      try {
        await _imageChannel.invokeMethod<void>(
          'configureImagePipeline',
          policy._toPlatformMap(),
        );
      } on PlatformException catch (error) {
        throw ErikaImageException(
          _errorReason(_platformImageErrorKind(error)),
          error.message ?? 'Unable to configure the Erika image pipeline',
        );
      }
    }
    _policy = policy;
    _capabilities = null;
    _ErikaSdrCoordinator.instance.configure(policy);
  }

  static Future<ErikaImageCapabilities> capabilities() {
    return _capabilities ??= _readCapabilities();
  }

  static Future<ErikaImageCapabilities> _readCapabilities() async {
    if (!isSupported) return const ErikaImageCapabilities.unsupported();
    final value = await _imageChannel.invokeMapMethod<String, Object?>(
      'getImageCapabilities',
    );
    if (value == null) return const ErikaImageCapabilities.unsupported();
    return ErikaImageCapabilities(
      sdrDecodeSupported: value['sdrDecodeSupported'] == true,
      hdrSurfaceSupported: value['hdrSurfaceSupported'] == true,
      activeBackend: _decodeBackend(value['activeBackend']),
      maxEncodedBytes: _integer(value['maxEncodedBytes']),
      maxSourcePixels: _integer(value['maxSourcePixels']),
      maxOutputPixels: _integer(value['maxOutputPixels']),
      maxConcurrentDecodes: _integer(value['maxConcurrentDecodes']),
    );
  }

  static Future<ErikaImageDiagnostics> diagnostics() async {
    if (!isSupported) {
      return const ErikaImageDiagnostics(
        queued: 0,
        inflight: 0,
        decodeCount: 0,
        singleFlightHits: 0,
        queuedCancelled: 0,
        nativeHandleCount: 0,
        sdrTextureCount: 0,
        idleSdrTextureBytes: 0,
        playerCount: 0,
        platformViewCount: 0,
      );
    }
    final value = await _imageChannel.invokeMapMethod<String, Object?>(
      'getImageDiagnostics',
    );
    return ErikaImageDiagnostics(
      queued: _integer(value?['queued']),
      inflight: _integer(value?['inflight']),
      decodeCount: _integer(value?['decodeCount']),
      singleFlightHits: _ErikaSdrCoordinator.instance.singleFlightHits,
      queuedCancelled: _integer(value?['queuedCancelled']),
      nativeHandleCount: _integer(value?['nativeHandleCount']),
      sdrTextureCount: _integer(value?['sdrTextureCount']),
      idleSdrTextureBytes: _ErikaSdrCoordinator.instance.idleTextureBytes,
      playerCount: _integer(value?['playerCount']),
      platformViewCount: _integer(value?['platformViewCount']),
    );
  }

  static void trimCache() {
    _ErikaSdrCoordinator.instance.trimIdleTextures();
  }

  static void _validatePolicy(ErikaImagePolicy policy) {
    if (policy.decodeTimeout <= Duration.zero ||
        policy.decodeTimeout > const Duration(seconds: 120)) {
      throw ArgumentError.value(
        policy.decodeTimeout,
        'decodeTimeout',
        'must be between zero and 120 seconds',
      );
    }
    if (policy.decodeDimensionBuckets.any((value) => value <= 0)) {
      throw ArgumentError.value(
        policy.decodeDimensionBuckets,
        'decodeDimensionBuckets',
        'values must be positive',
      );
    }
    for (var index = 1; index < policy.decodeDimensionBuckets.length; index++) {
      if (policy.decodeDimensionBuckets[index] <=
          policy.decodeDimensionBuckets[index - 1]) {
        throw ArgumentError.value(
          policy.decodeDimensionBuckets,
          'decodeDimensionBuckets',
          'values must be strictly increasing',
        );
      }
    }
  }
}

typedef ErikaImageErrorBuilder =
    Widget Function(BuildContext context, Object error, StackTrace? stackTrace);

/// Displays a cached local image with automatic SDR/HDR selection.
///
/// The file is decoded to the physical layout size. If the decoded metadata is
/// HDR and the device exposes an HDR surface, Erika presents HDR; otherwise it
/// produces an SDR texture. Callers never own native handles or textures.
final class ErikaImage extends StatefulWidget {
  const ErikaImage.file(
    this.path, {
    super.key,
    this.cacheKey,
    this.fit = BoxFit.contain,
    this.filterQuality = FilterQuality.low,
    this.maxDecodeExtent,
    this.placeholder = const SizedBox.shrink(),
    this.errorBuilder,
    this.onReady,
    this.onPresentationChanged,
  }) : assert(maxDecodeExtent == null || maxDecodeExtent > 0);

  final String path;
  final String? cacheKey;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final int? maxDecodeExtent;
  final Widget placeholder;
  final ErikaImageErrorBuilder? errorBuilder;
  final VoidCallback? onReady;
  final ValueChanged<ErikaImagePresentation>? onPresentationChanged;

  @override
  State<ErikaImage> createState() => _ErikaImageState();
}

final class _ErikaImageState extends State<ErikaImage> {
  _ErikaImageLease? _lease;
  _ErikaDecodedImage? _image;
  Object? _error;
  StackTrace? _stackTrace;
  int _requestedWidth = -1;
  int _requestedHeight = -1;
  int _generation = 0;
  bool _decodeScheduled = false;
  bool _ready = false;
  bool _forceSdr = false;

  @override
  void didUpdateWidget(covariant ErikaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.cacheKey != widget.cacheKey ||
        oldWidget.maxDecodeExtent != widget.maxDecodeExtent) {
      _requestedWidth = -1;
      _requestedHeight = -1;
      _forceSdr = false;
      _replaceLease(null);
      _image = null;
      _error = null;
      _stackTrace = null;
      _ready = false;
    }
  }

  @override
  void dispose() {
    _generation += 1;
    _replaceLease(null);
    super.dispose();
  }

  void _scheduleDecode(int width, int height) {
    if (_requestedWidth == width && _requestedHeight == height) return;
    _requestedWidth = width;
    _requestedHeight = height;
    if (_decodeScheduled) return;
    _decodeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _decodeScheduled = false;
      if (!mounted) return;
      _startDecode(_requestedWidth, _requestedHeight);
    });
  }

  Future<void> _startDecode(int width, int height) async {
    final generation = ++_generation;
    _replaceLease(null);
    setState(() {
      _image = null;
      _error = null;
      _stackTrace = null;
      _ready = false;
    });
    if (!ErikaImagePipeline.isSupported) {
      _setError(
        generation,
        const ErikaImageException(
          ErikaImageErrorReason.unsupportedPlatform,
          'Erika static images are not implemented on this platform',
        ),
        StackTrace.current,
      );
      return;
    }
    try {
      final capabilities = await ErikaImagePipeline.capabilities();
      if (!mounted || generation != _generation) return;
      final identity = widget.cacheKey ?? widget.path;
      final lease = _forceSdr || !capabilities.hdrSurfaceSupported
          ? _ErikaSdrCoordinator.instance.acquire(
              path: widget.path,
              identity: identity,
              width: width,
              height: height,
            )
          : _decodeNativeImage(
              method: 'decodeImage',
              path: widget.path,
              width: width,
              height: height,
            );
      _replaceLease(lease);
      final image = await lease.future;
      if (!mounted || generation != _generation || !identical(_lease, lease)) {
        return;
      }
      setState(() {
        _image = image;
        _ready = image is _ErikaSdrTexture;
      });
      if (image is _ErikaSdrTexture) {
        widget.onPresentationChanged?.call(ErikaImagePresentation.sdr);
        _notifyReady(generation);
      }
    } catch (error, stackTrace) {
      _setError(generation, error, stackTrace);
    }
  }

  void _setError(int generation, Object error, StackTrace stackTrace) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _error = error;
      _stackTrace = stackTrace;
      _ready = false;
    });
  }

  void _replaceLease(_ErikaImageLease? next) {
    final previous = _lease;
    _lease = next;
    previous?.release();
  }

  void _handleHdrReady() {
    if (!mounted || _image is! _ErikaHdrImage || _ready) return;
    setState(() => _ready = true);
    widget.onPresentationChanged?.call(ErikaImagePresentation.hdr);
    _notifyReady(_generation);
  }

  void _notifyReady(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation && _ready) {
        widget.onReady?.call();
      }
    });
  }

  void _handleHdrStatus(_ErikaImageOutputStatus status) {
    if (!mounted || _image is! _ErikaHdrImage) return;
    widget.onPresentationChanged?.call(
      status.hdrOutputConfirmed
          ? ErikaImagePresentation.hdr
          : ErikaImagePresentation.sdr,
    );
  }

  void _handleHdrError(ErikaImageException error) {
    if (!mounted || _image is! _ErikaHdrImage || _forceSdr) return;
    _forceSdr = true;
    _startDecode(_requestedWidth, _requestedHeight);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = _physicalDecodeSize(
          context,
          constraints,
          widget.maxDecodeExtent,
        );
        _scheduleDecode(size.$1, size.$2);
        final error = _error;
        if (error != null) {
          return widget.errorBuilder?.call(context, error, _stackTrace) ??
              widget.placeholder;
        }
        final image = _image;
        if (image is _ErikaSdrTexture) {
          return FittedBox(
            fit: widget.fit,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: image.width.toDouble(),
              height: image.height.toDouble(),
              child: Texture(
                textureId: image.textureId,
                filterQuality: widget.filterQuality,
              ),
            ),
          );
        }
        if (image is _ErikaHdrImage) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _ErikaFittedHdrSurface(
                image: image,
                fit: widget.fit,
                onReady: _handleHdrReady,
                onError: _handleHdrError,
                onOutputStatusChanged: _handleHdrStatus,
              ),
              if (!_ready) widget.placeholder,
            ],
          );
        }
        return widget.placeholder;
      },
    );
  }
}

(int, int) _physicalDecodeSize(
  BuildContext context,
  BoxConstraints constraints,
  int? maxDecodeExtent,
) {
  final ratio = MediaQuery.devicePixelRatioOf(context);
  var width = constraints.hasBoundedWidth
      ? math.max(1, (constraints.maxWidth * ratio).ceil())
      : maxDecodeExtent ?? 0;
  var height = constraints.hasBoundedHeight
      ? math.max(1, (constraints.maxHeight * ratio).ceil())
      : maxDecodeExtent ?? 0;
  if (maxDecodeExtent != null) {
    width = math.min(width, maxDecodeExtent);
    height = math.min(height, maxDecodeExtent);
  }
  width = _bucket(width, ErikaImagePipeline.policy.decodeDimensionBuckets);
  height = _bucket(height, ErikaImagePipeline.policy.decodeDimensionBuckets);
  final pixels = width * height;
  final maximumPixels = ErikaImagePipeline.policy.maxOutputPixels;
  if (pixels > maximumPixels && width > 0 && height > 0) {
    final scale = math.sqrt(maximumPixels / pixels);
    width = math.max(1, (width * scale).floor());
    height = math.max(1, (height * scale).floor());
  }
  return (width, height);
}

int _bucket(int value, List<int> buckets) {
  if (value <= 0 || buckets.isEmpty) return value;
  for (final bucket in buckets) {
    if (bucket >= value) return bucket;
  }
  return value;
}

enum _ErikaImageDynamicRange { unknown, sdr, hdr10Pq, hlg, ultraHdrGainMap }

final class _ErikaImageMetadata {
  const _ErikaImageMetadata({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.sourceDynamicRange,
  });

  final int sourceWidth;
  final int sourceHeight;
  final _ErikaImageDynamicRange sourceDynamicRange;
}

sealed class _ErikaDecodedImage {
  const _ErikaDecodedImage(this.metadata);

  final _ErikaImageMetadata metadata;
}

final class _ErikaSdrTexture extends _ErikaDecodedImage {
  _ErikaSdrTexture({
    required _ErikaImageMetadata metadata,
    required this.textureId,
    required this.width,
    required this.height,
  }) : super(metadata);

  final int textureId;
  final int width;
  final int height;
  Future<void>? _disposeFuture;

  Future<void> dispose() => _disposeFuture ??= _imageChannel
      .invokeMethod<void>('disposeSdrTexture', <String, Object>{
        'textureId': textureId,
      })
      .onError<PlatformException>((error, _) {
        _disposeFuture = null;
        throw _imageException(error, 'Unable to dispose SDR image texture');
      });
}

final class _ErikaHdrImage extends _ErikaDecodedImage {
  _ErikaHdrImage(this.imageId, super.metadata);

  final int imageId;
  Future<void>? _disposeFuture;

  Future<void> dispose() => _disposeFuture ??= _imageChannel
      .invokeMethod<void>('disposeHdrImage', <String, Object>{
        'imageId': imageId,
      })
      .onError<PlatformException>((error, _) {
        _disposeFuture = null;
        throw _imageException(error, 'Unable to dispose HDR image');
      });
}

final class _ErikaImageLease {
  _ErikaImageLease(this.future, this._release);

  final Future<_ErikaDecodedImage> future;
  final VoidCallback _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

_ErikaImageLease _decodeNativeImage({
  required String method,
  required String path,
  required int width,
  required int height,
}) {
  final operationId = _ErikaSdrCoordinator.nextOperationId();
  var completed = false;
  var released = false;
  _ErikaDecodedImage? decoded;
  final future = _imageChannel
      .invokeMapMethod<String, Object?>(method, <String, Object>{
        'operationId': operationId,
        'path': path,
        'cacheWidth': width,
        'cacheHeight': height,
      })
      .then<_ErikaDecodedImage>((value) {
        completed = true;
        if (value == null) {
          throw const ErikaImageException(
            ErikaImageErrorReason.internal,
            'The platform returned no static image',
          );
        }
        final metadata = _metadataFromMap(value);
        final result = value['presentation'] == 'hdr'
            ? _ErikaHdrImage(_integer(value['imageId']), metadata)
            : _ErikaSdrTexture(
                metadata: metadata,
                textureId: _integer(value['textureId']),
                width: _integer(value['width']),
                height: _integer(value['height']),
              );
        decoded = result;
        if (released) unawaited(_disposeDecodedQuietly(result));
        return result;
      })
      .onError<PlatformException>((error, _) {
        completed = true;
        throw _imageException(error, 'Erika static image decode failed');
      });
  return _ErikaImageLease(future, () {
    released = true;
    final image = decoded;
    if (image != null) {
      unawaited(_disposeDecodedQuietly(image));
    } else if (!completed) {
      unawaited(
        _imageChannel.invokeMethod<void>('cancelImageDecode', <String, Object>{
          'operationId': operationId,
        }),
      );
    }
  });
}

final class _ErikaSdrCoordinator {
  _ErikaSdrCoordinator._();

  static final _ErikaSdrCoordinator instance = _ErikaSdrCoordinator._();
  static int _nextOperationId = 1;

  static int nextOperationId() => _nextOperationId++;

  final Map<String, _SharedSdrDecode> _entries = <String, _SharedSdrDecode>{};
  final LinkedHashMap<String, _SharedSdrDecode> _idle =
      LinkedHashMap<String, _SharedSdrDecode>();
  int _idleTextureBytes = 0;
  bool _observingLifecycle = false;
  int singleFlightHits = 0;
  ErikaImagePolicy _policy = const ErikaImagePolicy();

  int get idleTextureBytes => _idleTextureBytes;

  void configure(ErikaImagePolicy policy) {
    _policy = policy;
    _trimToBudget();
  }

  _ErikaImageLease acquire({
    required String path,
    required String identity,
    required int width,
    required int height,
  }) {
    if (!_observingLifecycle) {
      _observingLifecycle = true;
      WidgetsBinding.instance.addObserver(
        _ErikaImageTextureCacheObserver(this),
      );
    }
    final key = '$identity|${width}x$height';
    var shared = _entries[key];
    if (shared != null) {
      if (shared.leases == 0 && identical(_idle.remove(key), shared)) {
        _idleTextureBytes -= shared.textureBytes;
      }
      shared.leases += 1;
      singleFlightHits += 1;
    } else {
      final nativeLease = _decodeNativeImage(
        method: 'decodeSdrTexture',
        path: path,
        width: width,
        height: height,
      );
      final future = nativeLease.future.then<_ErikaSdrTexture>((image) {
        if (image is! _ErikaSdrTexture) {
          throw const ErikaImageException(
            ErikaImageErrorReason.internal,
            'The SDR decoder returned an HDR surface',
          );
        }
        return image;
      });
      shared = _SharedSdrDecode(key, nativeLease, future);
      _entries[key] = shared;
      final captured = shared;
      future
          .then<void>(
            (texture) {
              captured.completed = true;
              captured.texture = texture;
              if (captured.evicted) {
                captured.nativeLease.release();
              } else if (captured.leases == 0) {
                _retainIdle(captured);
              }
            },
            onError: (_, _) {
              captured.completed = true;
              captured.nativeLease.release();
              if (identical(_entries[key], captured)) _entries.remove(key);
            },
          )
          .ignore();
    }
    final captured = shared;
    var released = false;
    return _ErikaImageLease(captured.future, () {
      if (released) return;
      released = true;
      captured.leases -= 1;
      if (!captured.completed && captured.leases == 0) {
        captured.evicted = true;
        if (identical(_entries[key], captured)) _entries.remove(key);
        captured.nativeLease.release();
      } else if (captured.completed && captured.leases == 0) {
        _retainIdle(captured);
      }
    });
  }

  void _retainIdle(_SharedSdrDecode shared) {
    if (shared.evicted || shared.texture == null || shared.leases != 0) return;
    if (identical(_idle[shared.key], shared)) return;
    _idle[shared.key] = shared;
    _idleTextureBytes += shared.textureBytes;
    _trimToBudget();
  }

  void _trimToBudget() {
    while (_idleTextureBytes > _policy.maxIdleTextureBytes &&
        _idle.isNotEmpty) {
      final key = _idle.keys.first;
      final shared = _idle.remove(key)!;
      _idleTextureBytes -= shared.textureBytes;
      shared.evicted = true;
      if (identical(_entries[key], shared)) _entries.remove(key);
      shared.nativeLease.release();
    }
  }

  void trimIdleTextures() {
    final idle = _idle.values.toList(growable: false);
    _idle.clear();
    _idleTextureBytes = 0;
    for (final shared in idle) {
      shared.evicted = true;
      if (identical(_entries[shared.key], shared)) {
        _entries.remove(shared.key);
      }
      shared.nativeLease.release();
    }
  }
}

final class _SharedSdrDecode {
  _SharedSdrDecode(this.key, this.nativeLease, this.future);

  final String key;
  final _ErikaImageLease nativeLease;
  final Future<_ErikaSdrTexture> future;
  int leases = 1;
  bool completed = false;
  bool evicted = false;
  _ErikaSdrTexture? texture;

  int get textureBytes {
    final value = texture;
    return value == null ? 0 : value.width * value.height * 4;
  }
}

final class _ErikaImageTextureCacheObserver with WidgetsBindingObserver {
  const _ErikaImageTextureCacheObserver(this.coordinator);

  final _ErikaSdrCoordinator coordinator;

  @override
  void didHaveMemoryPressure() {
    coordinator.trimIdleTextures();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!ErikaImagePipeline.policy.trimIdleTexturesOnBackground) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      coordinator.trimIdleTextures();
    }
  }
}

final class _ErikaImageOutputStatus {
  const _ErikaImageOutputStatus({
    required this.hdrOutputConfirmed,
    required this.activeDynamicRange,
    required this.activeEncoding,
    required this.fallbackReason,
  });

  final bool hdrOutputConfirmed;
  final _ErikaImageDynamicRange activeDynamicRange;
  final int activeEncoding;
  final int fallbackReason;
}

final Map<int, _ErikaHdrImageViewState> _hdrImageViews =
    <int, _ErikaHdrImageViewState>{};
bool _hdrImageHandlerInstalled = false;

final class _ErikaHdrImageView extends StatefulWidget {
  const _ErikaHdrImageView({
    required this.image,
    required this.onReady,
    required this.onError,
    required this.onOutputStatusChanged,
  });

  final _ErikaHdrImage image;
  final VoidCallback onReady;
  final ValueChanged<ErikaImageException> onError;
  final ValueChanged<_ErikaImageOutputStatus> onOutputStatusChanged;

  @override
  State<_ErikaHdrImageView> createState() => _ErikaHdrImageViewState();
}

final class _ErikaHdrImageViewState extends State<_ErikaHdrImageView> {
  int? _viewId;

  @override
  void initState() {
    super.initState();
    if (!_hdrImageHandlerInstalled) {
      _hdrImageHandlerInstalled = true;
      _imageChannel.setMethodCallHandler((call) async {
        if (call.method != 'imageSurfaceEvent') return;
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        _hdrImageViews[_integer(args['viewId'])]?._handleSurfaceEvent(args);
      });
    }
  }

  void _handleSurfaceEvent(Map<Object?, Object?> event) {
    if (!mounted || _integer(event['imageId']) != widget.image.imageId) return;
    if (event['ok'] != true) {
      widget.onError(
        ErikaImageException(
          ErikaImageErrorReason.renderer,
          event['error']?.toString() ?? 'HDR image surface failed',
        ),
      );
      return;
    }
    final value = Map<Object?, Object?>.from(event['value'] as Map);
    widget.onOutputStatusChanged(
      _ErikaImageOutputStatus(
        hdrOutputConfirmed: value['hdrOutputConfirmed'] == true,
        activeDynamicRange: _dynamicRange(value['activeDynamicRange']),
        activeEncoding: _integer(value['activeEncoding']),
        fallbackReason: _integer(value['fallbackReason']),
      ),
    );
    widget.onReady();
  }

  void _registerView(int id) {
    final oldId = _viewId;
    if (oldId != null) _hdrImageViews.remove(oldId);
    _viewId = id;
    _hdrImageViews[id] = this;
  }

  @override
  Widget build(BuildContext context) {
    const viewType = 'erika_flutter/hdr_image_view';
    final creationParams = <String, Object?>{
      'imageId': widget.image.imageId,
      'composition': 'hybrid',
    };
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        key: ValueKey<int>(widget.image.imageId),
        viewType: viewType,
        layoutDirection: TextDirection.ltr,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        onPlatformViewCreated: _registerView,
      );
    }
    return PlatformViewLink(
      key: ValueKey<int>(widget.image.imageId),
      viewType: viewType,
      surfaceFactory: (_, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller
          ..addOnPlatformViewCreatedListener(_registerView)
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
        return controller;
      },
    );
  }

  @override
  void dispose() {
    final id = _viewId;
    if (id != null && identical(_hdrImageViews[id], this)) {
      _hdrImageViews.remove(id);
    }
    super.dispose();
  }
}

final class _ErikaFittedHdrSurface extends StatelessWidget {
  const _ErikaFittedHdrSurface({
    required this.image,
    required this.fit,
    required this.onReady,
    required this.onError,
    required this.onOutputStatusChanged,
  });

  final _ErikaHdrImage image;
  final BoxFit fit;
  final VoidCallback onReady;
  final ValueChanged<ErikaImageException> onError;
  final ValueChanged<_ErikaImageOutputStatus> onOutputStatusChanged;

  @override
  Widget build(BuildContext context) {
    final sourceSize = Size(
      image.metadata.sourceWidth.toDouble(),
      image.metadata.sourceHeight.toDouble(),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth ||
            !constraints.hasBoundedHeight ||
            sourceSize.isEmpty) {
          return _view();
        }
        final destination = applyBoxFit(
          fit,
          sourceSize,
          constraints.biggest,
        ).destination;
        return Stack(
          clipBehavior: Clip.hardEdge,
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              left: (constraints.maxWidth - destination.width) / 2,
              top: (constraints.maxHeight - destination.height) / 2,
              width: destination.width,
              height: destination.height,
              child: _view(),
            ),
          ],
        );
      },
    );
  }

  Widget _view() => _ErikaHdrImageView(
    image: image,
    onReady: onReady,
    onError: onError,
    onOutputStatusChanged: onOutputStatusChanged,
  );
}

Future<void> _disposeDecodedQuietly(_ErikaDecodedImage image) async {
  if (image is _ErikaHdrImage) await WidgetsBinding.instance.endOfFrame;
  try {
    if (image is _ErikaHdrImage) {
      await image.dispose();
    } else if (image is _ErikaSdrTexture) {
      await image.dispose();
    }
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'erika_flutter',
        context: ErrorDescription('while disposing a static image resource'),
      ),
    );
  }
}

int _integer(Object? value) => switch (value) {
  int value => value,
  num value => value.toInt(),
  String value => int.tryParse(value) ?? 0,
  _ => 0,
};

ErikaImageDecodeBackend _decodeBackend(Object? value) => switch (value) {
  'software' || 1 => ErikaImageDecodeBackend.software,
  'hardware' || 2 => ErikaImageDecodeBackend.hardware,
  _ => ErikaImageDecodeBackend.unknown,
};

_ErikaImageDynamicRange _dynamicRange(Object? value) =>
    switch (_integer(value)) {
      1 => _ErikaImageDynamicRange.sdr,
      2 => _ErikaImageDynamicRange.hdr10Pq,
      3 => _ErikaImageDynamicRange.hlg,
      4 => _ErikaImageDynamicRange.ultraHdrGainMap,
      _ => _ErikaImageDynamicRange.unknown,
    };

_ErikaImageMetadata _metadataFromMap(Map<String, Object?> value) =>
    _ErikaImageMetadata(
      sourceWidth: _integer(value['sourceWidth'] ?? value['width']),
      sourceHeight: _integer(value['sourceHeight'] ?? value['height']),
      sourceDynamicRange: _dynamicRange(value['sourceDynamicRange']),
    );

ErikaImageException _imageException(PlatformException error, String fallback) =>
    ErikaImageException(
      _errorReason(_platformImageErrorKind(error)),
      error.message ?? fallback,
    );

ErikaImageErrorReason _errorReason(int kind) => switch (kind) {
  1 => ErikaImageErrorReason.unsupportedPlatform,
  2 => ErikaImageErrorReason.unsupportedFormat,
  3 => ErikaImageErrorReason.corrupt,
  4 => ErikaImageErrorReason.source,
  5 => ErikaImageErrorReason.network,
  6 => ErikaImageErrorReason.cancelled,
  7 => ErikaImageErrorReason.resourceLimit,
  8 => ErikaImageErrorReason.renderer,
  10 => ErikaImageErrorReason.busy,
  _ => ErikaImageErrorReason.internal,
};

int _platformImageErrorKind(PlatformException error) {
  final details = error.details;
  return details is Map ? _integer(details['kind']) : 9;
}
