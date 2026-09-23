import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'erika_image.dart';
import 'native/erika_image_ffi.dart';

/// A bounded SDR still image decoded from a local file by Erika.
///
/// Use this with Flutter's [Image] and existing file download cache. [cacheKey]
/// must change whenever the file contents change. [maximumDecodeExtent] is a
/// physical-pixel bound on both dimensions, independent of [ResizeImage].
@immutable
final class ErikaFileImage extends ImageProvider<ErikaFileImage> {
  const ErikaFileImage({
    required this.path,
    required this.cacheKey,
    required this.maximumDecodeExtent,
    this.scale = 1,
  }) : assert(path != ''),
       assert(cacheKey != ''),
       assert(maximumDecodeExtent > 0),
       assert(scale > 0);

  final String path;
  final String cacheKey;
  final int maximumDecodeExtent;
  final double scale;

  @override
  Future<ErikaFileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<ErikaFileImage>(this);

  @override
  ImageStreamCompleter loadImage(
    ErikaFileImage key,
    ImageDecoderCallback decode,
  ) {
    final interest = ErikaImagePipeline.isSupported
        ? _ErikaSdrDecodeCoordinator.instance.retainForStream(key)
        : null;
    final completer = OneFrameImageStreamCompleter(
      key._loadFrame().whenComplete(() => interest?.release()),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<String>('cacheKey', cacheKey),
        IntProperty('maximumDecodeExtent', maximumDecodeExtent),
      ],
    );
    if (interest != null) {
      completer.addOnLastListenerRemovedCallback(interest.release);
    }
    return completer;
  }

  ErikaSdrDecodeInterest retain({required bool interactive}) =>
      _ErikaSdrDecodeCoordinator.instance.retain(this, interactive);

  static ErikaImageDiagnostics get diagnostics =>
      _ErikaSdrDecodeCoordinator.instance.diagnostics;

  static final Map<ErikaFileImage, Object> _loads = {};

  Future<ImageInfo> _loadFrame() async {
    if (!ErikaImagePipeline.isSupported) {
      throw const ErikaImageException(
        ErikaImageErrorReason.unsupportedPlatform,
        'Erika SDR image decoding is unavailable on this platform',
      );
    }
    if (maximumDecodeExtent <= 0 || maximumDecodeExtent > 0xffffffff) {
      throw RangeError.range(
        maximumDecodeExtent,
        1,
        0xffffffff,
        'maximumDecodeExtent',
      );
    }
    final token = Object();
    _loads[this] = token;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      final result = await _ErikaSdrDecodeCoordinator.instance.decode(this);
      buffer = await ui.ImmutableBuffer.fromUint8List(
        result.bytes.materialize().asUint8List(),
      );
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: result.width,
        height: result.height,
        rowBytes: result.rowBytes,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image, scale: scale);
    } catch (_) {
      // Include first-frame failures, not just codec construction. Do not evict
      // a newer load if a caller explicitly replaced the failed cache entry.
      if (identical(_loads[this], token)) {
        PaintingBinding.instance.imageCache.evict(this);
      }
      rethrow;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      if (identical(_loads[this], token)) _loads.remove(this);
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ErikaFileImage &&
          other.cacheKey == cacheKey &&
          other.maximumDecodeExtent == maximumDecodeExtent &&
          other.scale == scale;

  @override
  int get hashCode => Object.hash(cacheKey, maximumDecodeExtent, scale);

  @override
  String toString() =>
      '$runtimeType(cacheKey: $cacheKey, maximumDecodeExtent: $maximumDecodeExtent)';
}

/// A view-owned interest, independent of ImageCache's internal listeners.
final class ErikaSdrDecodeInterest {
  ErikaSdrDecodeInterest._(this._job, this._interactive);
  final _ErikaSdrDecodeJob _job;
  bool _interactive;
  bool _released = false;

  void setInteractive(bool value) {
    if (_released || value == _interactive) return;
    _interactive = value;
    _ErikaSdrDecodeCoordinator.instance.drain();
  }

  void release() {
    if (_released) return;
    _released = true;
    _job.interests.remove(this);
    _ErikaSdrDecodeCoordinator.instance.release(_job);
  }
}

final class _ErikaSdrDecodeCoordinator {
  static final instance = _ErikaSdrDecodeCoordinator();
  final Map<ErikaFileImage, _ErikaSdrDecodeJob> _jobs = {};
  final List<_ErikaSdrDecodeJob> _pending = [];
  var _active = 0;
  var _sequence = 0;
  var _decodeCount = 0;
  var _singleFlightHits = 0;
  var _queuedCancelled = 0;

  ErikaImageDiagnostics get diagnostics => ErikaImageDiagnostics(
    queued: _pending.length,
    inflight: _active,
    decodeCount: _decodeCount,
    singleFlightHits: _singleFlightHits,
    queuedCancelled: _queuedCancelled,
  );

  _ErikaSdrDecodeJob _job(ErikaFileImage provider) => _jobs.putIfAbsent(
    provider,
    () => _ErikaSdrDecodeJob(
      provider,
      _sequence++,
      ErikaImagePipeline.policy,
    ),
  );

