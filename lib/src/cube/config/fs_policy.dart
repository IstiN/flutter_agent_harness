/// Filesystem policy for a cube (`spec.filesystem:`): which paths a sandboxed
/// run may read or write.
///
/// ```yaml
/// spec:
///   filesystem:
///     workspace: /workspace      # optional, default /workspace
///     mounts:
///       - {path: /usr/bin, access: ro}   # access: ro | rw | deny
///       - {path: ~/.ssh, access: deny}
/// ```
///
/// Resolution ([CubeFsPolicy.accessFor]) is pure string math — a lexical
/// traversal guard, no filesystem access: paths are `~`-expanded (when
/// [homeDir] is known; a `~` path with unknown [homeDir] is denied), `.`
/// and `..` segments are collapsed (a path that climbs above `/` is denied),
/// and symlinks are intentionally left unresolved. Relative paths resolve
/// against the workspace (the sandbox working directory).
///
/// The **longest matching mount wins**; otherwise a path inside the
/// workspace is read/write, and anything else is denied.
///
/// Parsing is strict: any schema problem throws [ConfigException] naming the
/// YAML path.
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';

/// Access level granted for a path.
enum CubePathAccess {
  /// Read-only (`ro` in the cube yaml).
  readOnly('ro'),

  /// Read and write (`rw` in the cube yaml).
  readWrite('rw'),

  /// No access at all (`deny` in the cube yaml).
  deny('deny');

  const CubePathAccess(this.label);

  /// The config-file label.
  final String label;

  /// Parses [label], throwing [ConfigException] on an unknown level.
  static CubePathAccess parse(String label, String where) {
    for (final access in values) {
      if (access.label == label) return access;
    }
    throw ConfigException(
      '$where: unknown access "$label" — supported: '
      '${values.map((a) => a.label).join(', ')}',
    );
  }
}

/// One mount entry: a path prefix and the access level granted under it.
final class CubeMount {
  /// Creates a mount; [path] is kept as written (`~` expands per query).
  const CubeMount({required this.path, required this.access});

  /// The mount path prefix (absolute, or `~`-relative).
  final String path;

  /// Access granted under [path].
  final CubePathAccess access;
}

/// The `spec.filesystem:` section: workspace root plus mount overrides.
final class CubeFsPolicy {
  /// Creates a policy; [workspace] must be absolute (enforced at parse).
  const CubeFsPolicy({this.workspace = '/workspace', this.mounts = const []});

  /// The read/write root; everything outside it is denied unless a mount
  /// grants access.
  final String workspace;

  /// Mount overrides, longest prefix wins over [workspace].
  final List<CubeMount> mounts;

  /// Parses the `spec.filesystem:` section. `null` (section absent) yields
  /// the default: workspace `/workspace`, no mounts.
  factory CubeFsPolicy.fromYaml(Object? node) {
    if (node == null) return const CubeFsPolicy();
    if (node is! YamlMap) {
      throw ConfigException(
        'cube.spec.filesystem: must be a map with optional "workspace"/'
        '"mounts", got ${node.runtimeType}',
      );
    }
    for (final key in node.keys) {
      if (key is! String || (key != 'workspace' && key != 'mounts')) {
        throw ConfigException(
          'cube.spec.filesystem: unknown key "$key" — supported: workspace, '
          'mounts',
        );
      }
    }
    final workspace = node['workspace'];
    if (workspace != null &&
        (workspace is! String ||
            !workspace.startsWith('/') && !workspace.startsWith('~/') ||
            workspace.trim().isEmpty)) {
      throw ConfigException(
        'cube.spec.filesystem.workspace: must be an absolute path (or '
        '~/-relative), got $workspace',
      );
    }
    final mountsNode = node['mounts'];
    final mounts = <CubeMount>[];
    if (mountsNode != null) {
      if (mountsNode is! YamlList) {
        throw ConfigException(
          'cube.spec.filesystem.mounts: must be a list of mount maps',
        );
      }
      for (final (index, entry) in mountsNode.indexed) {
        mounts.add(_parseMount(entry, 'cube.spec.filesystem.mounts[$index]'));
      }
    }
    return CubeFsPolicy(
      workspace: workspace == null ? '/workspace' : workspace.trim(),
      mounts: List.unmodifiable(mounts),
    );
  }

