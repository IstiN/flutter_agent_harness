/// The VM fd-pressure probe (gh-2415): this process's open descriptor
/// count and `RLIMIT_NOFILE` soft limit, for the bash tool's guard.
///
/// The count comes from the kernel's own descriptor directory — `/dev/fd`
/// on macOS (fdescfs), `/proc/self/fd` on Linux — read with raw
/// `opendir`/`readdir` through dart:ffi: one `readdir` per entry, NO
/// per-entry `stat`. Dart's `Directory.listSync` stats every entry, and
/// a descriptor another isolate closes between `readdir` and `stat`
/// fails the WHOLE listing (seen in the full suite: the probe answered
/// null under fd churn). Numeric names only, minus the `opendir`
/// descriptor itself. The limit rides the gh-2415 [FdLimitBackend] (the
/// same `getrlimit` the startup raise used). Null when the platform has
/// no descriptor directory or the read fails: the guard then stays off —
/// honest "no evidence", never a false refusal. Platform glue only,
/// imported behind `fd_pressure_stub.dart` for web.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'fd_limit.dart';
import 'fd_limit_io.dart';
import 'fd_pressure.dart';

FdLimitBackend? _limitBackend;
typedef _DirentReaders = ({
  Pointer<Void> Function(Pointer<Utf8>) opendir,
  Pointer<Uint8> Function(Pointer<Void>) readdir,
  int Function(Pointer<Void>) closedir,
});

/// Where this platform exposes the open descriptor table, or null.
String? get _fdDirectory {
  if (Platform.isMacOS) {
    return Directory('/dev/fd').existsSync() ? '/dev/fd' : null;
  }
  if (Platform.isLinux) {
    return Directory('/proc/self/fd').existsSync() ? '/proc/self/fd' : null;
  }
  return null;
}

/// `d_name`'s offset inside `struct dirent`: 21 on Darwin (`d_ino` 8 +
/// `d_seekoff` 8 + `d_reclen` 2 + `d_type` 1 + `d_namlen` 2) and 19 on
/// Linux glibc/musl, 64-bit (`d_ino` 8 + `d_off` 8 + `d_reclen` 2 +
/// `d_type` 1) — the two hosts this probe supports; verified against the
/// live byte layout, and a wrong offset can only yield non-numeric names
/// (→ null), never a wrong count.
int get _direntNameOffset => Platform.isMacOS ? 21 : 19;

/// The three libc entry points, or null when a symbol is missing.
_DirentReaders? _readers() {
  try {
    final libc = DynamicLibrary.process();
    return (
      opendir: libc
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>)
          >('opendir'),
      readdir: libc
          .lookupFunction<
            Pointer<Uint8> Function(Pointer<Void>),
            Pointer<Uint8> Function(Pointer<Void>)
          >('readdir'),
      closedir: libc
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('closedir'),
    );
  } on Object {
    return null;
  }
}

/// The NUL-terminated `d_name` of one `readdir` result: the bytes from
/// the fixed offset up to the first NUL (ASCII; anything else → '').
String _entryName(Pointer<Uint8> entry) {
  final bytes = <int>[];
  for (var i = _direntNameOffset; i < _direntNameOffset + 256; i++) {
    final byte = (entry + i).value;
    if (byte == 0) break;
    if (byte < 0x20 || byte > 0x7e) return '';
    bytes.add(byte);
  }
  return String.fromCharCodes(bytes);
}

/// The number of descriptors this process has open right now, or null
/// when the platform has no descriptor directory or the read failed.
int? countOpenFds() {
  final dir = _fdDirectory;
  if (dir == null) return null;
  final readers = _readers();
  if (readers == null) return null;
  final path = dir.toNativeUtf8();
  Pointer<Void>? handle;
  var count = 0;
  try {
    handle = readers.opendir(path);
    if (handle == nullptr) return null;
    while (true) {
      final entry = readers.readdir(handle);
      if (entry == nullptr) break;
      final name = _entryName(entry);
      // Numeric names only: '.', '..' and anything foreign never count.
      if (int.tryParse(name) == null) continue;
      count++;
    }
  } on Object {
    return null;
  } finally {
    malloc.free(path);
    final open = handle;
    if (open != null && open != nullptr) readers.closedir(open);
  }
  // The opendir descriptor itself is among the numeric entries; nothing
  // counted at all means the read was not real.
  return count == 0 ? null : count - 1;
}

/// One sample: open count vs the soft limit (0 = no limit / unknown, which
/// never reads as pressure), or null when nothing could be read.
FdPressureSnapshot? defaultFdPressureSnapshot() {
  final open = countOpenFds();
  if (open == null) return null;
  final soft = (_limitBackend ??= systemFdLimitBackend())?.getLimits()?.soft;
  return (open: open, limit: soft == null || soft < 0 ? 0 : soft);
}
