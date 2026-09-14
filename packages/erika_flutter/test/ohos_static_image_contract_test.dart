import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const pluginPath =
      'ohos/src/main/ets/components/plugin/ErikaFlutterPlugin.ets';
  const nativePath = 'ohos/src/main/cpp/erika_flutter_image.cpp';

  test('OpenHarmony static images have a typed Flutter texture bridge', () {
    final plugin = File(pluginPath).readAsStringSync();
    final native = File(nativePath).readAsStringSync();
    final cmake = File('ohos/src/main/cpp/CMakeLists.txt').readAsStringSync();
    final nativeTypes = File(
      'ohos/src/main/cpp/types/liberika_flutter/index.d.ts',
    ).readAsStringSync();

    for (final method in <String>[
      'configureImagePipeline',
      'getImageCapabilities',
      'getImageDiagnostics',
      'decodeImage',
      'decodeSdrTexture',
      'decodeHdrImage',
      'cancelImageDecode',
      'disposeSdrTexture',
      'disposeHdrImage',
      'createHdrImageTexture',
      'resizeHdrImageTexture',
      'releaseHdrImageTexture',
    ]) {
      expect(plugin, contains("call.method === '$method'"));
    }
    expect(plugin, contains('interface ErikaImageNativeResponse'));
    expect(plugin, contains('interface ErikaImageNativeModule'));
    expect(plugin, contains('const erikaImageNative: ErikaImageNativeModule'));
    expect(
      plugin,
      contains('private imageTextures: Map<number, ErikaImageTexture>'),
    );
    expect(
      plugin,
      contains('private imageTextureByImageId: Map<number, number>'),
    );
    expect(plugin, contains('nativeDecodeImageSurface('));
    expect(plugin, contains('nativeAttachHdrImageSurface('));
    expect(plugin, contains('nativeResizeHdrImageSurface('));
    expect(plugin, contains('nativeDetachHdrImageSurface('));
    expect(plugin, contains('nativeDestroyHdrImage('));

    expect(cmake, contains('erika_flutter_image.cpp'));
    expect(native, contains('ErikaFlutterDefineImageExports'));
    expect(native, contains('nativeConfigureImagePipeline'));
    expect(native, contains('nativeDecodeImageSurface'));
    expect(native, contains('erika_image_decode_uri_sized_with_policy'));
    expect(native, contains('ErikaHarmonyNextConfigureSurface'));
    expect(native, contains('NextBridgeImageId'));
    expect(native, contains('maxActiveImageSurfaces'));
    expect(
      native,
      contains(
        'Only one retained HarmonyOS NEXT static image surface may be active',
      ),
    );
    expect(nativeTypes, contains('nativeConfigureImagePipeline'));
    expect(nativeTypes, contains('nativeDecodeImageSurface'));
    expect(nativeTypes, contains('nativeAttachHdrImageSurface'));
    expect(nativeTypes, contains('nativeDestroyHdrImage'));
  });

  test('OpenHarmony static HDR status is emitted only after native render', () {
    final native = File(nativePath).readAsStringSync();
    final dart = File('lib/src/erika_image.dart').readAsStringSync();

    final render = native.indexOf('erika_image_render_surface(');
    final confirmation = native.indexOf('work->has_output_status = true');
    expect(render, greaterThanOrEqualTo(0));
    expect(confirmation, greaterThan(render));
    expect(native, contains('hdrOutputConfirmed'));
    expect(native, contains('work->prefer_hdr'));
    expect(
      native,
      contains('ErikaHarmonyNextConfigureSurface(window, source_is_hdr'),
    );

    expect(dart, contains('bool get _isHarmonyOsNext'));
    expect(dart, contains('maxActiveImageSurfaces'));
    expect(dart, contains('if (_isHarmonyOsNext) {'));
    expect(dart, contains('shared.nativeLease.release();'));
    expect(dart, contains('final class _ErikaOhosHdrImageView'));
    expect(dart, contains("'createHdrImageTexture'"));
    expect(dart, contains("'resizeHdrImageTexture'"));
    expect(dart, contains("'releaseHdrImageTexture'"));
    expect(
      dart,
      contains('hdrOutputConfirmed: status[\'hdrOutputConfirmed\'] == true'),
    );
    expect(dart, contains('Texture(\n                textureId: textureId,'));
  });

  test(
    'OpenHarmony static texture ownership rejects stale async completion',
    () {
      final plugin = File(pluginPath).readAsStringSync();
      final dart = File('lib/src/erika_image.dart').readAsStringSync();

      expect(dart, contains('final imageId = widget.image.imageId;'));
      expect(dart, contains('widget.image.imageId != imageId'));
      expect(
        dart,
        contains('await _releaseTexture(imageId, createdTextureId);'),
      );
      expect(plugin, contains('texture.imageId !== imageId'));
      expect(
        plugin,
        contains('private imageTextures: Map<number, ErikaImageTexture>'),
      );
      expect(
        plugin,
        contains('private imageTextureByImageId: Map<number, number>'),
      );
      expect(plugin, contains('destroyImageAfterSurfaceFailure(imageId)'));
      expect(
        plugin,
        contains('await this.destroyImageAfterSurfaceFailure(imageId);'),
      );
      final detached = plugin.substring(
        plugin.indexOf('onDetachedFromEngine'),
        plugin.indexOf('onAttachedToAbility'),
      );
      expect(
        detached.indexOf('this.destroyImageQuietly(texture.imageId);'),
        lessThan(detached.indexOf('unregisterTexture(textureId)')),
      );
    },
  );

  test(
    'OpenHarmony retained-surface replacement waits FIFO for destroy admission',
    () {
      final native = File(nativePath).readAsStringSync();
      final decodeEntry = native.substring(
        native.indexOf('napi_value NativeDecodeImage('),
        native.indexOf('napi_value NativeDecodeSdrImage('),
      );
      final decodeScheduler = native.substring(
        native.indexOf('void QueueNextImageDecode() {'),
        native.indexOf('napi_value NativeDecodeImage('),
      );
      final destroySchedule = native.substring(
        native.indexOf('napi_value ScheduleSurfaceWork('),
        native.indexOf('ImageSurfaceWork *NewSurfaceWork('),
      );
      final destroyCompletion = native.substring(
        native.indexOf('void CompleteImageSurfaceWork('),
        native.indexOf('void RejectAndDeleteSurfaceWork('),
      );
      final cancellation = native.substring(
        native.indexOf('napi_value NativeCancelImageDecode('),
        native.indexOf('napi_value NativeConfigureImagePipeline('),
      );
      final cleanup = native.substring(
        native.indexOf('void CleanupImageEnvironment('),
        native.indexOf('} // namespace'),
      );

      // Admission happens in the scheduler, not before the replacement has a
      // chance to observe that the old retained surface is being destroyed.
      expect(decodeEntry, isNot(contains('if (hdr && !TryReserveHdrImage())')));
      expect(
        decodeScheduler,
        contains('switch (AdmitRetainedImageOrWaitForDestroy())'),
      );
      expect(
        decodeScheduler,
        contains('Keep the waiting retained decode at the FIFO head'),
      );
      expect(decodeScheduler, contains('work->hdr_reservation_held = true;'));
      expect(decodeScheduler, contains('ErikaImageErrorKind_ResourceLimit'));
      expect(native, contains('std::mutex g_retained_admission_mutex'));
      expect(native, contains('RetainedImageAdmission::kWaitForDestroy'));

      // A destroy gets one exact session-map claim under the same admission
      // gate. All terminal paths consume that claim exactly once.
      expect(
        native,
        contains('bool ClaimRetainedSurfaceDestroy(ImageSurfaceWork *work)'),
      );
      expect(native, contains('work->retained_destroy_claimed = true;'));
      expect(
        native,
        contains('g_pending_retained_surface_destroys.fetch_add(1,'),
      );
      expect(destroySchedule, contains('ClaimRetainedSurfaceDestroy(work)'));
      expect(
        destroySchedule,
        contains('retained_destroy ? max_surface_work + 1 : max_surface_work'),
      );
      expect(destroyCompletion, contains('!work->retained_destroy_executed'));
      expect(
        destroyCompletion,
        contains('RestoreRetainedSurfaceDestroy(work);'),
      );
      final pendingRelease = destroyCompletion.indexOf(
        'FinishRetainedSurfaceDestroyClaim(work);',
      );
      final wake = destroyCompletion.indexOf('QueueNextImageDecode();');
      expect(pendingRelease, greaterThanOrEqualTo(0));
      expect(wake, greaterThan(pendingRelease));
      expect(destroyCompletion, contains('if (completed_retained_destroy)'));
      expect(cancellation, contains('QueueNextImageDecode();'));
      expect(cleanup, contains('FinishRetainedSurfaceDestroyClaim(work);'));
    },
  );
}
