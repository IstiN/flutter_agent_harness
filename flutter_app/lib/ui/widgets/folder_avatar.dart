// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:fa/services/project_mount_env.dart';
import 'package:fa/ui/chats/local_session_folders.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The deterministic folder avatar (yoloit tier-1 port): a rounded SQUARE
/// (radius `radiusFactor`·size, default 0.28) painted with the folder's
/// two-stop HSL gradient and the uppercase first rune of its name in WHITE
/// @ 95% — the saturated palette stops need the constant on-color on every
/// shell. When the folder carries a well-known icon file
/// ([FolderIconResolver]), that image wins. The Telegram compact strip
/// paints its UNSELECTED avatars as circles instead ([circle]).
class FolderAvatar extends StatelessWidget {
  const FolderAvatar({
    super.key,
    required this.seed,
    required this.label,
    this.size = 46,
    this.image,
    this.circle = false,
    this.radiusFactor = 0.28,
  });

  /// Hue seed — the folder identity string (the cwd path).
  final String seed;

  /// The letter shown when no icon image is available.
  final String label;
  final double size;

  /// Optional resolved folder icon (well-known file variant).
  final ImageProvider? image;

  /// Paint the gradient as a circle (the strip's unselected avatar).
  final bool circle;

  /// The rounded-square corner radius as a fraction of [size]. The strip's
  /// selected avatar re-renders as a rounded square at ~25%.
  final double radiusFactor;

  BorderRadius get _radius =>
      BorderRadius.circular(circle ? size / 2 : size * radiusFactor);

  @override
  Widget build(BuildContext context) {
    final (start, end) = folderAvatarGradient(seed);
    final radius = _radius;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [start, end],
        ),
      ),
      alignment: Alignment.center,
      child: image != null
          ? ClipRRect(
              borderRadius: radius,
              child: Image(
                image: image!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _letter(context),
              ),
            )
          : _letter(context),
    );
  }

  Widget _letter(BuildContext context) {
    return Text(
      folderAvatarLetter(label),
      style: TextStyle(
        // Spec: WHITE @ 95% — the same on-color on every theme.
        color: Colors.white.withValues(alpha: .95),
        fontSize: size * 0.52,
        fontWeight: FontWeight.w800,
        height: 1,
      ),
    );
  }
}

/// The host→mount rebase seam behind [FolderIconResolver]: maps a session
/// folder id (a HOST-absolute cwd) onto its path inside the agent's mount
/// namespace (`/project`, `/project/sub`), or null when the folder is not
/// under the ACTIVE mount. Null means the gradient-letter fallback — the
/// sandbox security model forbids raw host IO for anything outside the
/// mount (a HOST path is invisible through [ProjectMountEnv], which only
/// exposes the rebased `/project` segment).
typedef FolderHostToMountPath = String? Function(String folderId);

/// The production seam: walks the env's decorator stack (secrets /
/// session-vars wrappers sit between callers and the mount env, the same
/// walk [SessionCwd] does) and rebases onto the ACTIVE mount's host root —
/// the inverse of [ProjectMountEnv._map] (mount→host). Env without an
/// active mount (or a folder outside it) → null.
String? defaultHostToMountPath(ExecutionEnv env, String folderId) {
  var current = env;
  while (true) {
    if (current case final SecretsExecutionEnv secrets) {
      current = secrets.delegate;
    } else if (current case final SessionVarsExecutionEnv sessionVars) {
      current = sessionVars.delegate;
    } else if (current case final ProjectMountEnv mount) {
      final root = mount.mountedRoot;
      if (root == null || root.isEmpty || folderId.isEmpty) return null;
      if (folderId == root) return projectMountSegment;
      if (folderId.startsWith('$root/')) {
        return '$projectMountSegment/${folderId.substring(root.length + 1)}';
      }
      return null;
    } else {
      return null;
    }
  }
}

/// Resolves a folder's well-known icon file (tier-2 port) through the
/// session environment — at most [candidatePaths] stat/exists probes per
/// folder, never a deep scan — and caches the resolved image per folder
/// (in-memory; the persisted listing index already carries the cwd).
///
/// Probing rides the MOUNT NAMESPACE, not raw host paths: [env] rebases
/// the `/project` segment onto the user-selected host folder, so the
/// resolver probes `/project/<candidate>` through [hostToMountPath]'s
/// host→mount rebase. Folders outside the active mount (or an env without
/// a mount) resolve to null without a single IO probe.
final class FolderIconResolver {
  FolderIconResolver(this.env, {this.hostToMountPath});

  /// Kept SHORT deliberately (IO safety): root + assets/ candidates only.
  static const candidatePaths = [
    'icon.png',
    'favicon.png',
    'logo.png',
    'app_icon.png',
    'assets/icon.png',
    'assets/favicon.png',
  ];

  final ExecutionEnv env;

  /// The host→mount rebase seam; null → [defaultHostToMountPath] (the
  /// env's own ACTIVE mount). Tests fake it to pin the mapping.
  final FolderHostToMountPath? hostToMountPath;

  final Map<String, MemoryImage?> _cache = {};
  final Map<String, Future<MemoryImage?>> _inFlight = {};

  /// The folder's icon image, or null when it has none (the gradient
  /// letter fallback). Cached per folder id and single-flight.
  Future<MemoryImage?> resolve(String folderId) {
    if (folderId.isEmpty) return Future.value(null);
    final cached = _cache[folderId];
    if (cached != null || _cache.containsKey(folderId)) {
      return Future.value(cached);
    }
    return _inFlight[folderId] ??= _resolve(folderId)
      ..whenComplete(() => _inFlight.remove(folderId));
  }

  /// The folder's mount-namespace segment, or null when the folder is not
  /// under the active mount (no probing at all).
  String? _mountSegment(String folderId) {
    final seam = hostToMountPath;
    if (seam != null) return seam(folderId);
    return defaultHostToMountPath(env, folderId);
  }

  Future<MemoryImage?> _resolve(String folderId) async {
    final mountSegment = _mountSegment(folderId);
    if (mountSegment == null || mountSegment.isEmpty) {
      _cache[folderId] = null;
      return null;
    }
    for (final candidate in candidatePaths) {
      final path = '$mountSegment/$candidate';
      try {
        if ((await env.exists(path)).valueOrNull != true) continue;
        final data = (await env.readBinaryFile(path)).valueOrNull;
        if (data == null || data.isEmpty) continue;
        final image = MemoryImage(data);
        _cache[folderId] = image;
        return image;
      } on Object {
        // A hostile/unreadable folder root must never break the listing.
        continue;
      }
    }
    _cache[folderId] = null;
    return null;
  }
}
