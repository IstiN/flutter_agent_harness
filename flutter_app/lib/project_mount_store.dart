import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Persists the user-selected project folder (path + security-scoped
/// bookmark) as `project_mount.json` in the container env, so the mount
/// survives restarts — the same pattern as `LastConnectionStore`.
final class ProjectMountStore {
  ProjectMountStore._(this.path, this.bookmark);

  static const _fileName = 'project_mount.json';

  /// The mounted folder's host path.
  final String path;

  /// Base64 security-scoped bookmark for [path].
  final String bookmark;

  /// Reads the stored mount, or null when none/absent/corrupt.
  static Future<ProjectMountStore?> load(ExecutionEnv env) async {
    final result = await env.readTextFile(_fileName);
    final text = result.valueOrNull;
    if (text == null || text.trim().isEmpty) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return null;
      final path = json['path'];
      final bookmark = json['bookmark'];
      if (path is! String || path.isEmpty) return null;
      if (bookmark is! String || bookmark.isEmpty) return null;
      return ProjectMountStore._(path, bookmark);
    } on Object {
      return null;
    }
  }

  /// Persists [path] + [bookmark] (replaces any previous mount).
  static Future<void> save(
    ExecutionEnv env, {
    required String path,
    required String bookmark,
  }) async {
    await env.writeFile(
      _fileName,
      jsonEncode({'path': path, 'bookmark': bookmark}),
    );
  }

  /// Removes the stored mount (unmount flow).
  static Future<void> clear(ExecutionEnv env) async {
    await env.remove(_fileName, force: true);
  }
}
