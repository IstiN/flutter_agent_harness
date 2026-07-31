/// Archive inner-path reads for the `read` tool, ported from oh-my-pi
/// `packages/coding-agent/src/utils/zip.ts` (reduced to the read path):
/// `archive.ext:inner/entry` resolves a member of a `.zip`, `.tar`, or
/// `.tar.gz`/`.tgz` container and runs it through the same text pipeline as
/// a regular file (line selectors apply after extraction).
///
/// Backed by `package:archive` (pure Dart, web-safe). Unlike omp — which
/// indexes ZIPs through ranged central-directory reads — the whole archive
/// is decoded in memory, so the on-disk size is capped at
/// [maxArchiveBytes] and a single member's declared (uncompressed) size at
/// [maxArchiveMemberBytes].
///
/// Deliberate deviations from omp: the JVM/Android ZIP aliases (`.jar`,
/// `.war`, `.ear`, `.apk`) are not recognized, and member timestamps are not
/// surfaced (listings show name + size only, like omp).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Cap on the on-disk size of an archive read into memory for indexing
/// (omp's MAX_TAR_ARCHIVE_BYTES, applied to every format here because all
/// decoding is in-memory).
const maxArchiveBytes = 256 * 1024 * 1024;

/// Cap on a single archive member's declared (uncompressed) size — the
/// declared size is attacker-controlled metadata (omp's
/// MAX_ARCHIVE_MEMBER_BYTES).
const maxArchiveMemberBytes = 64 * 1024 * 1024;

/// Recognized archive containers.
enum ArchiveFormat { zip, tar, tarGz }

/// Regex alternation of every recognized archive extension, longest first so
/// `.tar.gz` wins over `.tar` (omp's ARCHIVE_EXTENSION_ALTERNATION, minus the
/// ZIP aliases).
const _archiveExtensionAlternation = 'tar\\.gz|tgz|zip|tar';

/// Infers the archive format from a filesystem path's extension (omp's
/// `archiveFormatFromPath`).
ArchiveFormat? archiveFormatFromPath(String filePath) {
  final normalized = filePath.toLowerCase();
  if (normalized.endsWith('.tar.gz') || normalized.endsWith('.tgz')) {
    return ArchiveFormat.tarGz;
  }
  if (normalized.endsWith('.tar')) return ArchiveFormat.tar;
  if (normalized.endsWith('.zip')) return ArchiveFormat.zip;
  return null;
}

/// One `{archivePath, subPath}` split of an `archive.ext:inner/path`
/// reference (omp's ArchivePathCandidate).
final class ArchivePathCandidate {
  /// Creates a candidate.
  const ArchivePathCandidate(this.archivePath, this.subPath);

  /// Path to the archive file itself.
  final String archivePath;

  /// Member path inside the archive (may itself carry a trailing selector).
  final String subPath;
}

final _archivePathPattern = RegExp(
  '\\.(?:$_archiveExtensionAlternation)(?=(?::|\$))',
  caseSensitive: false,
);

/// Splits an `archive.ext:inner/path` reference into every plausible
/// `{archivePath, subPath}` pair, longest archive prefix first. A path may
/// contain more than one archive extension, so each candidate is a guess at
/// where the archive ends and the member portion begins (omp's
/// `parseArchivePathCandidates`).
List<ArchivePathCandidate> parseArchivePathCandidates(String filePath) {
  final normalized = filePath.replaceAll('\\', '/');
  final seen = <String>{};
  final candidates = <ArchivePathCandidate>[];
  for (final match in _archivePathPattern.allMatches(normalized)) {
    final end = match.end;
    final archivePath = filePath.substring(0, end);
    final subPath = normalized.substring(end).replaceFirst(RegExp('^:+'), '');
    final key = '$archivePath\x00$subPath';
    if (!seen.add(key)) continue;
    candidates.add(ArchivePathCandidate(archivePath, subPath));
  }
  candidates.sort(
    (a, b) => b.archivePath.length.compareTo(a.archivePath.length),
  );
  return candidates;
}

/// Normalizes a member lookup path: `/` separators, `.` segments dropped.
/// Returns null when the path escapes via `..` (omp's
/// `normalizeArchiveLookupPath`).
String? normalizeArchiveLookupPath(String? rawPath) {
  if (rawPath == null || rawPath.isEmpty) return '';
  final segments = rawPath.replaceAll('\\', '/').split('/');
  final normalizedSegments = <String>[];
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') return null;
    normalizedSegments.add(segment);
  }
  return normalizedSegments.join('/');
}

