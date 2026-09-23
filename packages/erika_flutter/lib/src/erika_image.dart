import 'package:flutter/foundation.dart';

import 'erika_file_image.dart';

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

/// Limits for decoding a single static image and scheduling concurrent work.
///
/// Configure these before resolving an [ErikaFileImage]. Erika's C library
/// enforces the source and output limits as well as the decode timeout.
final class ErikaImagePolicy {
  const ErikaImagePolicy({
    this.maxEncodedBytes = 128 * 1024 * 1024,
    this.maxSourcePixels = 32 * 1024 * 1024,
    this.maxOutputPixels = 32 * 1024 * 1024,
    this.maxPacketsBeforeFrame = 256,
    this.decodeTimeout = const Duration(seconds: 15),
    this.maxQueuedDecodes = 8,
    this.maxConcurrentDecodes = 1,
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
       assert(maxConcurrentDecodes > 0 && maxConcurrentDecodes <= 4);

  final int maxEncodedBytes;
  final int maxSourcePixels;
  final int maxOutputPixels;
  final int maxPacketsBeforeFrame;
  final Duration decodeTimeout;
  final int maxQueuedDecodes;
  final int maxConcurrentDecodes;

  /// Ascending physical-pixel sizes available to callers when choosing a
  /// bounded decode extent. The provider uses the explicit extent it receives.
  final List<int> decodeDimensionBuckets;
}

/// Decode scheduling counters for the Dart FFI still-image path.
final class ErikaImageDiagnostics {
  const ErikaImageDiagnostics({
    required this.queued,
    required this.inflight,
    required this.decodeCount,
    required this.singleFlightHits,
    required this.queuedCancelled,
  });

  final int queued;
  final int inflight;
  final int decodeCount;
  final int singleFlightHits;
  final int queuedCancelled;
}

abstract final class ErikaImagePipeline {
  static ErikaImagePolicy _policy = const ErikaImagePolicy();

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform.name == 'ohos');

  static ErikaImagePolicy get policy => _policy;

  /// Applies limits to subsequent decodes. No native texture pipeline remains
  /// to configure; active decodes retain the policy with which they started.
  static Future<void> configure(ErikaImagePolicy policy) async {
    _validatePolicy(policy);
    _policy = policy;
  }

  static Future<ErikaImageDiagnostics> diagnostics() async =>
      ErikaFileImage.diagnostics;

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
