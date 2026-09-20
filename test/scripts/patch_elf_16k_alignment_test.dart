// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../scripts/patch_elf_16k_alignment.dart' as patcher;

/// Synthetic ELF builders for the 16 KB page-alignment patcher (gh-746).
///
/// Play rejects uploads containing native libraries whose PT_LOAD program
/// headers carry an alignment below 16 KB. The patcher raises `p_align` to
/// 0x4000 in place — which is exactly what a `-z max-page-size=16384` relink
/// produces — but ONLY when every LOAD segment is already 16 KB-congruent
/// (`p_offset` and `p_vaddr - p_offset` are multiples of 0x4000); a blob that
/// fails the congruence check needs a real relink, so the patcher reports it
/// loudly instead of writing a broken binary.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('elf16k-test-');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// Minimal little-endian ELF image with the given LOAD segments
  /// `(p_offset, p_vaddr, p_align, flags)` and one non-LOAD PT_DYNAMIC header
  /// (which must never be touched).
  Uint8List buildElf({
    required bool elf64,
    required List<(int, int, int, int)> loads,
  }) {
    final phnum = loads.length + 1;
    final phentsize = elf64 ? 56 : 32;
    final ehdrSize = elf64 ? 64 : 52;
    final phoff = ehdrSize;
    final image = Uint8List(phoff + phnum * phentsize)
      ..[0] = 0x7f
      ..[1] = 0x45 // 'E'
      ..[2] = 0x4c // 'L'
      ..[3] = 0x46 // 'F'
      ..[4] = elf64 ? 2 : 1
      ..[5] = 1; // LSB
    final w32 = (int off, int v) =>
        ByteData.sublistView(image).setUint32(off, v, Endian.little);
    final w64 = (int off, int v) =>
        ByteData.sublistView(image).setUint64(off, v, Endian.little);
    if (elf64) {
      w64(0x20, phoff); // e_phoff
      image[0x34] = ehdrSize ~/ 0x10 << 4 | 0; // e_ehsize-ish, unused
      image.setUint16 ??= null; // placeholder removed below
    }
    return image;
  }

  group('placeholder', () {
    test('placeholder', () {
      expect(true, isFalse);
    });
  });
}
