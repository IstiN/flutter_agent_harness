// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:fa/ui/chats/local_session_folders.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The deterministic folder avatar (yoloit tier-1 port): a rounded SQUARE
/// (radius 0.28·size) painted with the folder's two-stop HSL gradient and
/// the uppercase first rune of its name. When the folder carries a
/// well-known icon file ([FolderIconResolver]), that image wins.
class FolderAvatar extends StatelessWidget {
  const FolderAvatar({
    super.key,
    required this.seed,
    required this.label,
    this.size = 46,
    this.image,
  });

  /// Hue seed — the folder identity string (the cwd path).
  final String seed;

  /// The letter shown when no icon image is available.
  final String label;
  final double size;

  /// Optional resolved folder icon (well-known file variant).
  final ImageProvider? image;

  @override
  Widget build(BuildContext context) {
    final (start, end) = folderAvatarGradient(seed);
    final radius = BorderRadius.circular(size * 0.28);
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
    final colors = FahColors.of(context);
    return Text(
      folderAvatarLetter(label),
      style: TextStyle(
        // Spec: theme text primary @ alpha 235.
        color: colors.text.withValues(alpha: 235 / 255),
        fontSize: size * 0.52,
        fontWeight: FontWeight.w800,
        height: 1,
      ),
    );
  }
}

/// Resolves a folder's well-known icon file (tier-2 port) through the
/// session environment — at most [candidatePaths] stat/exists probes per
/// folder, never a deep scan — and caches the resolved image per folder
/// (in-memory; the persisted listing index already carries the cwd).
final class FolderIconResolver {
  FolderIconResolver(this.env);

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

  Future<MemoryImage?> _resolve(String folderId) async {
    for (final candidate in candidatePaths) {
      final path = '$folderId/$candidate';
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
