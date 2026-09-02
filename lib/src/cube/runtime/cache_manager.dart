/// Content-addressed cache management for cubes.
///
/// [CubeCacheManager] snapshots the cube's cache directories (from
/// [CubeCachePolicy.paths]) into a per-spec cache root keyed by an md5 of
/// the spec's canonical form, so two runs of the same cube share caches
/// while any spec change (one new tool, one extra path) forks the cache.
///
/// Everything is best-effort and built purely on [ExecutionEnv] — no
/// `dart:io`: any failed copy or read is silently skipped, never thrown.
/// A partially restored cache beats a crashed run.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../config/cube_spec.dart';
import '../config/fs_policy.dart';
import '../../env/execution_env.dart';

/// The content-addressed spec key: 10 hex chars of the md5 over the spec's
/// [CubeSpec.toCanonicalMap] JSON. Shared by the cache root
/// (`cube-cache/<key>`) and the kernel profile staging path
/// (`cube-profiles/<key>.sb`).
String cubeSpecCacheKey(CubeSpec spec) => md5
    .convert(utf8.encode(jsonEncode(spec.toCanonicalMap())))
    .toString()
    .substring(0, 10);

/// Saves, restores and clears a cube's cache directories.
final class CubeCacheManager {
  /// Creates a manager operating on [env] under the cache policy of [spec].
  CubeCacheManager(this._env, this.spec);

  final ExecutionEnv _env;

  /// The cube spec whose cache (and workspace, for path mapping) applies.
  final CubeSpec spec;

  /// The content-addressed cache key ([cubeSpecCacheKey] of the spec).
  String get cacheKey => _key ??= cubeSpecCacheKey(spec);

  String? _key;

  /// The cache directory for this spec: `<cwd>/.fah/cube-cache/<key>`.
  String get cacheRoot => '${_env.cwd}/.fah/cube-cache/$cacheKey';

  /// Restores the cached trees into their live locations when a fresh
  /// cache exists, it is not expired, and [CubeCachePolicy.restore] is on.
  ///
  /// A no-op when caching is disabled, no manifest exists yet, the entry's
  /// ttl has expired (the stale entry is then cleared), or restore is off
  /// (saving still works). Best-effort: restore stops at the first copy
  /// error per path, silently.
  Future<void> restoreIfNeeded() async {
    if (!spec.cache.enabled) return;
    final manifest = await _manifest;
    if (manifest == null) return;
    final createdAtMs = manifest['createdAtMs'];
    final ttlMs = manifest['ttlMs'];
    if (createdAtMs is int &&
        ttlMs is int &&
        DateTime.now().millisecondsSinceEpoch > createdAtMs + ttlMs) {
      await clear();
      return;
    }
    if (!spec.cache.restore) return;
    for (final path in spec.cache.paths) {
      final relative = _mirrorRelative(path);
      await _copyTree('$cacheRoot/cache/$relative', '${_env.cwd}/$relative');
    }
  }

  /// Snapshots the live cache paths into the cache root and writes a fresh
  /// manifest.
  ///
  /// A no-op when caching is disabled. Best-effort: paths that cannot be
  /// read are skipped silently. Honors [CubeResourceLimits.diskBytes] by
  /// pruning the oldest sibling cache entries until the total fits.
  Future<void> save() async {
    if (!spec.cache.enabled) return;
    await _env.remove('$cacheRoot/cache', recursive: true, force: true);
    for (final path in spec.cache.paths) {
      final relative = _mirrorRelative(path);
      await _copyTree('${_env.cwd}/$relative', '$cacheRoot/cache/$relative');
    }
    final ttl = spec.cache.ttl;
    await _env.writeFile(
      '$cacheRoot/manifest.json',
      jsonEncode({
        'key': cacheKey,
        'name': spec.name,
        'createdAtMs': DateTime.now().millisecondsSinceEpoch,
        if (ttl != null) 'ttlMs': ttl.inMilliseconds,
        'paths': spec.cache.paths,
      }),
    );
    await _pruneToBound();
  }

