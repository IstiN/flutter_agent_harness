import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:fa/services/project_folder_channel.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/project_mount_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Shared flow for changing the user-selected project folder (macOS only):
/// pick → resolve security-scoped bookmark → persist → apply to the mount
/// env → notify the host (typically `agent.refreshProjectMountPrompt`).
/// Extracted so the file browser, the chat header's workspace chip, and
/// tests all drive it through one code path.

/// Picks a directory and applies it as the project mount. Returns the
/// picked host path on success, null when cancelled or unsupported.
/// Surfaces access failures via [onAccessDenied]; tells the host the
/// environment changed via [onApplied] (pass the service's
/// `refreshProjectMountPrompt` to recompose the agent's system prompt).
Future<String?> pickAndApplyProjectMount({
  required ExecutionEnv env,
  required void Function() onApplied,
  ProjectFolderOps? ops,
  void Function()? onAccessDenied,
}) async {
  final mountEnv = _resolveMountEnv(env);
  if (mountEnv == null) return null;
  final resolvedOps = ops ?? _defaultOps();
  if (resolvedOps == null) return null;
  final picked = await resolvedOps.pickDirectory();
  if (picked == null) return null;
  final ok = await resolvedOps.startAccessing(picked.bookmark);
  if (!ok) {
    onAccessDenied?.call();
    return null;
  }
  await ProjectMountStore.save(
    env,
    path: picked.path,
    bookmark: picked.bookmark,
  );
  mountEnv.mountedRoot = picked.path;
  mountEnv.mountUnavailable = null;
  onApplied();
  return picked.path;
}

/// Unmounts the current project folder (best effort) and notifies the host.
/// Returns true when a mount was cleared.
Future<bool> unapplyProjectMount({
  required ExecutionEnv env,
  required void Function() onApplied,
  ProjectFolderOps? ops,
}) async {
  final mountEnv = _resolveMountEnv(env);
  final root = mountEnv?.mountedRoot;
  if (mountEnv == null || root == null) return false;
  final resolvedOps = ops ?? _defaultOps();
  final stored = await ProjectMountStore.load(env);
  if (stored != null && resolvedOps != null) {
    await resolvedOps.stopAccessing(stored.bookmark);
  }
  await ProjectMountStore.clear(env);
  mountEnv.mountedRoot = null;
  onApplied();
  return true;
}

/// The host path the project mount currently resolves to, or null when no
/// folder is mounted (the agent works in its container root).
String? currentMountedPath(ExecutionEnv env) =>
    _resolveMountEnv(env)?.mountedRoot;

/// Whether native directory picking is available on this platform (macOS).
bool projectFolderPickingSupported() {
  if (kIsWeb) return false;
  return Platform.isMacOS;
}

ProjectMountEnv? _resolveMountEnv(ExecutionEnv env) {
  var e = env;
  if (e is SecretsExecutionEnv) e = e.delegate;
  return e is ProjectMountEnv ? e : null;
}

ProjectFolderOps? _defaultOps() => ProjectFolderChannelOps.isSupported
    ? const ProjectFolderChannelOps()
    : null;
