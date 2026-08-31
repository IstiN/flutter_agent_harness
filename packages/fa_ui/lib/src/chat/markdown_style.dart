import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ExecutionEnv;
import 'package:flutter_markdown/flutter_markdown.dart';

import '../theme/app_theme.dart';

/// The app's shared [MarkdownStyleSheet]: theme text with the landing
/// palette's teal links, mono inline code, and bordered code blocks /
/// quotes — resolved per brightness, so the light theme gets the light
/// palette. Used by the chat transcript and the file browser's Markdown
/// preview so both render Markdown identically.
///
/// [fontSize] overrides the body size (the chat text-size setting); every
/// style scales by the same factor so headings keep their proportions.
/// Sizes are EXPLICIT, never inherited: the current Flutter ships M3 text
/// themes with null fontSize (fromTheme's assert kills debug builds, and
/// release silently collapsed headings to body size). Line height is
/// pinned at 1.35 / 1.3 for headings — the M3 defaults (1.43–1.5) read as
/// double-spaced in a dense chat transcript.
MarkdownStyleSheet fahMarkdownStyleSheet(ThemeData theme, {double? fontSize}) {
  const bodyHeight = 1.35;
  const headingHeight = 1.3;
  final body = fontSize ?? theme.textTheme.bodyMedium?.fontSize ?? 14.0;
  final bodyStyle = (theme.textTheme.bodyMedium ?? const TextStyle())
      .copyWith(fontSize: body, height: bodyHeight);
  TextStyle heading(double factor, FontWeight weight) => bodyStyle.copyWith(
    fontSize: body * factor,
    fontWeight: weight,
    height: headingHeight,
  );
  final isLight = theme.brightness == Brightness.light;
  final teal = isLight ? FahLightPalette.teal : FahPalette.teal;
  final indigo = isLight ? FahLightPalette.indigo : FahPalette.indigo;
  final panelAlt = isLight ? FahLightPalette.panelAlt : FahPalette.panelAlt;
  final border = isLight ? FahLightPalette.border : FahPalette.border;
  final codeBg = isLight ? FahLightPalette.codeBg : FahPalette.codeBg;
  final codeStyle = isLight ? FahLightPalette.mono() : FahPalette.mono();
  // fromTheme asserts a non-null bodyMedium fontSize — hand it a theme
  // whose bodyMedium is guaranteed resolved.
  final safeTheme = theme.copyWith(
    textTheme: theme.textTheme.copyWith(bodyMedium: bodyStyle),
  );
  return MarkdownStyleSheet.fromTheme(safeTheme).copyWith(
    p: bodyStyle,
    a: TextStyle(color: teal, fontSize: body, height: bodyHeight),
    h1: heading(2.0, FontWeight.w700),
    h2: heading(1.6, FontWeight.w700),
    h3: heading(1.35, FontWeight.w600),
    h4: heading(1.15, FontWeight.w600),
    h5: heading(1.0, FontWeight.w600),
    h6: heading(0.95, FontWeight.w500),
    listBullet: bodyStyle,
    code: codeStyle.copyWith(
      fontSize: body * 0.92,
      backgroundColor: codeBg,
    ),
    codeblockDecoration: BoxDecoration(
      color: panelAlt,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: border),
    ),
    codeblockPadding: const EdgeInsets.all(10),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: indigo, width: 3)),
    ),
  );
}

/// Resolves Markdown images that point into the agent's sandbox
/// (`![alt](generated/x.png)`, optionally with a leading `/`) by loading
/// the bytes through the session [ExecutionEnv].
///
/// One resolver per chat surface: loads are memoized so transcript rebuilds
/// do not re-read the sandbox on every frame. Missing, unreadable, or
/// undecodable files degrade to a small dim placeholder line — never a
/// crash or a red error box.
final class SandboxImageResolver {
  /// Creates a resolver reading through [env].
  SandboxImageResolver(this.env);

  /// The sandbox filesystem image paths resolve against.
  final ExecutionEnv env;