  /// Access level for [path]: the longest matching mount, else read/write
  /// inside [workspace], else [CubePathAccess.deny]. `~` paths with an
  /// unknown [homeDir], and paths that traverse above `/`, are denied.
  ///
  /// Pure string math — never touches the filesystem; symlinked paths are
  /// judged by their written form (the traversal guard is lexical only).
  CubePathAccess accessFor(String path, {String? homeDir}) {
    final target = _resolve(path, homeDir: homeDir);
    if (target == null) return CubePathAccess.deny;

    CubeMount? best;
    var bestLength = -1;
    for (final mount in mounts) {
      final base = _resolve(mount.path, homeDir: homeDir);
      if (base == null) continue;
      if (_within(target, base) && base.length > bestLength) {
        best = mount;
        bestLength = base.length;
      }
    }
    if (best != null) return best.access;

    final ws = _resolve(workspace, homeDir: homeDir);
    if (ws != null && _within(target, ws)) return CubePathAccess.readWrite;
    return CubePathAccess.deny;
  }

  static CubeMount _parseMount(Object? node, String where) {
    if (node is! YamlMap) {
      throw ConfigException('$where: must be a map with "path" and "access"');
    }
    for (final key in node.keys) {
      if (key is! String || (key != 'path' && key != 'access')) {
        throw ConfigException(
          '$where: unknown key "$key" — supported: path, access',
        );
      }
    }
    final path = node['path'];
    if (path is! String || path.trim().isEmpty) {
      throw ConfigException('$where.path: must be a non-empty string');
    }
    final access = node['access'];
    if (access is! String) {
      throw ConfigException('$where.access: must be one of ro, rw, deny');
    }
    return CubeMount(
      path: path.trim(),
      access: CubePathAccess.parse(access.trim(), '$where.access'),
    );
  }

  /// Lexically resolves [raw] to a normalized absolute path, or `null` when
  /// it cannot resolve (`~` without [homeDir], or `..` above the root).
  static String? _resolve(String raw, {String? homeDir}) {
    final path = raw.trim();
    if (path.isEmpty) return null;
    final home = homeDir?.trim();
    final hasHome = home != null && home.isNotEmpty;
    String target;
    if (path == '~' || path.startsWith('~/')) {
      if (!hasHome) return null;
      target = path == '~' ? home : '$home/${path.substring(2)}';
    } else if (path.startsWith('/')) {
      target = path;
    } else {
      // Relative path: the sandbox working directory is the workspace, so
      // resolve against it (workspace is validated absolute at parse time).
      target = '/workspace/$path';
    }
    return _normalize(target);
  }

  /// Collapses `.` and `..` segments; `null` when the path escapes above `/`.
  static String? _normalize(String target) {
    final stack = <String>[];
    for (final segment in target.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (stack.isEmpty) return null; // traversal above the root
        stack.removeLast();
      } else {
        stack.add(segment);
      }
    }
    return '/${stack.join('/')}';
  }

  /// Whether [path] equals or lives under [prefix].
  static bool _within(String path, String prefix) =>
      path == prefix || path.startsWith('$prefix/');
}

/// Remaps a spec-written [path] onto the realized workspace root: when
/// [path] equals or lives under [specWorkspace], that prefix is swapped for
/// [workspaceRoot] (`/workspace/data` with root `/work` becomes
/// `/work/data`); `null` when [path] is outside the workspace — including
/// look-alike prefixes like `/workspacefoo` — meaning the caller keeps it
/// as written.
///
/// Single source of truth for the CLI workspace override: the cube's
/// `/workspace` is realized as the process cwd, so every path written
/// against the spec workspace must follow ([CubeFsGuard] remaps mounts
/// with it, [CubeCacheManager] mirrors cache paths with it).
String? resolveWorkspacePath(
  String path,
  String specWorkspace,
  String workspaceRoot,
) {
  final base = CubeFsPolicy._normalize(specWorkspace);
  final target = CubeFsPolicy._normalize(path);
  if (base == null || target == null || !CubeFsPolicy._within(target, base)) {
    return null;
  }
  return '$workspaceRoot${target.substring(base.length)}';
}
