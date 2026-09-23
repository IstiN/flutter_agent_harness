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
/// Resolution ([CubeFsPolicy.accessFor]) expands `~` (when [homeDir] is
/// known; a `~` path with unknown [homeDir] is denied) and collapses `.`
/// and `..` segments (a path that climbs above `/` is denied). Relative
/// paths resolve against the workspace (the sandbox working directory).
///
/// Without a [CubeFsProbe] the check is pure string math — symlinked paths
/// are judged by their written form. With a probe,
/// [CubeFsPolicy.accessForResolved] resolves each path component against
/// the filesystem instead: symlink chains are followed to a fixed depth,
/// `..` applies after resolution, unreadable indirections (Windows reparse
/// points) fail closed, and the verdict judges the file the OS would
/// actually open.
///
/// The **longest matching mount wins**; otherwise a path inside the
/// workspace is read/write, and anything else is denied.
///
/// Parsing is strict: any schema problem throws [ConfigException] naming the
/// YAML path.
library;

import 'package:yaml/yaml.dart';

import '../../exceptions.dart';

/// One symlink-probe result for a path component:
///
/// - `(isLink: false, target: null)` — a regular file or directory.
/// - `(isLink: true, target: "…")` — a symlink; [target] is verbatim
///   (absolute or relative, and may itself contain links or `..`).
/// - `(isLink: true, target: null)` — an indirection exists but cannot be
///   read (an unreadable Windows reparse point/junction, a permission
///   wall): callers MUST deny — fail closed.
typedef CubeLinkTarget = ({bool isLink, String? target});

