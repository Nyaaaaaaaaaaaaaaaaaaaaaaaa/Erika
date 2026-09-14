import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readNormalized(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  test('automatic output mode keeps the native ABI value 3', () {
    final header = _readNormalized('native/include/erika.h');
    final dart = _readNormalized('lib/src/erika_player.dart');

    expect(header, contains('ErikaPresenterOutputMode_Auto = 3'));
    expect(dart, contains('auto(3)'));
    expect(dart, contains('3 => ErikaOutputMode.auto'));
  });

  for (final platform in <String>['macos', 'ios', 'tvos']) {
    test('$platform defaults Apple output to source-aware auto mode', () {
      final plugin =
          _readNormalized('$platform/Classes/ErikaFlutterPlugin.swift');

      expect(
        plugin,
        anyOf(
          contains(
              'let config = ErikaPresenterConfigC.auto(headroom: headroom)'),
          contains('return .auto(headroom: headroom)'),
        ),
      );
      expect(plugin, contains('case 3:'));
      expect(plugin, contains('getResourceStatus'));
      expect(plugin, contains('erika_presenter_get_resource_status'));
    });
  }

  for (final platform in <String>['ios', 'tvos']) {
    test('$platform does not reset active auto output during resize', () {
      final plugin =
          _readNormalized('$platform/Classes/ErikaFlutterPlugin.swift');

      expect(plugin, contains('if attach || presenterConfig.outputMode != 3'));
    });

    test('$platform presenter stats returns its Flutter map', () {
      final plugin =
          _readNormalized('$platform/Classes/ErikaFlutterPlugin.swift');

      expect(
        plugin,
        contains(
          'func presenterStats() -> [String: Any] {\n'
          '    nativeCallLock.lock()\n'
          '    defer { nativeCallLock.unlock() }\n'
          '    return latestPresenterStats.toFlutterMap()',
        ),
      );
    });
  }

  test('iOS output status includes native dynamic-range confirmation', () {
    final plugin = _readNormalized('ios/Classes/ErikaFlutterPlugin.swift');

    expect(plugin, contains('private struct ErikaDynamicRangeStatusC'));
    expect(plugin, contains('typealias GetDynamicRangeStatusFn'));
    expect(plugin, contains('let getDynamicRangeStatus: GetDynamicRangeStatusFn?'));
    expect(
      plugin,
      contains('erika_presenter_get_dynamic_range_status'),
    );
    expect(plugin, contains('var dynamicRange = ErikaDynamicRangeStatusC()'));
    expect(
      plugin,
      contains('if let getDynamicRangeStatus = library.getDynamicRangeStatus'),
    );
    expect(
      plugin,
      contains('return status.toFlutterMap(dynamicRange: dynamicRange)'),
    );
    expect(
      plugin,
      contains('"sourceDynamicRange": Int(dynamicRange.sourceDynamicRange)'),
    );
    expect(
      plugin,
      contains('"activeDynamicRange": Int(dynamicRange.activeDynamicRange)'),
    );
    expect(
      plugin,
      contains('"hdrOutputConfirmed": dynamicRange.hdrOutputConfirmed'),
    );
  });

  test('iOS reports conservative EDR video capabilities', () {
    final plugin = _readNormalized('ios/Classes/ErikaFlutterPlugin.swift');

    expect(plugin, contains('case "getHdrCapabilities":'));
    expect(plugin, contains('result(hdrCapabilities())'));
    expect(plugin, contains('private func hdrCapabilities() -> [String: Any]'));
    expect(plugin, contains('if #available(iOS 16.0, *)'));
    expect(plugin, contains('UIScreen.main.potentialEDRHeadroom > 1.0'));
    expect(plugin, contains('"known": true'));
    expect(
      plugin,
      contains('"supportedDynamicRanges": hdrSurfaceSupported ? [1, 2, 3] : [1]'),
    );
    expect(plugin, contains('"tenBitSurfaceSupported": false'));
    expect(plugin, contains('"hardwareAv1DecodeKnown": false'));
    expect(plugin, contains('"nativeVsyncSupported": true'));
    expect(plugin, contains('"fallbackReason": hdrSurfaceSupported ? 0 : 1'));
  });

  test('Metal limits contentsFormat switching to UIKit and tvOS', () {
    final rendererFile = File('../../crates/erika/src/renderer/metal/apple.rs');
    if (!rendererFile.existsSync()) {
      return;
    }
    final renderer = _readNormalized(rendererFile.path);

    expect(renderer, contains('layer.setPixelFormat('));
    expect(
      renderer,
      contains(
        '#[cfg(any(target_os = "ios", target_os = "tvos"))]\n'
        '    {\n'
        '        let contents_format',
      ),
    );
    expect(renderer, contains('layer.setContentsFormat(contents_format)'));
    expect(renderer, contains('kCAContentsFormatRGBA16Float'));
    expect(renderer, contains('kCAContentsFormatRGBA8Uint'));
    expect(renderer, contains('clips the right/bottom at 2x'));
  });
}
