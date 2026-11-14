import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
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
  if (mountEnv == null || !projectMountBackendAvailable(env)) return null;
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
    // Preserve the current scoped state across re-picks; default false
    // for a fresh /project.
    scoped: mountEnv.scoped,
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

/// THE visibility seam for opening a host folder in the session's env:
/// is [candidatePath] (typically a session's origin folder,
/// `service.currentSessionCwd`) inside the env's visible roots at all?
///
/// The env sees exactly two roots — [ExecutionEnv.cwd] (the container
/// root, e.g. the app-support sandbox) and the mounted host folder
/// ([currentMountedPath]). A session folder outside both (a host path the
/// sandbox cannot open — the macOS app sandbox sees only the granted
/// mount) yields null: the caller must NOT hand the path to a listing
/// (Files would show "could not open folder"); null means "open the env
/// root", which for a mounted session already IS the session's folder
/// (`/project` maps onto the mount).
///
/// Returns the normalized visible root (trailing slashes stripped, `null`
/// or blank candidates never pass), so one function owns the decision and
/// the follow-up access flow (the 'allow folder access' open-panel
/// affordance for a non-visible folder) can hook the same seam.
///
/// A session folder recorded under a RELOCATED container also resolves:
/// mobile reinstall/backup-restore re-seats the app container (the
/// recorded cwd keeps the old UUID prefix, `env.cwd` the new one) — the
/// folder is still the sandbox the env opens, so the match returns the
/// LIVE root the listing can actually open (never the stale prefix,
/// which would resolve nowhere). See [_isSameFolderPath].
String? visibleFolderRoot(ExecutionEnv env, String? candidatePath) {
  final candidate = _normalizeFolderPath(candidatePath);
  if (candidate == null) return null;
  for (final root in <String?>[env.cwd, currentMountedPath(env)]) {
    final visible = _normalizeFolderPath(root);
    if (visible == null) continue;
    if (_isSameFolderPath(visible, candidate)) return visible;
  }
  return null;
}

/// Whether [candidate] names the same folder as [root] after a relocation
/// of every segment before the last two (the folder and its parent).
/// Exact equality is the primary contract; the tail match only fires when
/// both paths carry at least two segments and the trailing two agree
/// (case-folded on case-insensitive platforms, mirroring the
/// SandboxHostRoot convention). Single-segment roots never tail-match —
/// a shared folder name alone is too weak to claim identity.
bool _isSameFolderPath(String root, String candidate) {
  if (root == candidate) return true;
  return folderPathsTailMatch(
    root,
    candidate,
    // kIsWeb MUST short-circuit before Platform: dart:io's Platform throws
    // UnsupportedError on the web build, and this comparison runs un-gated
    // every time the Files panel resolves a folder (review blocker, PR
    // #2112). Web paths follow URL case semantics — same as Linux.
    caseSensitive: kIsWeb || Platform.isLinux,
  );
}

/// The tail-match half of [_isSameFolderPath], with the platform fold
/// injected as a plain bool so tests can exercise the web branch on the
/// VM (the web build cannot reach dart:io's Platform at all).
@visibleForTesting
bool folderPathsTailMatch(
  String root,
  String candidate, {
  required bool caseSensitive,
}) {
  final fold = caseSensitive ? (String s) => s : (String s) => s.toLowerCase();
  final rootSegments = _folderSegments(root);
  final candidateSegments = _folderSegments(candidate);
  if (rootSegments.length < 2 || candidateSegments.length < 2) return false;
  return fold(rootSegments.last) == fold(candidateSegments.last) &&
      fold(rootSegments[rootSegments.length - 2]) ==
          fold(candidateSegments[candidateSegments.length - 2]);
}

/// Non-empty path segments (slashes and '.' dropped).
List<String> _folderSegments(String path) => [
  for (final segment in path.split('/'))
    if (segment.isNotEmpty && segment != '.') segment,
];

/// Trailing-slash-insensitive folder-path comparison form: null for
/// null/blank, the path with any trailing slashes stripped (`/` stays
/// `/`). One normalization so roots and candidates cannot drift apart on
/// a formatting detail.
String? _normalizeFolderPath(String? path) {
  final trimmed = path?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  var normalized = trimmed;
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

/// Whether the active mount is scoped (tool restriction flag on).
bool? currentMountedScoped(ExecutionEnv env) => _resolveMountEnv(env)?.scoped;

/// Toggles the 'restrict tools to this folder' flag without re-picking
/// the folder: updates [ProjectMountEnv.scoped] in place, persists the
/// new flag via [ProjectMountStore.save] (re-using the existing path +
/// bookmark), and recomposes the agent's prompt. Returns true when the
/// toggle landed. No-op when nothing is mounted (nothing to scope TO).
Future<bool> setProjectMountScoped({
  required ExecutionEnv env,
  required bool scoped,
  required void Function() onApplied,
}) async {
  final target = await _scopedMountTarget(env);
  if (target == null) {
    return false;
  }
  final (mountEnv, stored) = target;
  mountEnv.scoped = scoped;
  await ProjectMountStore.save(
    env,
    path: stored.path,
    bookmark: stored.bookmark,
    scoped: scoped,
  );
  onApplied();
  return true;
}

/// The mount target of the scoped toggle: `(mountEnv, stored record)`, or
/// null when any precondition is missing.
Future<(ProjectMountEnv, ProjectMountStore)?> _scopedMountTarget(
  ExecutionEnv env,
) async {
  final mountEnv = _mountedProjectEnv(env);
  if (mountEnv == null) {
    return null;
  }
  final stored = await ProjectMountStore.load(env);
  if (stored == null) {
    return null;
  }
  return (mountEnv, stored);
}

/// The mount env only when a folder is actually mounted (nothing mounted
/// means nothing to scope TO).
ProjectMountEnv? _mountedProjectEnv(ExecutionEnv env) {
  final mountEnv = _resolveMountEnv(env);
  return mountEnv?.mountedRoot == null ? null : mountEnv;
}

/// Whether native directory picking is available on this platform (macOS).
bool projectFolderPickingSupported() {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isIOS;
}

ProjectMountEnv? _resolveMountEnv(ExecutionEnv env) =>
    resolveProjectMountEnv(env);

ProjectFolderOps? _defaultOps() => defaultProjectFolderOps();
