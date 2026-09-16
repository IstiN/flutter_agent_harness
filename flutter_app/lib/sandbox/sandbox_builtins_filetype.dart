// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of sandbox_builtins.dart: file(1)-style magic-byte detection used by
// the archive/text description builtins. Same library, private members resolve.

part of 'sandbox_builtins.dart';

// ---------------------------------------------------------------------------
// file(1) magic helpers
// ---------------------------------------------------------------------------

/// Whether [bytes] starts with [magic].
bool _hasPrefix(List<int> bytes, List<int> magic) =>
    _hasMagicAt(bytes, 0, magic);

/// Whether [bytes] carries [magic] at [offset].
bool _hasMagicAt(List<int> bytes, int offset, List<int> magic) {
  if (bytes.length < offset + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[offset + i] != magic[i]) return false;
  }
  return true;
}

/// Throws a [FormatException] unless [bytes] starts with [magic]. The
/// `package:archive` XZ/bzip2 decoders fail silently on malformed input
/// (their error reporting is commented out upstream), so decompression
/// validates the signature itself before decoding.
void _requireMagic(List<int> bytes, List<int> magic) {
  if (!_hasPrefix(bytes, magic)) {
    throw const FormatException('unexpected file signature');
  }
}

/// Describes compressed/archive payloads: wasm, zip, gzip, xz, bzip2.
String? _describeCompressedBytes(List<int> bytes) {
  if (_hasPrefix(bytes, const [0x00, 0x61, 0x73, 0x6d])) {
    // The wasm version is a little-endian uint32 at offset 4 (1 = MVP).
    if (bytes.length >= 8) {
      final version =
          bytes[4] +
          bytes[5] * 0x100 +
          bytes[6] * 0x10000 +
          bytes[7] * 0x1000000;
      return 'WebAssembly (wasm) binary module version 0x$version (MVP)';
    }
    return 'WebAssembly (wasm) binary module';
  }
  if (_hasPrefix(bytes, const [0x50, 0x4b, 0x03, 0x04]) ||
      _hasPrefix(bytes, const [0x50, 0x4b, 0x05, 0x06]) ||
      _hasPrefix(bytes, const [0x50, 0x4b, 0x07, 0x08])) {
    return 'Zip archive data';
  }
  if (_hasPrefix(bytes, const [0x1f, 0x8b])) return 'gzip compressed data';
  if (_hasPrefix(bytes, const [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])) {
    return 'XZ compressed data';
  }
  if (_hasPrefix(bytes, const [0x42, 0x5a, 0x68])) {
    final digit = bytes.length > 3 ? bytes[3] : 0;
    final blockSize = digit >= 0x31 && digit <= 0x39
        ? ', block size = ${digit - 0x30}00k'
        : '';
    return 'bzip2 compressed data$blockSize';
  }
  return null;
}

/// Describes image payloads: PNG, JPEG, GIF, WebP.
String? _describeImageBytes(List<int> bytes) {
  if (_hasPrefix(bytes, const [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ])) {
    return 'PNG image data';
  }
  if (_hasPrefix(bytes, const [0xff, 0xd8, 0xff])) return 'JPEG image data';
  if (_hasPrefix(bytes, 'GIF87a'.codeUnits)) {
    return 'GIF image data, version 87a';
  }
  if (_hasPrefix(bytes, 'GIF89a'.codeUnits)) {
    return 'GIF image data, version 89a';
  }
  if (_hasPrefix(bytes, 'RIFF'.codeUnits) &&
      _hasMagicAt(bytes, 8, 'WEBP'.codeUnits)) {
    return 'RIFF (little-endian) data, Web/P image';
  }
  return null;
}

/// Describes executable payloads: ELF and the Mach-O variants.
String? _describeExecutableBytes(List<int> bytes) {
  if (_hasPrefix(bytes, const [0x7f, 0x45, 0x4c, 0x46])) {
    if (bytes.length < 6) return 'ELF executable';
    final bits = bytes[4] == 1 ? '32-bit' : '64-bit';
    final endian = bytes[5] == 2 ? 'MSB' : 'LSB';
    return 'ELF $bits $endian executable';
  }
  if (_hasPrefix(bytes, const [0xfe, 0xed, 0xfa, 0xce]) ||
      _hasPrefix(bytes, const [0xce, 0xfa, 0xed, 0xfe])) {
    return 'Mach-O 32-bit executable';
  }
  if (_hasPrefix(bytes, const [0xfe, 0xed, 0xfa, 0xcf]) ||
      _hasPrefix(bytes, const [0xcf, 0xfa, 0xed, 0xfe])) {
    return 'Mach-O 64-bit executable';
  }
  if (_hasPrefix(bytes, const [0xca, 0xfe, 0xba, 0xbe])) {
    return 'Mach-O universal binary';
  }
  return null;
}

/// Classifies [bytes] BSD-file style by magic-number matching; the subset
/// covers the formats the sandbox can produce or consume. Falls back to
/// text detection and finally `data`.
String _describeBytes(List<int> bytes) {
  if (bytes.isEmpty) return 'empty';
  final compressed = _describeCompressedBytes(bytes);
  if (compressed != null) return compressed;
  final image = _describeImageBytes(bytes);
  if (image != null) return image;
  if (_hasPrefix(bytes, '%PDF-'.codeUnits)) return 'PDF document';
  if (_hasPrefix(bytes, 'SQLite format 3\x00'.codeUnits)) {
    return 'SQLite 3.x database';
  }
  if (_hasMagicAt(bytes, 257, 'ustar'.codeUnits)) return 'POSIX tar archive';
  final executable = _describeExecutableBytes(bytes);
  if (executable != null) return executable;
  if (_isUtf8Text(bytes)) {
    return bytes.every((b) => b < 0x80) ? 'ASCII text' : 'UTF-8 Unicode text';
  }
  return 'data';
}

/// Whether [bytes] decode as UTF-8 without control characters other than
/// the common whitespace ones (tab, LF, CR, FF).
bool _isUtf8Text(List<int> bytes) {
  try {
    utf8.decode(bytes);
  } on FormatException {
    return false;
  }
  for (final b in bytes) {
    if (b < 0x20 && b != 0x09 && b != 0x0a && b != 0x0d && b != 0x0c) {
      return false;
    }
    if (b == 0x7f) return false;
  }
  return true;
}