  ErikaSdrDecodeInterest retain(ErikaFileImage provider, bool interactive) {
    final job = _job(provider);
    final interest = ErikaSdrDecodeInterest._(job, interactive);
    job.interests.add(interest);
    return interest;
  }

  ErikaSdrDecodeInterest? retainForStream(ErikaFileImage provider) {
    // An application that explicitly owns a view interest must be able to
    // cancel an offscreen job even while Flutter keeps a pending cache stream.
    if (_jobs[provider]?.interests.isNotEmpty ?? false) return null;
    return retain(provider, false);
  }

  Future<_ErikaSdrPixels> decode(ErikaFileImage provider) {
    final job = _job(provider);
    if (job.enqueued) {
      _singleFlightHits++;
      return job.completer.future;
    }
    if (!job.enqueued) {
      job.enqueued = true;
      if (_pending.length >= ErikaImagePipeline.policy.maxQueuedDecodes) {
        final expendable = _pending
            .where((item) => !item.interactive)
            .lastOrNull;
        if (job.interactive && expendable != null) {
          _cancel(expendable);
        } else {
          _jobs.remove(provider);
          job.finished = true;
          job.completer.completeError(
            const ErikaImageException(
              ErikaImageErrorReason.busy,
              'Image decode queue is full',
            ),
          );
          return job.completer.future;
        }
      }
      _pending.add(job);
      scheduleMicrotask(drain);
    }
    return job.completer.future;
  }

  void release(_ErikaSdrDecodeJob job) {
    if (job.interests.isEmpty && !job.finished) _cancel(job);
    if (job.interests.isEmpty && identical(_jobs[job.provider], job)) {
      _jobs.remove(job.provider);
    }
  }

  void _cancel(_ErikaSdrDecodeJob job) {
    if (job.finished) return;
    job.cancelled = true;
    if (job.enqueued) {
      // A new view must not attach to the still-running cancelled completer.
      // Token-fenced loader cleanup will not evict a newer replacement.
      PaintingBinding.instance.imageCache.evict(job.provider);
    }
    _pending.remove(job);
    if (!job.running && job.enqueued) _queuedCancelled++;
    if (identical(_jobs[job.provider], job)) _jobs.remove(job.provider);
    // Let the native worker finish/release its buffers before completing.
    if (job.running) {
      try {
        final operationId = job.operationId;
        if (operationId != null) cancelErikaImageDecode(operationId);
      } catch (_) {
        // Teardown must remain safe if native cancellation itself is unavailable.
        // The worker's late result is still discarded by job.cancelled.
      }
    } else if (job.enqueued && !job.completer.isCompleted) {
      job.finished = true;
      job.completer.completeError(
        const ErikaImageException(
          ErikaImageErrorReason.cancelled,
          'Image no longer needed',
        ),
      );
    }
  }

  void drain() {
    _pending.sort((a, b) {
      final priority = (a.interactive ? 0 : 1).compareTo(b.interactive ? 0 : 1);
      return priority != 0 ? priority : a.sequence.compareTo(b.sequence);
    });
    while (_active < ErikaImagePipeline.policy.maxConcurrentDecodes &&
        _pending.isNotEmpty) {
      final job = _pending.removeAt(0);
      if (job.cancelled) continue;
      _active++;
      job.running = true;
      unawaited(_run(job));
    }
  }

  Future<void> _run(_ErikaSdrDecodeJob job) async {
    try {
      _decodeCount++;
      final path = job.provider.path;
      final extent = job.provider.maximumDecodeExtent;
      // Allocate only for an actual decode; a warm ImageCache hit never opens
      // the native library. The C allocator is process-wide across engines.
      final operationId = allocateErikaImageOperationId();
      job.operationId = operationId;
      final policy = job.policy;
      final result = await Isolate.run<Map<String, Object>>(
        () => decodeErikaSdrInWorker(path, extent, operationId, policy),
        debugName: 'erika-sdr',
      );
      if (job.cancelled) {
        throw const ErikaImageException(
          ErikaImageErrorReason.cancelled,
          'Image no longer needed',
        );
      }
      job.completer.complete(
        _ErikaSdrPixels(
          width: result['width']! as int,
          height: result['height']! as int,
          rowBytes: result['rowBytes']! as int,
          bytes: result['bytes']! as TransferableTypedData,
        ),
      );
    } catch (error, stack) {
      job.completer.completeError(error, stack);
    } finally {
      job.finished = true;
      if (identical(_jobs[job.provider], job)) _jobs.remove(job.provider);
      _active--;
      drain();
    }
  }
}

final class _ErikaSdrDecodeJob {
  _ErikaSdrDecodeJob(this.provider, this.sequence, this.policy);
  final ErikaFileImage provider;
  int? operationId;
  final int sequence;
  final ErikaImagePolicy policy;
  final interests = <ErikaSdrDecodeInterest>{};
  final completer = Completer<_ErikaSdrPixels>();
  bool enqueued = false;
  bool running = false;
  bool finished = false;
  bool cancelled = false;
  bool get interactive => interests.any((item) => item._interactive);
}

final class _ErikaSdrPixels {
  const _ErikaSdrPixels({
    required this.width,
    required this.height,
    required this.rowBytes,
    required this.bytes,
  });

  final int width;
  final int height;
  final int rowBytes;
  final TransferableTypedData bytes;
}
