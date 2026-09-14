import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:flutter_agent_harness/src/cli/paste_image.dart';

Uint8List _png([int size = 64]) => Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  ...List.filled(size - 8, 0),
]);

void main() {
  group('sniffImageMime', () {
    test('recognizes png/jpeg/gif/webp magic', () {
      expect(
        sniffImageMime([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        'image/png',
      );
      expect(
        sniffImageMime([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]),
        'image/jpeg',
      );
      expect(
        sniffImageMime([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0, 0]),
        'image/gif',
      );
      expect(
        sniffImageMime([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, //
          0x57, 0x45, 0x42, 0x50,
        ]),
        'image/webp',
      );
    });

    test('rejects text and short buffers', () {
      expect(sniffImageMime('hello world'.codeUnits), isNull);
      expect(sniffImageMime([1, 2]), isNull);
    });
  });

  test('imageMimeExtension maps mime to canonical extension', () {
    expect(imageMimeExtension('image/jpeg'), 'jpg');
    expect(imageMimeExtension('image/png'), 'png');
    expect(imageMimeExtension('image/webp'), 'webp');
  });

  test('formatPasteBytes scales B/KB/MB', () {
    expect(formatPasteBytes(512), '512B');
    expect(formatPasteBytes(2048), '2KB');
    expect(formatPasteBytes(1536), '1.5KB');
    expect(formatPasteBytes(25 * 1024 * 1024), '25.0MB');
  });

  group('pasteImageError', () {
    test('accepts an in-cap png (null)', () {
      expect(pasteImageError(_png()), isNull);
    });

    test('names the size cap with both numbers', () {
      final error = pasteImageError(
        Uint8List.fromList([..._png(), ...List.filled(21 * 1024 * 1024, 0)]),
      );
      expect(error, contains('clipboard image too large'));
      expect(error, contains('21.0MB'));
      expect(error, contains('10.0MB'));
    });

    test('names the not-an-image case', () {
      expect(
        pasteImageError('not an image'.codeUnits),
        contains('does not hold'),
      );
    });
  });
}
