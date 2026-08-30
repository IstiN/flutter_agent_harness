// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

/// Base URL of the fa_widgets rolling release. Asset names from
/// `catalog.json` (`zip.file`, `icon` gallery copy) join against it.
const String kDefaultWidgetsBaseUrl =
    'https://github.com/IstiN/fa_widgets/releases/latest/download/';

/// Raw mirror of the fa_widgets repo (catalog + per-widget sources/icons).
/// raw.githubusercontent.com sends `access-control-allow-origin: *` and
/// serves UTF-8 sources — used for in-app gallery icons and web fetches.
const String kDefaultWidgetsRawBaseUrl =
    'https://raw.githubusercontent.com/IstiN/fa_widgets/main/';

/// How long a fetched catalog stays trusted before the next fetch revalidates.
const Duration kCatalogCacheTtl = Duration(hours: 6);

/// Everything that can go wrong while consuming the widgets catalog:
/// fetch/decode failures, archive hash mismatches, hostile zip layouts.
class CatalogError implements Exception {
  CatalogError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One widget entry of `catalog.json` (schemaVersion 1).
class CatalogEntry {
  CatalogEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.author,
    required this.tags,
    required this.minRuntime,
    required this.iconFile,
    required this.network,
    required this.allowedCommands,
    required this.zipFile,
    required this.zipSha256,
    required this.zipSizeBytes,
  });

  factory CatalogEntry.fromJson(Map<String, dynamic> json) {
    final permissions = json['permissions'];
    final zip = json['zip'];
    return CatalogEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      description: json['description'] as String? ?? '',
      author: json['author'] as String? ?? '',
      tags: [
        for (final tag in (json['tags'] as List? ?? const []))
          if (tag is String) tag,
      ],
      minRuntime: json['minRuntime'] as String? ?? '',
      iconFile: json['icon'] is String ? json['icon'] as String : null,
      network: permissions is Map ? permissions['network'] == true : false,
      allowedCommands: [
        for (final command
            in ((permissions?['allowedCommands'] as List?) ?? const []))
          if (command is String) command,
      ],
      zipFile: zip is Map ? zip['file'] as String? ?? '' : '',
      zipSha256: zip is Map ? zip['sha256'] as String? ?? '' : '',
      zipSizeBytes: zip is Map ? (zip['sizeBytes'] as int? ?? 0) : 0,
    );
  }

  final String id;
  final String name;
  final String version;
  final String description;
  final String author;
  final List<String> tags;

  /// Minimum `js_widget_runtime`; informational (the app pins the package).
  final String minRuntime;

  /// Zip-relative icon file inside the archive; null when absent.
  final String? iconFile;

  /// Declared permissions (all default-denied at runtime regardless).
  final bool network;
  final List<String> allowedCommands;

  /// Flat release-asset name of the zip artifact.
  final String zipFile;

  /// Hex sha256 over the exact published zip bytes.
  final String zipSha256;
  final int zipSizeBytes;

  /// Gallery download URL for this entry's archive.
  Uri get downloadUrl => Uri.parse('$kDefaultWidgetsBaseUrl$zipFile');
}

/// The outcome of a catalog fetch: entries plus how trustworthy they are.
class CatalogFetchResult {
  const CatalogFetchResult({
    required this.entries,
    required this.stale,
    this.error,
  });

  /// Entries sorted by id (the publisher already sorts, but never trust).
  final List<CatalogEntry> entries;

  /// True when a network failure forced a cached snapshot older than its
  /// TTL — UI should show an offline banner while still listing entries.
  final bool stale;

  /// The failure behind [stale], when there was one.
  final Object? error;
}

/// Reads the fa_widgets release catalog and unpacks widget archives into
/// memory for [AppsStore] to install through its ownership-aware path.
///
/// - TTL-cached in `apps/.catalog_cache.json` so launches stay fast and an
///   offline start still renders the last known gallery ([stale] flag).
/// - Archives must contain ONE root folder named `<id>/`; anything escaping
///   it (absolute paths, `..`, foreign roots) aborts with [CatalogError].
/// - Bytes are verified against the catalog's sha256 BEFORE unpacking.
class CatalogService {
  CatalogService(
    this._env, {
    http.Client? httpClient,
    Uri? baseUrl,
    DateTime Function()? clock,
  }) : _client = httpClient ?? http.Client(),
       _baseUrl = baseUrl?.toString() ?? kDefaultWidgetsBaseUrl,
       _clock = clock ?? DateTime.now;

  /// Env-relative cache file (inside the shared `apps/` workspace folder).
  /// `_v2`: v1 caches were written from `response.body`, which the http
  /// package decodes as latin1 when the release asset has no charset —
  /// non-ASCII descriptions ("→", Cyrillic) came out mojibake. The v2 name
  /// purges those poisoned snapshots; decoding now goes through
  /// `utf8.decode(response.bodyBytes)`.
  static const String cacheFile = 'apps/.catalog_cache_v2.json';

  final ExecutionEnv _env;
  final http.Client _client;
  final String _baseUrl;
  final DateTime Function() _clock;

