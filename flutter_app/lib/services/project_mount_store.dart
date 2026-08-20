import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Persists the user-selected project folder (path + security-scoped
/// bookmark + scoped flag) as `project_mount.json` in the container env,
/// so the mount survives restarts — the same pattern as `LastConnectionStore`.
///
/// [scoped] is the runtime toggle for 'restrict tools to this folder'.
/// When true, only paths under [path] should be writable / readable from
/// the agent (enforcement lands in the tool layer; the store is just
/// state).
final class ProjectMountStore {
  ProjectMountStore._(this.path, this.bookmark, {this.scoped = false});

  static const _fileName = 'project_mount.json';

  /// The mounted folder's host path.
  final String path;

  /// Base64 security-scoped bookmark for [path].
  final String bookmark;

  /// Restrict the agent's tools to operate only inside [path].
  final bool scoped;

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
      final scoped = json['scoped'] == true;
      return ProjectMountStore._(path, bookmark, scoped: scoped);
    } on Object {
      return null;
    }
  }

  /// Persists [path] + [bookmark] (replaces any previous mount). Pass
  /// [scoped] to update the restriction flag without changing the mount.
  static Future<void> save(
    ExecutionEnv env, {
    required String path,
    required String bookmark,
    bool scoped = false,
  }) async {
    await env.writeFile(
      _fileName,
      jsonEncode({'path': path, 'bookmark': bookmark, 'scoped': scoped}),
    );
  }

  /// Removes the stored mount (unmount flow).
  static Future<void> clear(ExecutionEnv env) async {
    await env.remove(_fileName, force: true);
  }
}
