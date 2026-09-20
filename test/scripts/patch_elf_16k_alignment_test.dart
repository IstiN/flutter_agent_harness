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
  /// `(p_offset, p_vaddr, p_align)` plus one non-LOAD PT_DYNAMIC header that
  /// must never be touched.
  Uint8List buildElf({
    required bool elf64,
    required List<(int, int, int)> loads,
  }) {
    final phentsize = elf64 ? 56 : 32;
    final ehdrSize = elf64 ? 64 : 52;
    final phnum = loads.length + 1;
    final image = Uint8List(ehdrSize + phnum * phentsize);
    final bd = ByteData.sublistView(image);
    image
      ..[0] = 0x7f
      ..[1] = 0x45 // 'E'
      ..[2] = 0x4c // 'L'
      ..[3] = 0x46 // 'F'
      ..[4] = elf64 ? 2 : 1
      ..[5] = 1; // EI_DATA = LSB
    void phdr(int index, int type, int offset, int vaddr, int align) {
      final base = ehdrSize + index * phentsize;
      bd.setUint32(base, type, Endian.little);
      if (elf64) {
        bd.setUint64(base + 8, offset, Endian.little);
        bd.setUint64(base + 16, vaddr, Endian.little);
        bd.setUint64(base + 48, align, Endian.little);
      } else {
        bd.setUint32(base + 4, offset, Endian.little);
        bd.setUint32(base + 8, vaddr, Endian.little);
        bd.setUint32(base + 28, align, Endian.little);
      }
    }

    // One non-LOAD segment first (PT_DYNAMIC) — its (zero) align must be
    // ignored by both the scan and the patch.
    phdr(0, 2, 0, 0, 0);
    for (var i = 0; i < loads.length; i++) {
      phdr(i + 1, 1, loads[i].$1, loads[i].$2, loads[i].$3);
    }
    if (elf64) {
      bd.setUint64(0x20, ehdrSize, Endian.little); // e_phoff
      bd.setUint16(0x36, phentsize, Endian.little); // e_phentsize
      bd.setUint16(0x38, phnum, Endian.little); // e_phnum
    } else {
      bd.setUint32(0x1c, ehdrSize, Endian.little); // e_phoff
      bd.setUint16(0x2a, phentsize, Endian.little); // e_phentsize
      bd.setUint16(0x2c, phnum, Endian.little); // e_phnum
    }
    return image;
  }

  int loadAlign(Uint8List image, int loadIndex, bool elf64) {
    final phentsize = elf64 ? 56 : 32;
    final base = (elf64 ? 64 : 52) + (loadIndex + 1) * phentsize;
    final bd = ByteData.sublistView(image);
    return elf64
        ? bd.getUint64(base + 48, Endian.little)
        : bd.getUint32(base + 28, Endian.little);
  }

  File writeSo(Uint8List image, {String name = 'libtest.so'}) {
    final file = File('${tempDir.path}/$name');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(image);
    return file;
  }

  group('ELF64', () {
    test('two congruent 4 KB-aligned LOADs are raised to 16 KB', () {
      // Mirrors the QNN Skel layout: file offsets and vaddrs sit on 16 KB
      // boundaries; only the declared p_align is still 4 KB.
      final image = buildElf(elf64: true, loads: [
        (0, 0, 0x1000),
        (0xa3c000, 0xa3c000, 0x1000),
      ]);
      final file = writeSo(image);

      final outcome = patcher.patchFile(file);

      expect(outcome.error, isNull);
      expect(outcome.patched, isTrue);
      final patched = file.readAsBytesSync();
      expect(loadAlign(patched, 0, true), 0x4000);
      expect(loadAlign(patched, 1, true), 0x4000);
      // Only the two p_align fields changed.
      for (var i = 0; i < image.length; i++) {
        final inAlignField = _isAlignField64(i);
        if (!inAlignField) {
          expect(patched[i], image[i], reason: 'byte $i must be unchanged');
        }
      }
    });

    test('already 16 KB-aligned file is a no-op', () {
      final image = buildElf(elf64: true, loads: [
        (0, 0, 0x4000),
        (0xa3c000, 0xa3c000, 0x10000),
      ]);
      final file = writeSo(image);

      final outcome = patcher.patchFile(file);

      expect(outcome.error, isNull);
      expect(outcome.patched, isFalse);
      expect(outcome.alreadyAligned, isTrue);
      expect(file.readAsBytesSync(), image);
    });

    test('non-congruent vaddr/offset diff fails loudly, bytes untouched', () {
      final image = buildElf(elf64: true, loads: [
        (0, 0, 0x1000),
        (0x23e0b0, 0x23f0b0, 0x1000), // diff 0x1000 — not 16 KB-congruent
      ]);
      final file = writeSo(image);

      final outcome = patcher.patchFile(file);

      expect(outcome.patched, isFalse);
      expect(outcome.error, isNotNull);
      expect(outcome.error, contains('congruence'));
      expect(file.readAsBytesSync(), image);
    });

    test('congruent segment at a sub-16 KB file offset patches with a '
        'warning (DSP-blob shape)', () {
      // The Qualcomm QNN Skel layout: vaddr ≡ offset (mod 0x4000) but the
      // file offset itself is only 4 KB-strided. Never kernel-mmap'd (the
      // QNN runtime parses and pushes the image to the Hexagon DSP), so the
      // patch is sound — but the outcome must carry the caveat loudly.
      final image = buildElf(elf64: true, loads: [
        (0, 0, 0x1000),
        (0x1000, 0x1000, 0x1000),
      ]);
      final file = writeSo(image);

      final outcome = patcher.patchFile(file);

      expect(outcome.error, isNull);
      expect(outcome.patched, isTrue);
      expect(outcome.warnings, hasLength(1));
      expect(outcome.warnings.single, contains('not 16 KB-aligned'));
      expect(loadAlign(file.readAsBytesSync(), 1, true), 0x4000);
    });
  });

  group('ELF32', () {
    test('two congruent LOADs are raised to 16 KB', () {
      final image = buildElf(elf64: false, loads: [
        (0, 0, 0x1000),
        (0xa3c000, 0xa3c000, 0x1000),
      ]);
      final file = writeSo(image);

      final outcome = patcher.patchFile(file);

      expect(outcome.error, isNull);
      expect(outcome.patched, isTrue);
      final patched = file.readAsBytesSync();
      expect(loadAlign(patched, 0, false), 0x4000);
      expect(loadAlign(patched, 1, false), 0x4000);
    });

    test('non-congruent LOAD fails loudly', () {
      final image = buildElf(elf64: false, loads: [
        (0x2000, 0x3000, 0x1000),
      ]);
      final file = writeSo(image);

      final outcome = patcher.patchFile(file);

      expect(outcome.patched, isFalse);
      expect(outcome.error, contains('congruence'));
      expect(file.readAsBytesSync(), image);
    });
  });

  group('robustness', () {
    test('non-ELF file fails with a clean error', () {
      final file = writeSo(Uint8List.fromList(List.filled(300, 0x55)));

      final outcome = patcher.patchFile(file);

      expect(outcome.patched, isFalse);
      expect(outcome.error, contains('ELF'));
    });

    test('truncated program header table fails with a clean error', () {
      final image = buildElf(elf64: true, loads: [(0, 0, 0x1000)]);
      final file = writeSo(image.sublist(0, image.length - 40));

      final outcome = patcher.patchFile(file);

      expect(outcome.patched, isFalse);
      expect(outcome.error, isNotNull);
    });

    test('big-endian image fails with a clean error', () {
      final image = buildElf(elf64: true, loads: [(0, 0, 0x1000)]);
      image[5] = 2; // EI_DATA = MSB
      final file = writeSo(image);

      final outcome = patcher.patchFile(file);

      expect(outcome.patched, isFalse);
      expect(outcome.error, contains('endian'));
    });
  });

  group('directory scan', () {
    test('patches every .so under a directory tree, skips other files', () {
      writeSo(
        buildElf(elf64: true, loads: [(0, 0, 0x1000)]),
        name: 'lib/arm64-v8a/libQnnHtpV73Skel.so',
      );
      writeSo(
        buildElf(elf64: true, loads: [(0, 0, 0x1000)]),
        name: 'lib/arm64-v8a/libQnnHtpV75Skel.so',
      );
      writeSo(
        Uint8List.fromList(List.filled(64, 0x1)),
        name: 'lib/arm64-v8a/notes.txt',
      );
      Directory('${tempDir.path}/empty').createSync();

      final outcomes = patcher.patchPath(tempDir.path);

      expect(outcomes, hasLength(2));
      expect(outcomes.every((o) => o.patched), isTrue);
      for (final outcome in outcomes) {
        expect(
          loadAlign(File(outcome.path).readAsBytesSync(), 0, true),
          0x4000,
        );
      }
    });

    test('a failing file is reported but does not stop the scan', () {
      writeSo(
        buildElf(elf64: true, loads: [(0, 0, 0x1000)]),
        name: 'liba.so',
      );
      writeSo(
        buildElf(elf64: true, loads: [(0x1000, 0x2000, 0x1000)]),
        name: 'libb.so',
      );

      final outcomes = patcher.patchPath(tempDir.path);

      expect(outcomes, hasLength(2));
      expect(outcomes.firstWhere((o) => o.path.endsWith('liba.so')).patched,
          isTrue);
      final bad = outcomes.firstWhere((o) => o.path.endsWith('libb.so'));
      expect(bad.patched, isFalse);
      expect(bad.error, isNotNull);
    });

    test('missing path fails with a clean error', () {
      final outcomes = patcher.patchPath('${tempDir.path}/does-not-exist');
      expect(outcomes, hasLength(1));
      expect(outcomes.single.error, isNotNull);
    });
  });
}

/// Byte offsets of the 8-byte p_align field of the two LOAD program headers
/// in the synthetic ELF64 image (header 64 bytes, one PT_DYNAMIC phdr first).
bool _isAlignField64(int offset) {
  const ehdrSize = 64;
  const phentsize = 56;
  for (final index in [1, 2]) {
    final base = ehdrSize + index * phentsize;
    if (offset >= base + 48 && offset < base + 56) return true;
  }
  return false;
}
