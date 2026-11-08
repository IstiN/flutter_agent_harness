import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every bundled font is declared, non-empty and has an OFL license', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final directory = Directory('assets/fonts');
    final fonts = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.ttf'))
        .toList();
    expect(fonts, isNotEmpty);

    for (final font in fonts) {
      final name = font.uri.pathSegments.last;
      expect(
        pubspec,
        contains('- asset: assets/fonts/$name'),
        reason: '$name is not registered in pubspec.yaml',
      );
      final bytes = font.readAsBytesSync();
      expect(bytes.length, greaterThan(1000), reason: name);
      expect(_isTrueType(bytes), isTrue, reason: '$name has an invalid header');
    }

    for (final family in const [
      'Inter',
      'Geist',
      'GeistMono',
      'PlusJakartaSans',
      'Outfit',
      'DMMono',
      'JetBrainsMono',
      'SpaceGrotesk',
      'IBMPlexSans',
      'IBMPlexMono',
      'Manrope',
    ]) {
      final license = File('assets/fonts/$family-LICENSE.txt');
      expect(license.existsSync(), isTrue, reason: license.path);
      expect(license.readAsStringSync(), contains('SIL OPEN FONT LICENSE'));
    }
  });
}

bool _isTrueType(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final signature = ByteData.sublistView(bytes).getUint32(0);
  return signature == 0x00010000 ||
      signature == 0x4F54544F || // OTTO
      signature == 0x74727565; // true
}