  /// Fetches the catalog, consulting the TTL cache first. [force] skips the
  /// freshness check (the UI's pull-to-refresh). Network failure with a
  /// usable cache yields a [CatalogFetchResult.stale] snapshot; without one
  /// it throws [CatalogError].
  Future<CatalogFetchResult> fetchCatalog({bool force = false}) async {
    if (!force) {
      final cached = await _readCache();
      if (cached != null) {
        final age = _clock().difference(cached.$1);
        if (age < kCatalogCacheTtl) {
          return CatalogFetchResult(entries: cached.$2, stale: false);
        }
      }
    }
    try {
      final response = await _client.get(Uri.parse('$_baseUrl/catalog.json'));
      if (response.statusCode != 200) {
        throw CatalogError('catalog HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw CatalogError('catalog.json is not an object');
      }
      final entries = await _parseEntries(decoded);
      await _writeCache(decoded);
      return CatalogFetchResult(entries: entries, stale: false);
    } on CatalogError catch (error) {
      final cached = await _readCache();
      if (cached != null) {
        return CatalogFetchResult(
          entries: cached.$2,
          stale: true,
          error: error,
        );
      }
      rethrow;
    } on Object catch (error) {
      // Transport-level failure (offline, DNS, timeout…).
      final cached = await _readCache();
      if (cached != null) {
        return CatalogFetchResult(
          entries: cached.$2,
          stale: true,
          error: error,
        );
      }
      throw CatalogError('catalog fetch failed: $error');
    }
  }

  /// Downloads and verifies one widget's archive, returning its files as
  /// `<relative-path> → bytes` WITHOUT the leading `<id>/` root. Refuses to
  /// serve anything whose extraction could escape `apps/<id>/`.
  Future<Map<String, Uint8List>> downloadWidget(CatalogEntry entry) async {
    if (entry.zipFile.isEmpty || entry.zipFile.contains('/')) {
      throw CatalogError('bad asset name "${entry.zipFile}"');
    }
    late Uint8List bytes;
    try {
      final response = await _client.get(entry.downloadUrl);
      if (response.statusCode != 200) {
        throw CatalogError('${entry.id} HTTP ${response.statusCode}');
      }
      bytes = response.bodyBytes;
    } on CatalogError {
      rethrow;
    } on Object catch (error) {
      throw CatalogError('${entry.id} download failed: $error');
    }

    final digest = sha256.convert(bytes).toString();
    if (entry.zipSha256.isNotEmpty && digest != entry.zipSha256) {
      throw CatalogError('${entry.id} zip sha256 mismatch');
    }

    final root = '${entry.id}/';
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, Uint8List>{};
    for (final file in archive.files) {
      if (file.isFile == false) continue;
      final name = file.name;
      if (!name.startsWith(root)) {
        throw CatalogError(
          '${entry.id}: zip entry outside the $root root: "$name"',
        );
      }
      final relative = name.substring(root.length);
      if (relative.isEmpty) continue;
      if (relative.startsWith('/') ||
          relative.contains('\\') ||
          relative.split('/').any((segment) => segment == '..')) {
        throw CatalogError('${entry.id}: unsafe zip entry "$name"');
      }
      files[relative] = Uint8List.fromList(file.content as List<int>);
    }
    if (!files.containsKey('manifest.json') ||
        !files.containsKey('widget.js')) {
      throw CatalogError('${entry.id}: archive misses manifest/widget.js');
    }
    return files;
  }

  Future<List<CatalogEntry>> _parseEntries(Map<String, dynamic> catalog) async {
    final rawWidgets = catalog['widgets'];
    if (rawWidgets is! List) throw CatalogError('catalog has no widgets[]');
    final entries = <CatalogEntry>[];
    for (final raw in rawWidgets) {
      if (raw is! Map<String, dynamic>) continue;
      final entry = CatalogEntry.fromJson(raw);
      if (entry.id.isEmpty || entry.version.isEmpty || entry.zipFile.isEmpty) {
        continue; // malformed entry — skip, never fail the whole gallery
      }
      entries.add(entry);
    }
    entries.sort((a, b) => a.id.compareTo(b.id));
    return entries;
  }

  Future<(DateTime, List<CatalogEntry>)?> _readCache() async {
    final text = (await _env.readTextFile(cacheFile)).valueOrNull;
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final stamp = DateTime.tryParse(decoded['fetchedAt'] as String? ?? '');
      final payload = decoded['catalog'];
      if (stamp == null || payload is! Map<String, dynamic>) return null;
      return (stamp, await _parseEntries(payload));
    } on Object {
      return null; // torn/corrupt cache behaves like "no cache"
    }
  }

  Future<void> _writeCache(Map<String, dynamic> catalogJson) async {
    final payload = jsonEncode({
      'fetchedAt': _clock().toIso8601String(),
      'catalog': catalogJson,
    });
    try {
      await _env.writeFile(cacheFile, payload);
    } on Object {
      // A failing cache write must not kill the gallery — refetch next time.
    }
  }
}
