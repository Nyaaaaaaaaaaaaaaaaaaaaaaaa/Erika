import 'dart:async';

import 'package:erika_flutter/erika_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'image identity follows resource revision and physical decode bound',
    () {
      const first = ErikaFileImage(
        path: '/cache/one.avif',
        cacheKey: 'image:revision-1',
        maximumDecodeExtent: 1024,
      );
      const renewedUrl = ErikaFileImage(
        path: '/cache/two.avif',
        cacheKey: 'image:revision-1',
        maximumDecodeExtent: 1024,
      );
      const resized = ErikaFileImage(
        path: '/cache/one.avif',
        cacheKey: 'image:revision-1',
        maximumDecodeExtent: 2048,
      );
      const replaced = ErikaFileImage(
        path: '/cache/one.avif',
        cacheKey: 'image:revision-2',
        maximumDecodeExtent: 1024,
      );

      expect(first, renewedUrl);
      expect(first.hashCode, renewedUrl.hashCode);
      expect(first, isNot(resized));
      expect(first, isNot(replaced));
    },
  );

  test(
    'policy configuration and FFI scheduler diagnostics stay typed',
    () async {
      const policy = ErikaImagePolicy(
        maxOutputPixels: 4 * 1024 * 1024,
        maxQueuedDecodes: 4,
        maxConcurrentDecodes: 2,
      );
      await ErikaImagePipeline.configure(policy);

      expect(ErikaImagePipeline.policy, same(policy));
      final diagnostics = await ErikaImagePipeline.diagnostics();
      expect(diagnostics.queued, 0);
      expect(diagnostics.inflight, 0);
      expect(diagnostics.decodeCount, 0);

      await ErikaImagePipeline.configure(const ErikaImagePolicy());
    },
  );

  test('retaining an undecoded image never loads the native library', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const provider = ErikaFileImage(
      path: '/cache/still.avif',
      cacheKey: 'image:revision-1',
      maximumDecodeExtent: 1024,
    );

    final interest = provider.retain(interactive: true);
    interest.setInteractive(false);
    interest.release();
    interest.release();

    expect(ErikaFileImage.diagnostics.queued, 0);
    expect(ErikaFileImage.diagnostics.inflight, 0);
  });

  test('explicit interest release cancels a queued Flutter image load', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const provider = ErikaFileImage(
      path: '/cache/cancel.avif',
      cacheKey: 'image:cancel-queued',
      maximumDecodeExtent: 1024,
    );
    final interest = provider.retain(interactive: true);
    final failure = Completer<Object>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (_, __) {},
      onError: (error, _) => failure.complete(error),
    );
    stream.addListener(listener);

    interest.release();
    final error = await failure.future;
    expect(error, isA<ErikaImageException>());
    expect(
      (error as ErikaImageException).reason,
      ErikaImageErrorReason.cancelled,
    );
    expect(ErikaFileImage.diagnostics.queuedCancelled, greaterThan(0));

    stream.removeListener(listener);
  });

  test('unsupported platforms report a typed image error', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    const provider = ErikaFileImage(
      path: '/cache/still.avif',
      cacheKey: 'image:revision-1',
      maximumDecodeExtent: 1024,
    );
    final failure = Completer<Object>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (_, __) {},
      onError: (error, _) => failure.complete(error),
    );
    stream.addListener(listener);

    final error = await failure.future;
    expect(error, isA<ErikaImageException>());
    expect(
      (error as ErikaImageException).reason,
      ErikaImageErrorReason.unsupportedPlatform,
    );

    stream.removeListener(listener);
  });
}
