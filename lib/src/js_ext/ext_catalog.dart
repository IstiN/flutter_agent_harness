/// Catalog v2 client for JS extensions: tolerant catalog parsing, a
/// TTL-cached fetcher with stale-on-error fallback, and a verified archive
/// downloader.
///
/// The hostile-zip rules are ported from `flutter_app` `catalog_service`:
/// sha256 verified BEFORE unpacking, exactly one root dir (`<id>/` for
/// catalog archives), no absolute/backslash/`..` entry names, and the archive
/// must contain `manifest.json` and `main.js`. Tampered archives throw
/// [ExtCatalogException] and nothing is ever written.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../env/execution_env.dart';
import '../tools/archive_reader.dart' show decodeUtf8Text;
import 'ext_manifest.dart';

/// Default release-asset base URL the catalog and its zips are served from.
const String kExtCatalogBaseUrl =
    'https://github.com/IstiN/fa_widgets/releases/latest/download/';

/// How long a cached catalog stays fresh before the network is consulted.
const Duration kExtCatalogCacheTtl = Duration(hours: 6);

/// Network or archive failure of the extension catalog client.
class ExtCatalogException implements Exception {
  /// Human-readable failure description.
  final String message;

  /// Creates an exception with [message].
  const ExtCatalogException(this.message);

  @override
  String toString() => 'ExtCatalogException: $message';
}

/// One servable catalog entry.
final class ExtCatalogEntry {
  /// Catalog id (unique per catalog; sorted output guarantees determinism).
  final String id;

  /// Version string.
  final String version;

  /// Optional human description.
  final String? description;

  /// Entry kind; absent in JSON => [ExtKind.widget] (v1 back-compat).
  final ExtKind kind;

  /// Supported platforms; `null` => all platforms.
  final Set<ExtPlatformTag>? platforms;

  /// Flat release-asset file name of the zip artifact.
  final String zipFile;

  /// Hex sha256 over the exact published zip bytes (empty => unverified).
  final String zipSha256;

  /// The raw JSON object the entry was parsed from.
  final Map<String, dynamic> raw;

  /// Creates an entry.
  const ExtCatalogEntry({
    required this.id,
    required this.version,
    this.description,
    required this.kind,
    this.platforms,
    required this.zipFile,
    required this.zipSha256,
    required this.raw,
  });
}

/// A parsed catalog document: schema version plus its entries.
final class ExtCatalog {
  /// Schema version (absent in JSON => 1).
  final int schemaVersion;

  /// Valid entries sorted by id; invalid entries were skipped by the parser.
  final List<ExtCatalogEntry> entries;

  /// Creates a catalog.
  const ExtCatalog({required this.schemaVersion, required this.entries});
}

/// Tolerant catalog parse: entries live under BOTH the v1 `widgets` key and
/// the v2 `extensions` key when present (union). An entry is skipped — never
/// fatal — when its `kind` is unknown or `id`/`version`/`zipFile` are
/// missing/empty. Unknown platform names are dropped from the entry's set.
ExtCatalog parseExtCatalog(Map<String, dynamic> json) {
  final entries = [
    for (final raw in _rawCatalogEntries(json))
      if (raw is Map) ?_catalogEntry(_stringMap(raw)),
  ].whereType<ExtCatalogEntry>().toList()..sort((a, b) => a.id.compareTo(b.id));
  return ExtCatalog(schemaVersion: _schemaVersion(json), entries: entries);
}

int _schemaVersion(Map<String, dynamic> json) {
  final versionValue = json['schemaVersion'];
  return switch (versionValue) {
    null => 1,
    int value => value,
    _ => int.tryParse('$versionValue') ?? 1,
  };
}

/// The union of the v1 `widgets` and v2 `extensions` lists. A non-list
/// value is fatal (schema violation).
List<Object?> _rawCatalogEntries(Map<String, dynamic> json) {
  final rawEntries = <Object?>[];
  for (final key in const ['widgets', 'extensions']) {
    final list = json[key];
    if (list == null) continue;
    if (list is! List) {
      throw ExtCatalogException('catalog "$key" must be a list');
    }
    rawEntries.addAll(list);
  }
  return rawEntries;
}

Map<String, dynamic> _stringMap(Map raw) => {
  for (final entry in raw.entries) '${entry.key}': entry.value,
};

