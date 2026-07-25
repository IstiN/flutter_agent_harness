// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/icloud_sync_service.dart';

/// Whether the current platform has the native iCloud backend: the
/// `fah/icloud` method channel is wired up on macOS and iOS only (see
/// `MainFlutterWindow.swift` / `AppDelegate.swift`).
bool get icloudSyncSupported => Platform.isMacOS || Platform.isIOS;

/// Creates the method-channel-backed [ICloudSyncService] (IO platforms).
ICloudSyncService createICloudSyncService(ExecutionEnv env) =>
    MethodChannelICloudSyncService(env);

/// [ICloudSyncService] over the `fah/icloud` method channel: the channel
/// resolves the ubiquity container URL, the merge itself runs Dart-side in
/// [ICloudSyncEngine] against the container path with `dart:io`.
final class MethodChannelICloudSyncService implements ICloudSyncService {
  /// Creates a service syncing [env]'s `sessions/` and `apps/` trees.
  ///
  /// [containerPath] overrides the channel lookup; tests inject a fake
  /// container directory through it.
  MethodChannelICloudSyncService(
    this._env, {
    @visibleForTesting Future<String?> Function()? containerPath,
  }) : _containerPath = containerPath ?? _channelContainerPath;

  static const _channel = MethodChannel('fah/icloud');

  final ExecutionEnv _env;
  final Future<String?> Function() _containerPath;

  static Future<String?> _channelContainerPath() async {
    if (!icloudSyncSupported) return null;
    try {
      return await _channel.invokeMethod<String>('containerUrl');
    } on MissingPluginException {
      // No native handler (e.g. unit tests) — treat as unavailable.
      return null;
    }
  }

  @override
  Future<String?> containerUrl() => _containerPath();

  @override
  Future<bool> isAvailable() async => await _containerPath() != null;

  @override
  Future<ICloudSyncReport> syncNow() async {
    final container = await _containerPath();
    if (container == null) {
      throw StateError(
        'iCloud sync is not available: the ubiquity container could not be '
        'resolved (not signed in to iCloud, or the capability/container id '
        'is missing from the provisioning profile).',
      );
    }
    return ICloudSyncEngine(env: _env, faSyncRoot: '$container/FaSync').sync();
  }

  @override
  Future<DateTime?> lastSyncAt() => readICloudSyncState(_env);
}

/// Reads the [icloudSyncStateFile] timestamp from [env]; null when the file
/// is missing or unreadable (never synced).
Future<DateTime?> readICloudSyncState(ExecutionEnv env) async {
  final result = await env.readTextFile('${env.cwd}/$icloudSyncStateFile');
  final body = result.valueOrNull;
  if (body == null) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final ms = (decoded['lastSyncMs'] as num?)?.toInt();
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  } on Object {
    return null;
  }
}

/// File metadata used for the last-write-wins comparison.
typedef _FileMeta = ({int mtimeMs, int size});

