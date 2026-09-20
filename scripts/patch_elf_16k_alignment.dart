/// Patches ELF shared libraries in place for 16 KB memory-page support
/// (gh-746: Play "Your app does not support 16 KB memory page sizes").
///
/// Some prebuilt Android `.so` blobs — today the Qualcomm QNN HTP `Skel`
/// libraries that flutter_gemma's LiteRT-LM native assets bundle ships —
/// are linked with a 4 KB max page size, so their PT_LOAD program headers
/// carry `p_align = 0x1000`. Google Play rejects uploads containing such
/// libraries, and 16 KB-page devices cannot map them in place.
///
/// When every LOAD segment is already 16 KB-congruent (`p_offset` and
/// `p_vaddr - p_offset` are multiples of 0x4000), raising `p_align` to
/// 0x4000 produces exactly the binary a `-z max-page-size=16384` relink
/// would — the mmap alignment contract is unchanged, only the declared
/// page size grows — so for those blobs we patch the ELF program headers
/// in place instead of relinking proprietary binaries we cannot rebuild.
///
/// A blob that fails the congruence check genuinely needs a real relink;
/// writing a bigger `p_align` there would produce an unloadable binary, so
/// such files are reported loudly and the tool exits non-zero.
///
/// Usage:
///
/// ```sh
/// dart scripts/patch_elf_16k_alignment.dart <file-or-dir>...
/// ```
///
/// Directories are scanned recursively for `*.so` files. Exit code is 0
/// when every scanned file is (or became) 16 KB-aligned; 1 otherwise.
library;

import 'dart:io';
import 'dart:typed_data';

/// The page size Google Play requires native libraries to declare.
const requiredPageAlignment = 0x4000; // 16 KB

const _ptLoad = 1;
const _page16k = 0x4000;

/// Per-file result of a patch run.
final class PatchOutcome {
  /// Absolute path of the scanned file.
  final String path;

  /// `p_align` was raised to 16 KB (the file was modified).
  final bool patched;

  /// Every LOAD segment already declared a 16 KB-compatible alignment and
  /// the file was left untouched.
  final bool alreadyAligned;

  /// Why the file could not be patched (not an ELF image, truncated,
  /// unsupported layout, or LOAD segments that are not 16 KB-congruent).
  /// Null on success.
  final String? error;

  const PatchOutcome({
    required this.path,
    required this.patched,
    required this.alreadyAligned,
    this.error,
  });

  @override
  String toString() => error != null
      ? 'FAIL  $path: $error'
      : patched
          ? 'PATCH $path (p_align -> 0x$_page16kHex)'
          : 'OK    $path (already 16 KB-aligned)';

  static const _page16kHex = '4000';
}

/// Patch a single ELF file in place. Never throws — malformed or
/// non-congruent files come back as a [PatchOutcome] with [PatchOutcome.error]
/// set and their bytes untouched.
PatchOutcome patchFile(File file) {
  final path = file.absolute.path;
  try {
    final image = file.readAsBytesSync();
    final loads = _loadSegments(image);
    if (loads == null) {
      return PatchOutcome(
        path: path,
        patched: false,
        alreadyAligned: false,
        error: 'not a little-endian ELF image',
      );
    }
    if (loads.isEmpty) {
      // No PT_LOAD segments (e.g. a core dump or relocatable) — nothing to
      // align, nothing Play would flag either.
      return PatchOutcome(path: path, patched: false, alreadyAligned: true);
    }

    final needsPatch = loads.any((l) => l.align % _page16k != 0);
    if (!needsPatch) {
      return PatchOutcome(path: path, patched: false, alreadyAligned: true);
    }

    // Raising p_align is only loadable when every segment can actually be
    // mapped at 16 KB granularity.
    final incongruent = loads.where(
      (l) =>
          l.offset % _page16k != 0 || (l.vaddr - l.offset) % _page16k != 0,
    );
    if (incongruent.isNotEmpty) {
      final l = incongruent.first;
      return PatchOutcome(
        path: path,
        patched: false,
        alreadyAligned: false,
        error:
            'LOAD segment at file offset 0x${l.offset.toRadixString(16)} is '
            'not 16 KB-congruent (p_vaddr - p_offset = '
            '0x${(l.vaddr - l.offset).toRadixString(16)}) — needs a real '
            'relink with -Wl,-z,max-page-size=16384, refusing to patch',
      );
    }

    // Rewrite p_align for every LOAD segment (congruent ones may declare
    // anything ≥ 0x4000 already; keep them and only lift the sub-16 KB ones)
    // and write the image back in one shot — dart:io has no non-truncating
    // write-only open mode, so in-memory edit + full overwrite it is (the
    // file length is unchanged either way).
    final bd = ByteData.sublistView(image);
    for (final l in loads) {
      if (l.align % _page16k == 0) continue;
      if (l.alignIs64Bit) {
        bd.setUint64(l.alignOffset, _page16k, Endian.little);
      } else {
        bd.setUint32(l.alignOffset, _page16k, Endian.little);
      }
    }
    file.writeAsBytesSync(image);
    return PatchOutcome(path: path, patched: true, alreadyAligned: false);
  } on PathNotFoundException {
    return PatchOutcome(
      path: path,
      patched: false,
      alreadyAligned: false,
      error: 'file not found',
    );
  } on FileSystemException catch (e) {
    return PatchOutcome(
      path: path,
      patched: false,
      alreadyAligned: false,
      error: 'I/O error: ${e.message}',
    );
  }
}