  /// Removes this spec's whole cache entry.
  Future<void> clear() => _env.remove(cacheRoot, recursive: true, force: true);

  /// The parsed manifest, or `null` when absent or unreadable.
  Future<Map<Object?, Object?>?> get _manifest async {
    final text = await _env.readTextFile('$cacheRoot/manifest.json');
    if (text.isErr) return null;
    final decoded = jsonDecode(text.getOrThrow());
    return decoded is Map ? decoded : null;
  }

  /// Maps a cube cache path to its location relative to the env cwd: a path
  /// under the spec workspace maps positionally onto the realized workspace
  /// ([resolveWorkspacePath] with the env cwd as the root —
  /// `/workspace/.cache` becomes `.cache`), anything outside the workspace
  /// lands by basename (`.m2` in the cube stays `.m2` here).
  ///
  // ponytail: basename fallback flattens — two outside paths sharing a
  // basename (`/etc/.m2`, `/opt/.m2`) mirror into one directory; per-path
  // subdirs if that ever collides in practice.
  String _mirrorRelative(String cubePath) {
    final realized = resolveWorkspacePath(
      cubePath,
      spec.filesystem.workspace,
      _env.cwd,
    );
    if (realized != null && realized.length > _env.cwd.length) {
      return realized.substring(_env.cwd.length + 1);
    }
    final segments = [
      for (final segment in cubePath.split('/'))
        if (segment.isNotEmpty) segment,
    ];
    return segments.isEmpty ? '' : segments.last;
  }

  /// Recursively copies [from] to [to] (files only, parents created).
  /// Every error is swallowed — best-effort by contract.
  Future<void> _copyTree(String from, String to) async {
    final info = await _env.fileInfo(from);
    if (info.isErr) return;
    final node = info.getOrThrow();
    if (node.kind != FileKind.directory) {
      final bytes = await _env.readBinaryFile(from);
      if (bytes.isOk) await _env.writeBinaryFile(to, bytes.getOrThrow());
      return;
    }
    final children = await _env.listDir(from);
    if (children.isErr) return;
    await _env.createDir(to, recursive: true);
    for (final child in children.getOrThrow()) {
      await _copyTree(child.path, '$to/${child.name}');
    }
  }

  /// Prunes oldest sibling entries under `.fah/cube-cache/` until the total
  /// fits [CubeResourceLimits.diskBytes].
  ///
  // ponytail: coarse ratchet over whole entries; a per-file quota is a
  // kernel-backend-phase concern.
  Future<void> _pruneToBound() async {
    final bound = spec.resources.diskBytes;
    if (bound == null) return;
    final base = '${_env.cwd}/.fah/cube-cache';
    final listing = await _env.listDir(base);
    if (listing.isErr) return;
    final entries = [
      for (final entry in listing.getOrThrow())
        if (entry.kind == FileKind.directory) entry,
    ]..sort((a, b) => a.mtimeMs.compareTo(b.mtimeMs));
    final sizes = <String, int>{};
    var total = 0;
    for (final entry in entries) {
      final size = await _treeSize(entry.path);
      sizes[entry.path] = size;
      total += size;
    }
    for (final entry in entries) {
      if (total <= bound) return;
      if (entry.path == cacheRoot) continue; // keep the entry just saved
      await _env.remove(entry.path, recursive: true, force: true);
      total -= sizes[entry.path] ?? 0;
    }
  }

  /// Recursively sums the file sizes under [path]; 0 on any error.
  Future<int> _treeSize(String path) async {
    final info = await _env.fileInfo(path);
    if (info.isErr) return 0;
    final node = info.getOrThrow();
    if (node.kind != FileKind.directory) return node.size;
    final children = await _env.listDir(path);
    if (children.isErr) return 0;
    var total = 0;
    for (final child in children.getOrThrow()) {
      total += await _treeSize(child.path);
    }
    return total;
  }
}
