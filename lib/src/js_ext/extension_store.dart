/// On-disk store for installed JS extensions, layered over [ExecutionEnv]
/// (no dart:io): `<projectDir>/.fah/js-ext/<name>/` shadows
/// `<userDir>/.fah/js-ext/<name>/`, plus the pinned content hash function.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../env/execution_env.dart';
import 'ext_manifest.dart';
import 'trust.dart';

/// Which store root an installed extension lives in.
enum ExtStoreScope {
  /// Project-local root: `<projectDir>/.fah/js-ext`.
  project,

  /// Per-user root: `<userDir>/.fah/js-ext`.
  user,
}

/// One installed extension as read from the store.
final class StoredExtension {
  /// Extension name (from its manifest).
  final String name;

  /// Which root the winning copy was read from.
  final ExtStoreScope scope;

  /// Absolute directory of the extension.
  final String dir;

  /// Parsed manifest.
  final ExtensionManifest manifest;

  /// Text content of `main.js`.
  final String mainJs;

  /// Granted trust record; `null` => untrusted (tombstone, never loaded).
  final TrustRecord? trust;

  /// Creates a stored extension view.
  StoredExtension({
    required this.name,
    required this.scope,
    required this.dir,
    required this.manifest,
    required this.mainJs,
    required this.trust,
  });
}

/// Result of [ExtensionStore.list]: loaded extensions plus the reasons any
/// invalid extension directory was skipped.
final class ExtStoreListResult {
  /// Valid extensions, project scope shadowing user scope by name.
  final List<StoredExtension> extensions;

  /// Directory name -> why it was skipped (invalid manifest, missing
  /// main.js). Shadowed or platform-filtered entries are NOT problems.
  final Map<String, String> problems;

  /// Creates a list result.
  ExtStoreListResult({required this.extensions, this.problems = const {}});
}

/// Reads and writes installed extensions through [ExecutionEnv].
final class ExtensionStore {
  /// Manifest file name inside an extension directory.
  static const String kManifestFile = 'manifest.json';

  /// Execution environment backing all store IO.
  final ExecutionEnv env;

  /// Project root directory (store root is `<projectDir>/.fah/js-ext`).
  final String projectDir;

  /// User root directory (store root is `<userDir>/.fah/js-ext`).
  final String userDir;

  /// Creates a store over [env], rooted at [projectDir] and [userDir].
  ExtensionStore({
    required this.env,
    required this.projectDir,
    required this.userDir,
  });
  static const String kMainFile = 'main.js';

  /// Trust record file name (absent => untrusted tombstone).
  static const String kTrustFile = 'trust.json';

  String _root(ExtStoreScope scope) => scope == ExtStoreScope.project
      ? '$projectDir/.fah/js-ext'
      : '$userDir/.fah/js-ext';

  /// Lists installed extensions. Project entries shadow user entries with the
  /// same name. Dirs with an invalid manifest (or a missing [kMainFile]) are
  /// skipped and reported in the returned [ExtStoreListResult.problems] map.
  /// With [forPlatform], only extensions whose manifest supports that
  /// platform are returned.
  Future<ExtStoreListResult> list({ExtPlatformTag? forPlatform}) async {
    final extensions = <StoredExtension>[];
    final problems = <String, String>{};
    final seen = <String>{};
    for (final scope in ExtStoreScope.values) {
      final listed = await env.listDir(_root(scope));
      if (listed.isErr) continue;
      for (final entry in listed.valueOrNull!) {
        if (entry.kind != FileKind.directory) continue;
        final ext = await _read(entry.path, scope, problems);
        if (ext == null) continue;
        if (seen.contains(ext.name)) continue;
        if (forPlatform != null &&
            !ext.manifest.supportsPlatform(forPlatform)) {
          continue;
        }
        seen.add(ext.name);
        extensions.add(ext);
      }
    }
    return ExtStoreListResult(extensions: extensions, problems: problems);
  }

  /// Finds an installed extension by name; project scope wins. `null` when
  /// not installed (or its manifest is invalid).
  Future<StoredExtension?> find(String name) async {
    final problems = <String, String>{};
    for (final scope in ExtStoreScope.values) {
      final ext = await _read('${_root(scope)}/$name', scope, problems);
      if (ext != null) return ext;
    }
    return null;
  }