/// Patch every `.so` file under [path] (recursive when it is a directory).
List<PatchOutcome> patchPath(String path) {
  final entity = FileSystemEntity.typeSync(path);
  if (entity == FileSystemEntityType.file) {
    return [patchFile(File(path))];
  }
  if (entity == FileSystemEntityType.directory) {
    final outcomes = <PatchOutcome>[];
    Directory(path)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.so'))
        .map(patchFile)
        .forEach(outcomes.add);
    return outcomes;
  }
  return [
    PatchOutcome(
      path: File(path).absolute.path,
      patched: false,
      alreadyAligned: false,
      error: 'no such file or directory',
    ),
  ];
}

final class _LoadSegment {
  final int offset;
  final int vaddr;
  final int align;

  /// Absolute file offset of the p_align field.
  final int alignOffset;
  final bool alignIs64Bit;

  const _LoadSegment({
    required this.offset,
    required this.vaddr,
    required this.align,
    required this.alignOffset,
    required this.alignIs64Bit,
  });
}

/// Parse PT_LOAD program headers out of a little-endian ELF image.
/// Returns null when [image] is not a supported ELF file.
List<_LoadSegment>? _loadSegments(Uint8List image) {
  if (image.length < 16 ||
      image[0] != 0x7f ||
      image[1] != 0x45 ||
      image[2] != 0x4c ||
      image[3] != 0x46) {
    return null;
  }
  final eiClass = image[4];
  final eiData = image[5];
  if (eiClass != 1 && eiClass != 2) return null;
  if (eiData != 1) return null; // only little-endian images exist on Android
  final elf64 = eiClass == 2;

  final bd = ByteData.sublistView(image);
  final int phoff;
  final int phentsize;
  final int phnum;
  if (elf64) {
    if (image.length < 0x3a) return null;
    phoff = bd.getUint64(0x20, Endian.little);
    phentsize = bd.getUint16(0x36, Endian.little);
    phnum = bd.getUint16(0x38, Endian.little);
  } else {
    if (image.length < 0x2e) return null;
    phoff = bd.getUint32(0x1c, Endian.little);
    phentsize = bd.getUint16(0x2a, Endian.little);
    phnum = bd.getUint16(0x2c, Endian.little);
  }
  final minPhentsize = elf64 ? 56 : 32;
  if (phentsize < minPhentsize) return null;
  if (phnum == 0xffff) {
    return null; // PN_XNUM: real count lives in section headers; not a shape
    // any Android shared library takes.
  }
  if (phoff + phnum * phentsize > image.length) return null;

  final loads = <_LoadSegment>[];
  for (var i = 0; i < phnum; i++) {
    final base = phoff + i * phentsize;
    if (bd.getUint32(base, Endian.little) != _ptLoad) continue;
    if (elf64) {
      loads.add(
        _LoadSegment(
          offset: bd.getUint64(base + 8, Endian.little),
          vaddr: bd.getUint64(base + 16, Endian.little),
          align: bd.getUint64(base + 48, Endian.little),
          alignOffset: base + 48,
          alignIs64Bit: true,
        ),
      );
    } else {
      loads.add(
        _LoadSegment(
          offset: bd.getUint32(base + 4, Endian.little),
          vaddr: bd.getUint32(base + 8, Endian.little),
          align: bd.getUint32(base + 28, Endian.little),
          alignOffset: base + 28,
          alignIs64Bit: false,
        ),
      );
    }
  }
  return loads;
}

/// CLI entry: `dart scripts/patch_elf_16k_alignment.dart <file-or-dir>...`.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart scripts/patch_elf_16k_alignment.dart <file-or-dir>...',
    );
    exitCode = 64;
    return;
  }
  final outcomes = <PatchOutcome>[];
  for (final arg in args) {
    outcomes.addAll(patchPath(arg));
  }
  for (final outcome in outcomes) {
    stdout.writeln(outcome);
  }
  final failed = outcomes.where((o) => o.error != null).length;
  final patched = outcomes.where((o) => o.patched).length;
  stdout.writeln(
    'scanned ${outcomes.length}, patched $patched, failed $failed',
  );
  if (failed > 0) {
    stderr.writeln(
      'patch_elf_16k_alignment: $failed file(s) could not be patched',
    );
    exitCode = 1;
  }
}
