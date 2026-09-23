import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readNormalized(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  test('Flutter player requests the existing native SDR ABI value', () {
    final header = _readNormalized('native/include/erika.h');
    final dart = _readNormalized('lib/src/erika_player.dart');

    expect(header, contains('ErikaPresenterOutputMode_Sdr = 0'));
    expect(dart, contains("'outputMode': 0"));
    expect(dart, isNot(contains('ErikaOutputMode.preferHdr')));
    expect(dart, isNot(contains("'edrHeadroom'")));
  });

  test('iOS uses an SDR presenter and an eight-bit SDR Metal layer', () {
    final plugin = _readNormalized('ios/Classes/ErikaFlutterPlugin.swift');

    expect(plugin, contains('ErikaPresenterConfigC.sdr'));
    expect(plugin, contains('erikaConfigureLayerSdr(view.metalLayer)'));
    expect(plugin, contains('layer.contentsFormat = .RGBA8Uint'));
    expect(plugin, contains('layer.wantsExtendedDynamicRangeContent = false'));
    expect(plugin, isNot(contains('case "getHdrCapabilities":')));
  });

  for (final platform in <String>['ios', 'tvos']) {
    test('$platform presenter stats still returns its Flutter map', () {
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
}