/// The file-level merge behind [MethodChannelICloudSyncService.syncNow],
/// factored out so tests drive it with a fake container directory.
///
/// Two-way, last-write-wins by file mtime (see [ICloudSyncService] for the
/// full v1 semantics): for each tree in [syncedTrees], env-only files push
/// to the container, container-only files pull into the env, and files on
/// both sides copy the newer mtime over the older one. Pushes preserve the
/// source mtime on the container copy; pulls cannot (the env API has no
/// mtime setter), so a pulled file is pushed back once on the next sync
/// before the mtimes settle. Deletions are never propagated.
final class ICloudSyncEngine {
  /// Creates an engine syncing [env]'s trees against [faSyncRoot], the host
  /// path of `<container>/Documents/FaSync`.
  ICloudSyncEngine({
    required this.env,
    required this.faSyncRoot,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// The sandbox env whose `sessions/` and `apps/` trees are synced.
  final ExecutionEnv env;

  /// Host path of the sync root inside the ubiquity container.
  final String faSyncRoot;

  final DateTime Function() _now;

  /// The env-root trees that participate in the sync.
  static const syncedTrees = ['sessions', 'apps'];

  /// Runs one merge, persists [icloudSyncStateFile] via the env, and
  /// returns the report.
  Future<ICloudSyncReport> sync() async {
    var files = 0;
    var bytes = 0;
    for (final tree in syncedTrees) {
      final envRoot = '${env.cwd}/$tree';
      final hostRoot = '$faSyncRoot/$tree';
      final envFiles = await _envTree(envRoot);
      final hostFiles = _hostTree(hostRoot);
      final relPaths = {...envFiles.keys, ...hostFiles.keys}.toList()..sort();
      for (final rel in relPaths) {
        final copied = await _reconcile(
          envRoot,
          hostRoot,
          rel,
          envFiles[rel],
          hostFiles[rel],
        );
        if (copied != null) {
          files++;
          bytes += copied;
        }
      }
    }
    final at = _now();
    await env.writeFile(
      '${env.cwd}/$icloudSyncStateFile',
      jsonEncode({
        'lastSyncMs': at.millisecondsSinceEpoch,
        'filesCopied': files,
        'bytesCopied': bytes,
      }),
    );
    return (filesCopied: files, bytesCopied: bytes, syncedAt: at);
  }

  /// Recursive file map (relative path → metadata) of the env tree rooted
  /// at [root]; empty when the tree does not exist.
  Future<Map<String, _FileMeta>> _envTree(String root) async {
    final result = <String, _FileMeta>{};
    Future<void> walk(String dir, String prefix) async {
      final listing = await env.listDir(dir);
      final entries = listing.valueOrNull;
      if (entries == null) return; // missing tree = nothing to sync
      for (final entry in entries) {
        final rel = prefix.isEmpty ? entry.name : '$prefix/${entry.name}';
        if (entry.kind == FileKind.directory) {
          await walk('$dir/${entry.name}', rel);
        } else if (entry.kind == FileKind.file) {
          result[rel] = (mtimeMs: entry.mtimeMs, size: entry.size);
        }
      }
    }

    await walk(root, '');
    return result;
  }

  /// Recursive file map (relative path → metadata) of the container tree
  /// rooted at [root]; empty when the tree does not exist.
  Map<String, _FileMeta> _hostTree(String root) {
    final result = <String, _FileMeta>{};
    final dir = Directory(root);
    if (!dir.existsSync()) return result;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(root.length + 1);
      final stat = entity.statSync();
      result[rel] = (
        mtimeMs: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
      );
    }
    return result;
  }

  /// Copies [rel] in the winning direction, returning the copied byte
  /// count; null when both sides agree (same mtime) so nothing is done.
  Future<int?> _reconcile(
    String envRoot,
    String hostRoot,
    String rel,
    _FileMeta? envMeta,
    _FileMeta? hostMeta,
  ) async {
    if (envMeta != null &&
        (hostMeta == null || envMeta.mtimeMs > hostMeta.mtimeMs)) {
      // Push env → container, preserving the source mtime so later syncs
      // see the two sides as equal.
      final read = await env.readBinaryFile('$envRoot/$rel');
      final bytes = read.valueOrNull;
      if (bytes == null) return null;
      final hostFile = File('$hostRoot/$rel');
      await hostFile.parent.create(recursive: true);
      await hostFile.writeAsBytes(bytes, flush: true);
      await hostFile.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(envMeta.mtimeMs),
      );
      return bytes.length;
    }
    if (hostMeta != null &&
        (envMeta == null || hostMeta.mtimeMs > envMeta.mtimeMs)) {
      // Pull container → env. The env API cannot set mtimes, so the env
      // copy lands with "now" — see the class doc for the settle copy.
      final bytes = await File('$hostRoot/$rel').readAsBytes();
      await env.writeBinaryFile('$envRoot/$rel', bytes);
      return bytes.length;
    }
    return null;
  }
}