/// Answers "is this path a symlink, and where does it point?" — the seam
/// that keeps [CubeFsPolicy] pure Dart. Real hosts implement it over the OS
/// (`LocalCubeFsProbe`, exported from `lib/io.dart`); tests fake it.
abstract interface class CubeFsProbe {
  /// Probes [path] for an indirection. See [CubeLinkTarget] for the shapes.
  CubeLinkTarget linkTarget(String path);
}

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
  /// Without a [probe] this is pure string math — symlinked paths are
  /// judged by their written form. With a probe the verdict judges the
  /// file the OS will open; see [accessForResolved].
  CubePathAccess accessFor(
    String path, {
    String? homeDir,
    CubeFsProbe? probe,
  }) => accessForResolved(path, homeDir: homeDir, probe: probe).access;

  /// [accessFor] plus the canonical path to open: `resolved` is the
  /// per-component real-path resolution of [path] when a [probe] is given
  /// and the path is allowed (feed it to the delegate — resolve-then-open),
  /// and `null` otherwise (denied, or the no-probe lexical mode).
  ///
  /// Resolving mode: each component of [path] is probed in turn, symlink
  /// chains are followed up to a fixed depth, relative link targets splice
  /// in front of the remaining components, and `..` pops the RESOLVED
  /// prefix (so `link/..` climbs out of the link's target, like the kernel
  /// does). Every resolved ancestor is probed; the access verdict itself
  /// runs once on the final resolved path — longest-match mounts stay
  /// intact (an ancestor inside a deny mount never over-blocks a deeper
  /// rw mount). An unreadable indirection (Windows reparse point) or a
  /// chain past the depth limit denies — fail closed.
  ///
  /// Residual race (documented, not solved): the target can still be
  /// swapped between this check and the delegate's open. That window is a
  /// swap, not a standing symlink — closing it entirely needs the file
  /// tools to run inside the sandboxed worker.
  ({CubePathAccess access, String? resolved}) accessForResolved(
    String path, {
    String? homeDir,
    CubeFsProbe? probe,
  }) {
    if (probe == null) {
      final target = _resolve(path, homeDir: homeDir);
      return (
        access: target == null
            ? CubePathAccess.deny
            : _classify(target, homeDir: homeDir),
        resolved: null,
      );
    }
    final head = _splitHead(path, homeDir: homeDir);
    if (head == null) return (access: CubePathAccess.deny, resolved: null);
    final resolved = _resolveReal(head: head.$1, rest: head.$2, probe: probe);
    if (resolved == null) return (access: CubePathAccess.deny, resolved: null);
    return (access: _classify(resolved, homeDir: homeDir), resolved: resolved);
  }

  /// Symlink chains longer than this are denied (fail-closed). The POSIX
  /// kernel limit is 40; ours is deliberately tighter — eight hops already
  /// covers every legitimate layout.
  static const _maxResolvedLinks = 8;

  /// Walks the attacker-controlled components of a path to their real-path
  /// resolution: `null` denies (above-root climb, unreadable indirection,
  /// or a chain past [_maxResolvedLinks]). Trusted heads (home, workspace)
  /// are seeded as the stack and never probed — the cube owner picks them.
  static String? _resolveReal({
    required List<String> head,
    required List<String> rest,
    required CubeFsProbe probe,
  }) {
    var linksLeft = _maxResolvedLinks;
    final stack = [...head];
    final pending = [...rest];
    while (pending.isNotEmpty) {
      final segment = pending.removeAt(0);
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (stack.isEmpty) return null; // traversal above the root
        stack.removeLast();
        continue;
      }
      final link = probe.linkTarget('/${[...stack, segment].join('/')}');
      if (!link.isLink) {
        stack.add(segment);
        continue;
      }
      final target = link.target;
      if (target == null || linksLeft == 0) return null;
      linksLeft--;
      if (target.startsWith('/')) stack.clear();
      pending.insertAll(0, target.split('/'));
    }
    return '/${stack.join('/')}';
  }

  /// The path split into non-empty components — the one tokenizer every
  /// branch of [_splitHead] shares.
  static List<String> _components(String path) =>
      path.split('/')..removeWhere((segment) => segment.isEmpty);

  /// The trusted head of [raw] plus its own untrusted components. The head
  /// is the longest configured root (~-expanded home, workspace, or the
  /// longest matching mount — normalized, no links involved) that lexically
  /// prefixes [raw]; only components BELOW it are probed. The owner picks
  /// the roots, and firmware symlinks (`/tmp` → `/private/tmp`) live in
  /// them, not below — resolving them would split the verdict from the
  /// mounts' own spelling. `null` per [_resolve]'s unresolvable rules.
  (List<String>, List<String>)? _splitHead(String raw, {String? homeDir}) {
    final path = raw.trim();
    if (path.isEmpty) return null;
    final home = homeDir?.trim();
    final hasHome = home != null && home.isNotEmpty;
    if (path == '~' || path.startsWith('~/')) {
      if (!hasHome) return null;
      return (_components(home), _components(path.substring(2)));
    }
    if (path.startsWith('/')) {
      return _splitAbsoluteHead(path, homeDir: homeDir);
    }
    // Relative path: the sandbox working directory is the workspace, so
    // resolve against it (workspace is validated absolute at parse time).
    final ws = _resolve(workspace, homeDir: homeDir);
    if (ws == null) return null;
    return (_components(ws), _components(path));
  }

  /// The absolute-path branch of [_splitHead]: find the longest configured
  /// root (workspace or mount) that lexically prefixes [path] — that prefix
  /// is the trusted head — and return it with the remaining components.
  (List<String>, List<String>) _splitAbsoluteHead(
    String path, {
    String? homeDir,
  }) {
    var head = const <String>[];
    var bestLength = -1;
    final roots = [workspace, ...mounts.map((mount) => mount.path)];
    for (final root in roots) {
      final base = _resolve(root, homeDir: homeDir);
      if (base != null && _within(path, base) && base.length > bestLength) {
        bestLength = base.length;
        head = _components(base);
      }
    }
    return (head, _components(path).sublist(head.length));
  }

  /// The longest-mount-else-workspace verdict for a fully resolved [target].
  CubePathAccess _classify(String target, {String? homeDir}) {
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
  /// Relative paths resolve against the policy's workspace — the same base
  /// the resolving mode's [_splitHead] uses.
  String? _resolve(String raw, {String? homeDir}) {
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
      // Relative path: the sandbox working directory is the workspace
      // (validated absolute at parse time).
      final ws = _resolve(workspace, homeDir: homeDir);
      if (ws == null) return null;
      target = '$ws/$path';
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

  /// Whether [path] equals or lives under [prefix]. The root prefix
  /// matches everything (the `$prefix/` join would spell `//` and never
  /// match, silently voiding a `{path: /, access: …}` mount).
  static bool _within(String path, String prefix) =>
      prefix == '/' || path == prefix || path.startsWith('$prefix/');
}