/// Normalizes an entry name from an archive index. Returns null for names
/// that escape via `..` or normalize to nothing (omp's
/// `normalizeArchiveEntryPath`).
String? _normalizeArchiveEntryPath(String rawPath) {
  final normalized = normalizeArchiveLookupPath(rawPath);
  if (normalized == null || normalized.isEmpty) return null;
  return normalized;
}

/// Metadata for one archive node (omp's ArchiveNode).
final class ArchiveNode {
  /// Creates a node.
  const ArchiveNode({
    required this.path,
    required this.isDirectory,
    required this.size,
  });

  /// Normalized full path inside the archive.
  final String path;

  /// Whether this node is a directory.
  final bool isDirectory;

  /// Uncompressed size in bytes (0 for directories).
  final int size;
}

/// A direct child of an archive directory (omp's ArchiveDirectoryEntry).
final class ArchiveDirectoryEntry extends ArchiveNode {
  /// Creates a directory entry.
  const ArchiveDirectoryEntry({
    required super.path,
    required super.isDirectory,
    required super.size,
    required this.name,
  });

  /// Basename within the listed directory.
  final String name;
}

final class _IndexEntry extends ArchiveNode {
  _IndexEntry({
    required super.path,
    required super.isDirectory,
    required super.size,
    this.file,
  });

  /// Backing [ArchiveFile] for lazy content access (null for directories).
  final ArchiveFile? file;
}

void _upsertArchiveEntry(Map<String, _IndexEntry> map, _IndexEntry entry) {
  final existing = map[entry.path];
  if (existing == null) {
    map[entry.path] = entry;
    return;
  }
  if (existing.isDirectory && !entry.isDirectory) {
    map[entry.path] = entry;
    return;
  }
  if (!existing.isDirectory && entry.isDirectory) return;
  map[entry.path] = _IndexEntry(
    path: entry.path,
    isDirectory: entry.isDirectory,
    size: existing.size != 0 ? existing.size : entry.size,
    file: existing.file ?? entry.file,
  );
}

void _ensureParentDirectories(Map<String, _IndexEntry> map) {
  for (final entry in map.values.toList()) {
    final parts = entry.path.split('/');
    for (var index = 1; index < parts.length; index++) {
      final dirPath = parts.sublist(0, index).join('/');
      if (dirPath.isEmpty || map.containsKey(dirPath)) continue;
      map[dirPath] = _IndexEntry(path: dirPath, isDirectory: true, size: 0);
    }
  }
}

/// An indexed, read-only view over a single archive (omp's ArchiveReader,
/// reduced to read/list). Decoding happens up front in [ArchiveReader.decode]
/// via `package:archive`; member bytes are inflated on demand by
/// [readFileBytes].
final class ArchiveReader {
  ArchiveReader._(this.format, List<_IndexEntry> entries) {
    for (final entry in entries) {
      _upsertArchiveEntry(_entries, entry);
    }
    _ensureParentDirectories(_entries);
  }

  /// Decodes [bytes] as [format] into an indexed reader. Throws [StateError]
  /// when the archive exceeds [maxArchiveBytes] or fails to decode.
  factory ArchiveReader.decode(Uint8List bytes, ArchiveFormat format) {
    if (bytes.length > maxArchiveBytes) {
      throw StateError(
        'Archive is too large to read in memory '
        '(${bytes.length} bytes > $maxArchiveBytes byte limit)',
      );
    }
    // ZipDecoder is lenient with garbage input (it yields an empty archive);
    // every real ZIP — even an empty one — starts with a PK record
    // signature, so reject non-ZIP bytes up front (omp's framing rejects a
    // missing end-of-central-directory record the same way).
    if (format == ArchiveFormat.zip &&
        (bytes.length < 2 || bytes[0] != 0x50 || bytes[1] != 0x4B)) {
      throw StateError('Cannot read archive: not a ZIP file');
    }
    final Archive decoded;
    try {
      decoded = switch (format) {
        ArchiveFormat.zip => ZipDecoder().decodeBytes(bytes),
        ArchiveFormat.tar => TarDecoder().decodeBytes(bytes),
        ArchiveFormat.tarGz => TarDecoder().decodeBytes(
          GZipDecoder().decodeBytes(bytes),
        ),
      };
    } on Object catch (error) {
      throw StateError('Cannot read archive: $error');
    }

    final entries = <_IndexEntry>[];
    for (final file in decoded.files) {
      final normalizedPath = _normalizeArchiveEntryPath(file.name);
      if (normalizedPath == null) continue;
      final isDirectory =
          !file.isFile || file.name.endsWith('/') || file.name.endsWith('\\');
      entries.add(
        _IndexEntry(
          path: normalizedPath,
          isDirectory: isDirectory,
          size: isDirectory ? 0 : file.size,
          file: isDirectory ? null : file,
        ),
      );
    }
    return ArchiveReader._(format, entries);
  }