/// One entry, or null when it is skippable: unknown `kind` (the CLI cannot
/// serve it) or missing/empty `id`/`version`/`zipFile`.
ExtCatalogEntry? _catalogEntry(Map<String, dynamic> map) {
  final kindName = map['kind'];
  final kind = kindName == null
      ? ExtKind.widget
      : extKindFromJsonName('$kindName');
  if (kind == null) return null;
  if (_blank(map['id']) || _blank(map['version']) || _blank(map['zipFile'])) {
    return null;
  }
  return ExtCatalogEntry(
    id: map['id'] as String,
    version: map['version'] as String,
    description: map['description'] is String
        ? map['description'] as String
        : null,
    kind: kind,
    platforms: _entryPlatforms(map['platforms']),
    zipFile: map['zipFile'] as String,
    zipSha256: map['zipSha256'] is String ? map['zipSha256'] as String : '',
    raw: map,
  );
}

bool _blank(Object? value) => value is! String || value.isEmpty;

/// The declared platforms; unknown names are dropped, non-lists yield null.
Set<ExtPlatformTag>? _entryPlatforms(Object? platformsValue) {
  if (platformsValue is! List) return null;
  return {
    for (final name in platformsValue)
      if (name is String) ?extPlatformTagFromJsonName(name),
  };
}

/// Fetches the catalog from `<baseUrl>/catalog.json`.
///
/// With both [cachePath] and [env] the parsed document is cached for
/// [kExtCatalogCacheTtl] (`{fetchedAt, catalog}` JSON); [force] skips the
/// freshness check but still rewrites the cache. Any network/parse failure
/// falls back to the cached snapshot when one exists (stale-on-error) and
/// rethrows otherwise.
Future<ExtCatalog> fetchExtCatalog(
  String baseUrl,
  http.Client client, {
  bool force = false,
  String? cachePath,
  ExecutionEnv? env,
}) async {
  final useCache = cachePath != null && env != null;
  if (useCache && !force) {
    final fresh = await _freshCatalog(cachePath, env);
    if (fresh != null) return fresh;
  }

  final (json, failure) = await _fetchCatalogJson(
    '${_joinBase(baseUrl)}catalog.json',
    client,
  );
  if (json != null) {
    if (useCache) await _writeCache(cachePath, env, json);
    return parseExtCatalog(json);
  }
  final stale = await _cachedCatalog(cachePath, env);
  if (stale != null) return stale;
  throw failure!;
}

/// The parsed cached document when it exists and is inside the TTL.
Future<ExtCatalog?> _freshCatalog(String cachePath, ExecutionEnv env) async {
  final cached = await readExtCatalogCache(cachePath, env);
  if (cached == null ||
      DateTime.now().toUtc().difference(cached.$1) >= kExtCatalogCacheTtl) {
    return null;
  }
  return parseExtCatalog(cached.$2);
}

/// The parsed cached document regardless of age (stale-on-error fallback).
Future<ExtCatalog?> _cachedCatalog(String? cachePath, ExecutionEnv? env) async {
  if (cachePath == null || env == null) return null;
  final cached = await readExtCatalogCache(cachePath, env);
  if (cached == null) return null;
  return parseExtCatalog(cached.$2);
}

/// The raw catalog document over the network; failures are returned, not
/// thrown, so the caller can fall back to the cache.
Future<(Map<String, dynamic>?, Object?)> _fetchCatalogJson(
  String url,
  http.Client client,
) async {
  try {
    final response = await client.get(Uri.parse(url));
    if (response.statusCode != 200) {
      return (null, ExtCatalogException('catalog HTTP ${response.statusCode}'));
    }
    return _decodeCatalog(response.bodyBytes);
  } on ExtCatalogException catch (error) {
    return (null, error);
  } on Object catch (error) {
    return (null, ExtCatalogException('catalog fetch failed: $error'));
  }
}

(Map<String, dynamic>?, Object?) _decodeCatalog(Uint8List body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
  } on Object catch (error) {
    return (null, ExtCatalogException('catalog fetch failed: $error'));
  }
  if (decoded is! Map) {
    return (null, const ExtCatalogException('catalog is not a JSON object'));
  }
  return ({for (final e in decoded.entries) '${e.key}': e.value}, null);
}

/// Persists the `{fetchedAt, catalog}` snapshot; a failing cache write must
/// not kill the fetch — the next run simply refetches.
Future<void> _writeCache(
  String cachePath,
  ExecutionEnv env,
  Map<String, dynamic> json,
) async {
  try {
    await env.writeFile(
      cachePath,
      jsonEncode({
        'fetchedAt': DateTime.now().toUtc().toIso8601String(),
        'catalog': json,
      }),
    );
  } on Object {
    // Refetch next time.
  }
}