  final Map<String, Future<Uint8List?>> _cache = {};

  /// Bytes of the sandbox file at [path] (a leading `/` is stripped), or
  /// null when the file is missing or unreadable.
  Future<Uint8List?> load(String path) {
    final clean = path.startsWith('/') ? path.substring(1) : path;
    return _cache.putIfAbsent(clean, () async {
      final result = await env.readBinaryFile(clean);
      return result.valueOrNull;
    });
  }

  /// A [MarkdownSizedImageBuilder] for `MarkdownBody(sizedImageBuilder: …)`.
  ///
  /// `http(s)` URIs load over the network; `data:` URIs decode inline;
  /// everything else is treated as a sandbox-relative path. Taps on a
  /// successfully loaded image go to [onImageTap] (fullscreen preview).
  MarkdownSizedImageBuilder sizedImageBuilder({
    void Function(Uint8List bytes)? onImageTap,
  }) {
    return (config) {
      final uri = config.uri;
      final alt = config.alt ?? config.title;
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        return _framedNetworkImage(uri, alt: alt);
      }
      if (uri.scheme == 'data') {
        return _framedImage(
          bytes: UriData.parse(uri.toString()).contentAsBytes(),
          alt: alt,
          onTap: onImageTap,
        );
      }
      return image(path: uri.path, alt: alt, onTap: onImageTap);
    };
  }

  /// The inline image for the sandbox file at [path]: a bounded,
  /// rounded-corner thumbnail while loading, the decoded image on success
  /// (tap → [onTap]), or a dim placeholder line on failure.
  Widget image({
    required String path,
    String? alt,
    void Function(Uint8List bytes)? onTap,
    double maxHeight = 320,
  }) {
    return FutureBuilder<Uint8List?>(
      future: load(path),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _loadingBox(context);
        }
        final bytes = snapshot.data;
        if (bytes == null) return _placeholder(context, alt ?? path);
        return _framedImage(
          bytes: bytes,
          alt: alt,
          onTap: onTap,
          maxHeight: maxHeight,
        );
      },
    );
  }

  Widget _framedImage({
    required Uint8List bytes,
    String? alt,
    void Function(Uint8List bytes)? onTap,
    double maxHeight = 320,
  }) {
    Widget child = Image.memory(
      bytes,
      fit: BoxFit.fitWidth,
      errorBuilder: (context, _, _) => _placeholder(context, alt ?? 'image'),
    );
    child = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: child,
      ),
    );
    if (onTap != null) {
      child = GestureDetector(onTap: () => onTap(bytes), child: child);
    }
    return Padding(padding: const EdgeInsets.only(top: 4), child: child);
  }

  Widget _framedNetworkImage(Uri uri, {String? alt}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: Image.network(
            uri.toString(),
            fit: BoxFit.fitWidth,
            errorBuilder: (context, _, _) =>
                _placeholder(context, alt ?? uri.toString()),
          ),
        ),
      ),
    );
  }

  Widget _loadingBox(BuildContext context) {
    final palette = FahColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: palette.panelAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.border),
        ),
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.dim,
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context, String label) {
    final palette = FahColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, size: 14, color: palette.dim),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: palette.mono(color: palette.dim, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// A [MarkdownSizedImageBuilder] over [env] — see [SandboxImageResolver].
///
/// Each call creates a fresh resolver (and cache); surfaces that rebuild
/// often should hold one [SandboxImageResolver] instead.
MarkdownSizedImageBuilder fahSandboxImageBuilder(
  ExecutionEnv env, {
  void Function(Uint8List bytes)? onImageTap,
}) => SandboxImageResolver(env).sizedImageBuilder(onImageTap: onImageTap);

/// Fullscreen, zoomable preview dialog for image [bytes] — shared by the
/// chat screen's Markdown images / `generate_image` tool tiles and the Fa
/// chat overlay.
void showFahImagePreview(BuildContext context, Uint8List bytes) {
  showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(16),
      child: InteractiveViewer(child: Image.memory(bytes)),
    ),
  );
}