  /// The container format.
  final ArchiveFormat format;

  final Map<String, _IndexEntry> _entries = {};

  /// Looks up [subPath] (normalized); null/empty addresses the root.
  ArchiveNode? getNode(String? subPath) {
    final normalizedPath = normalizeArchiveLookupPath(subPath);
    if (normalizedPath == null) return null;
    if (normalizedPath.isEmpty) {
      return const ArchiveNode(path: '', isDirectory: true, size: 0);
    }
    final entry = _entries[normalizedPath];
    if (entry == null) return null;
    return ArchiveNode(
      path: entry.path,
      isDirectory: entry.isDirectory,
      size: entry.size,
    );
  }

  /// Lists the immediate children of [subPath] (omp's `listDirectory`):
  /// throws when the path escapes via `..`, is missing, or is not a
  /// directory. Entries keep archive index order.
  List<ArchiveDirectoryEntry> listDirectory(String? subPath) {
    final normalizedPath = normalizeArchiveLookupPath(subPath);
    if (normalizedPath == null) {
      throw StateError("Archive path cannot contain '..'");
    }
    _requireDirectory(normalizedPath);

    final prefix = normalizedPath.isEmpty ? '' : '$normalizedPath/';
    final children = <String, ArchiveDirectoryEntry>{};
    for (final entry in _entries.values) {
      final child = _childEntry(entry, prefix);
      if (child == null) continue;
      children[child.path] = child;
    }
    return children.values.toList();
  }

  /// Throws when [normalizedPath] names a missing or non-directory node.
  void _requireDirectory(String normalizedPath) {
    if (normalizedPath.isEmpty) return;
    final entry = _entries[normalizedPath];
    if (entry == null) {
      throw StateError("Archive path '$normalizedPath' not found");
    }
    if (!entry.isDirectory) {
      throw StateError("Archive path '$normalizedPath' is not a directory");
    }
  }

  /// [entry] as a direct child of the directory addressed by [prefix], or
  /// null when the entry lies outside it or deeper than one level.
  ArchiveDirectoryEntry? _childEntry(_IndexEntry entry, String prefix) {
    if (prefix.isNotEmpty && !entry.path.startsWith(prefix)) return null;
    final remainder = entry.path.substring(prefix.length);
    if (remainder.isEmpty || remainder.contains('/')) return null;
    return ArchiveDirectoryEntry(
      path: entry.path,
      isDirectory: entry.isDirectory,
      size: entry.size,
      name: remainder,
    );
  }

  /// Reads the (inflated) bytes of a file member. Throws when the member is
  /// missing, a directory, or exceeds [maxArchiveMemberBytes] declared.
  Uint8List readFileBytes(String subPath) {
    final normalizedPath = normalizeArchiveLookupPath(subPath);
    if (normalizedPath == null) {
      throw StateError("Archive path cannot contain '..'");
    }
    final entry = _entries[normalizedPath];
    if (entry == null) {
      throw StateError("Archive path '$normalizedPath' not found");
    }
    if (entry.isDirectory) {
      throw StateError("Archive path '$normalizedPath' is a directory");
    }
    if (entry.size > maxArchiveMemberBytes) {
      throw StateError(
        "Archive entry '$normalizedPath' is too large to read "
        '(${entry.size} bytes > $maxArchiveMemberBytes byte limit)',
      );
    }
    final content = entry.file!.content;
    return content;
  }
}

/// Decodes [bytes] as strict UTF-8 text, or returns null for binary content
/// (omp's `decodeUtf8Text`: NUL bytes or malformed UTF-8 mark binary).
String? decodeUtf8Text(Uint8List bytes) {
  if (bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on Object {
    return null;
  }
}