/// Reads the `{fetchedAt, catalog}` cache file; corrupt/torn caches behave
/// like "no cache".
Future<(DateTime, Map<String, dynamic>)?> readExtCatalogCache(
  String cachePath,
  ExecutionEnv env,
) async {
  final text = (await env.readTextFile(cachePath)).valueOrNull;
  if (text == null) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    final stamp = DateTime.tryParse('${decoded['fetchedAt']}');
    final payload = decoded['catalog'];
    if (stamp == null || payload is! Map) return null;
    return (
      stamp.toUtc(),
      {for (final e in payload.entries) '${e.key}': e.value},
    );
  } on Object {
    return null;
  }
}

/// Downloads one entry's zip, verifies its sha256 (when declared), and
/// returns `{relPath: text}` with the single `<id>/` root dir stripped.
/// Binary entries (icons) are skipped silently — v1 extensions are
/// text-only. Tampered or hostile archives throw [ExtCatalogException];
/// nothing is written.
Future<Map<String, String>> downloadExtZip({
  required String baseUrl,
  required ExtCatalogEntry entry,
  required http.Client client,
}) async {
  if (entry.zipFile.isEmpty || entry.zipFile.contains('/')) {
    throw ExtCatalogException('bad asset name "${entry.zipFile}"');
  }
  final http.Response response;
  try {
    response = await client.get(
      Uri.parse('${_joinBase(baseUrl)}${entry.zipFile}'),
    );
  } on Object catch (error) {
    throw ExtCatalogException('${entry.id} download failed: $error');
  }
  if (response.statusCode != 200) {
    throw ExtCatalogException('${entry.id} HTTP ${response.statusCode}');
  }
  final bytes = response.bodyBytes;
  final digest = sha256.convert(bytes).toString();
  if (entry.zipSha256.isNotEmpty && digest != entry.zipSha256) {
    throw ExtCatalogException('${entry.id} zip sha256 mismatch');
  }
  return extractExtensionZip(
    bytes,
    requiredRoot: '${entry.id}/',
    label: entry.id,
  );
}

/// Extracts TEXT files from an extension archive, enforcing the hostile-zip
/// rules ported from flutter_app `catalog_service.downloadWidget` (plus
/// zip-slip): every entry name is checked for a leading `/`, backslashes,
/// and `..` segments; when [requiredRoot] is given (catalog rule) every file
/// must live under that exact `<dir>/` prefix, which is stripped; otherwise
/// the root is DISCOVERED as the directory of the single `manifest.json`
/// (github/local archives root at `repo-<branch>/`). The stripped result
/// must contain `manifest.json` and `main.js`. Binary (non-UTF-8) entries
/// are skipped silently.
Map<String, String> extractExtensionZip(
  Uint8List bytes, {
  String? requiredRoot,
  required String label,
}) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object catch (error) {
    throw ExtCatalogException('$label: not a valid zip archive: $error');
  }
  final fileEntries = <ArchiveFile>[
    for (final file in archive.files)
      if (file.isFile) file,
  ];
  _validateEntryNames(fileEntries, label);
  final root = requiredRoot ?? _discoverRoot(fileEntries, label);
  final files = <String, String>{};
  for (final file in fileEntries) {
    final name = file.name;
    if (!name.startsWith(root)) {
      throw ExtCatalogException(
        '$label: zip entry outside the $root root: "$name"',
      );
    }
    final relative = name.substring(root.length);
    if (relative.isEmpty) continue;
    final text = decodeUtf8Text(file.content);
    if (text == null) continue; // binary (icons) — v1 is text-only
    files[relative] = text;
  }
  if (!files.containsKey('manifest.json') || !files.containsKey('main.js')) {
    throw ExtCatalogException('$label: archive misses manifest.json/main.js');
  }
  return files;
}

/// Rejects absolute paths, Windows separators, and `..` escapes.
void _validateEntryNames(List<ArchiveFile> fileEntries, String label) {
  for (final file in fileEntries) {
    final name = file.name;
    if (name.startsWith('/') ||
        name.contains('\\') ||
        name.split('/').any((segment) => segment == '..')) {
      throw ExtCatalogException('$label: unsafe zip entry "$name"');
    }
  }
}

/// Finds the root prefix of the single `manifest.json` entry (`''` when it
/// sits at the archive root); ambiguous manifests are rejected.
String _discoverRoot(List<ArchiveFile> entries, String label) {
  final manifests = [
    for (final file in entries)
      if (file.name == 'manifest.json' || file.name.endsWith('/manifest.json'))
        file.name,
  ];
  if (manifests.length != 1) {
    throw ExtCatalogException(
      '$label: expected exactly one manifest.json in archive, '
      'found ${manifests.length}',
    );
  }
  final name = manifests.single;
  final slash = name.lastIndexOf('/');
  return slash < 0 ? '' : name.substring(0, slash + 1);
}

String _joinBase(String baseUrl) =>
    baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