  /// Writes an extension into the PROJECT scope. [files] maps relative paths
  /// to text content and must contain [kManifestFile] and [kMainFile].
  /// Order: files first, then `trust.json` last — a crash mid-write leaves
  /// the extension untrusted (tombstone), never half-trusted.
  Future<void> write(
    String name, {
    required Map<String, String> files,
    required TrustRecord trust,
  }) async {
    if (!files.containsKey(kManifestFile) || !files.containsKey(kMainFile)) {
      throw ArgumentError('files must contain $kManifestFile and $kMainFile');
    }
    for (final rel in files.keys) {
      if (rel.isEmpty || rel.startsWith('/') || rel.split('/').contains('..')) {
        throw ArgumentError('invalid file path: $rel');
      }
    }
    final manifestValue = jsonDecode(files[kManifestFile]!);
    if (manifestValue is! Map<String, dynamic>) {
      throw ArgumentError('$kManifestFile must be a JSON object');
    }
    ExtensionManifest.fromJson(manifestValue); // throws ExtManifestException
    final dir = '${_root(ExtStoreScope.project)}/$name';
    for (final rel in files.keys.toList()..sort()) {
      await _writeText('$dir/$rel', files[rel]!);
    }
    await _writeText('$dir/$kTrustFile', jsonEncode(trust.toJson()));
  }

  /// Replaces the trust record of an installed extension (project scope
  /// wins). Throws [StateError] when not installed.
  Future<void> setTrust(String name, TrustRecord trust) async {
    final ext = await find(name);
    if (ext == null) throw StateError('extension not found: $name');
    await _writeText('${ext.dir}/$kTrustFile', jsonEncode(trust.toJson()));
  }

  /// Deletes the extension directory (project scope first). Missing
  /// extensions are silently ignored.
  Future<void> remove(String name) async {
    for (final scope in ExtStoreScope.values) {
      final dir = '${_root(scope)}/$name';
      final exists = await env.exists(dir);
      if (exists.isErr || exists.valueOrNull != true) continue;
      await env.remove(dir, recursive: true, force: true);
      return;
    }
  }

  Future<StoredExtension?> _read(
    String dir,
    ExtStoreScope scope,
    Map<String, String> problems,
  ) async {
    final dirName = dir.split('/').last;
    final manifestResult = await env.readTextFile('$dir/$kManifestFile');
    if (manifestResult.isErr) return null; // no manifest => not an ext dir
    Map<String, dynamic> manifestJson;
    try {
      final decoded = jsonDecode(manifestResult.valueOrNull!);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('manifest must be a JSON object');
      }
      manifestJson = decoded;
    } on FormatException catch (e) {
      problems[dirName] = 'invalid $kManifestFile: ${e.message}';
      return null;
    }
    ExtensionManifest manifest;
    try {
      manifest = ExtensionManifest.fromJson(manifestJson);
    } on ExtManifestException catch (e) {
      problems[dirName] = 'invalid $kManifestFile: ${e.problems.join('; ')}';
      return null;
    }
    final mainResult = await env.readTextFile('$dir/$kMainFile');
    if (mainResult.isErr) {
      problems[dirName] = 'missing $kMainFile';
      return null;
    }
    return StoredExtension(
      name: manifest.name,
      scope: scope,
      dir: dir,
      manifest: manifest,
      mainJs: mainResult.valueOrNull!,
      trust: await _readTrust(dir),
    );
  }

  /// `trust.json` absent or unreadable => `null` (untrusted tombstone).
  Future<TrustRecord?> _readTrust(String dir) async {
    final result = await env.readTextFile('$dir/$kTrustFile');
    if (result.isErr) return null;
    try {
      final decoded = jsonDecode(result.valueOrNull!);
      if (decoded is! Map<String, dynamic>) return null;
      return TrustRecord.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeText(String path, String content) async {
    final result = await env.writeFile(path, content);
    if (result.isErr) {
      throw StateError('failed to write $path: ${result.errorOrNull!.message}');
    }
  }
}

/// Pinned, testable content hash: sha256 hex over, for each rel-path sorted
/// lexicographically, `utf8(path) + 0x00 + utf8(content)` concatenated.
String extContentHash(Map<String, String> files) {
  final bytes = <int>[];
  for (final path in files.keys.toList()..sort()) {
    bytes.addAll(utf8.encode(path));
    bytes.add(0x00);
    bytes.addAll(utf8.encode(files[path]!));
  }
  return sha256.convert(bytes).toString();
}
