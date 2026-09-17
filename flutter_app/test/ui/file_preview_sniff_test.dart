// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:fa/ui/widgets/file_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List bytes(List<int> list) => Uint8List.fromList(list);

  group('magicMatchesAt', () {
    test('matches a full prefix at the offset', () {
      final b = bytes([1, 2, 3, 4, 5]);
      expect(magicMatchesAt(b, 0, [1, 2, 3]), isTrue);
      expect(magicMatchesAt(b, 2, [3, 4]), isTrue);
    });

    test('rejects a mismatched byte inside the signature', () {
      expect(magicMatchesAt(bytes([1, 2, 9]), 0, [1, 2, 3]), isFalse);
    });

    test('rejects when the signature runs past the end', () {
      expect(magicMatchesAt(bytes([1, 2]), 0, [1, 2, 3]), isFalse);
      // The WEBP check reads at offset 8: a short RIFF must not crash.
      expect(magicMatchesAt(bytes([1, 2]), 8, [1, 2]), isFalse);
    });

    test('empty input never matches a non-empty signature', () {
      expect(magicMatchesAt(bytes([]), 0, [1]), isFalse);
    });
  });

  group('sniffsAsImage', () {
    test('PNG magic', () {
      expect(sniffsAsImage(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D])), isTrue);
    });

    test('JPEG magic', () {
      expect(sniffsAsImage(bytes([0xFF, 0xD8, 0xFF, 0xE0])), isTrue);
    });

    test('GIF8 magic', () {
      expect(sniffsAsImage(bytes([0x47, 0x49, 0x46, 0x38, 0x39])), isTrue);
    });

    test('WEBP: RIFF header with WEBP at bytes 8..11', () {
      final webp = bytes([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0, 0, 0, 0, // size
        0x57, 0x45, 0x42, 0x50, // WEBP
        0, 0,
      ]);
      expect(sniffsAsImage(webp), isTrue);
    });

    test('RIFF without a WEBP tag is not an image', () {
      final wave = bytes([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0, 0, 0, 0,
        0x57, 0x41, 0x56, 0x45, // WAVE
      ]);
      expect(sniffsAsImage(wave), isFalse);
    });

    test('truncated WEBP (under 12 bytes) is not an image', () {
      final short = bytes([
        0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42,
      ]);
      expect(sniffsAsImage(short), isFalse);
    });

    test('text bytes are not an image', () {
      expect(sniffsAsImage(bytes('# heading\n'.codeUnits)), isFalse);
    });

    test('empty input is not an image', () {
      expect(sniffsAsImage(bytes([])), isFalse);
    });
  });
}
