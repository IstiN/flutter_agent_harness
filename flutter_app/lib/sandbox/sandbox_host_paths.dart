// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

import 'dart:io' as io;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Shared "is this path inside the sandbox host directory" convention.
///
/// gh-1274 review: this test used to be re-implemented in three places —
/// `WasiSandboxShell._effectiveCwd`, `WasiSandboxShell._hostPath`, and
/// `SandboxedExecutionEnv._map` — and the copies could drift apart. All
/// three now route through this helper.
///
/// The match is hardened against the realistic path variants that would
/// otherwise silently fall through and re-leak the host cwd into guest
/// path resolution:
/// - a trailing separator on either side is ignored (a `Directory.path`
///   join can store the root as `<root>/`);
/// - a [path] spelled through a symlinked component (iOS simulator's
///   `/var` → `/private/var` shape) is matched against the symlink-resolved
///   root, resolved lazily once per instance;
/// - on case-insensitive-by-default platforms (anything but Linux, e.g.
///   APFS on macOS/iOS) the comparison folds case.
final class SandboxHostRoot {
  /// Creates a root matcher for the sandbox host directory at [root].
  ///
  /// [caseInsensitive] overrides the platform default (case-insensitive
  /// everywhere but Linux) — tests use it to exercise both modes on any
  /// host.
  SandboxHostRoot(String root, {bool? caseInsensitive})
    : _root = _stripTrailingSeparator(root),
      _caseInsensitive = caseInsensitive ?? !io.Platform.isLinux;

  final String _root;
  final bool _caseInsensitive;

  /// Lazily-resolved symlink spelling of the root; '' when resolution
  /// failed (e.g. the root does not exist yet) — null means "not computed".
  String? _resolved;

  static String _stripTrailingSeparator(String path) =>
      path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;

  String _key(String path) => _caseInsensitive ? path.toLowerCase() : path;

  String? get _resolvedRoot {
    var resolved = _resolved;
    if (resolved == null) {
      try {
        resolved = io.Directory(_root).resolveSymbolicLinksSync();
      } on Object {
        resolved = '';
      }
      _resolved = resolved;
    }
    return resolved.isEmpty ? null : resolved;
  }

  /// The sandbox-absolute remainder of [path] under the root: `/` when
  /// [path] *is* the root, `/work/...` when it sits under it (lexically
  /// normalized); `null` when [path] is outside the root.
  String? stripToSandboxPath(String path) {
    if (path.isEmpty) return null;
    final trimmed = _stripTrailingSeparator(path);
    final pathKey = _key(trimmed);
    final candidates = <String>[_root];
    final resolved = _resolvedRoot;
    if (resolved != null && resolved != _root) candidates.add(resolved);
    for (final root in candidates) {
      final rootKey = _key(root);
      if (pathKey == rootKey) return '/';
      final prefix = '$rootKey/';
      if (pathKey.startsWith(prefix)) {
        // Cut in the *original* string: case folding can shift lengths,
        // so the folded prefix length is not safe to use as an index.
        final cut = trimmed.length - (pathKey.length - prefix.length);
        return normalizeLexicalPath(trimmed.substring(cut));
      }
    }
    return null;
  }

  /// Whether [path] is the root itself or directly under it.
  bool contains(String path) => stripToSandboxPath(path) != null;
}
