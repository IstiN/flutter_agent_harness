import 'dart:convert';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'html_preview_stub.dart' if (dart.library.html) 'html_preview_web.dart';
import 'markdown_style.dart';

/// Files larger than this are never loaded for preview (4 MB).
const int kPreviewReadCapBytes = 4 * 1024 * 1024;

/// Displayed text is truncated to this many characters (~512 KB).
const int kTextPreviewCapChars = 512 * 1024;

const _kImageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp'};
const _kMarkdownExtensions = {'.md', '.markdown'};
const _kHtmlExtensions = {'.html', '.htm'};

/// Builds the in-app rendering surface for an HTML file's [html] markup.
///
/// Defaults to the platform [HtmlFilePreview] (webview on mobile/desktop,
/// sandboxed iframe on web); tests inject a fake because the webview
/// plugin has no platform implementation on the host test runner.
typedef HtmlPreviewBuilder = Widget Function(BuildContext context, String html);

/// Formats a byte count as a short human-readable string.
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Lowercased file extension of [name] (including the dot), or ''.
String fileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

/// Rich rendering offered for [name]'s extension, if any.
_RichKind _richKindFor(String name) {
  final ext = fileExtension(name);
  if (_kMarkdownExtensions.contains(ext)) return _RichKind.markdown;
  if (_kHtmlExtensions.contains(ext)) return _RichKind.html;
  return _RichKind.none;
}

/// Magic-byte sniff for the image formats we preview.
bool _sniffsAsImage(Uint8List bytes) {
  bool startsWith(List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return true; // PNG
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return true; // JPEG
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return true; // GIF8
  // RIFF....WEBP
  return bytes.length >= 12 &&
      startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50;
}

/// Git-style binary heuristic: a NUL byte in the first 8 KB means binary.
bool _looksBinary(Uint8List bytes) {
  final probe = bytes.length < 8192 ? bytes.length : 8192;
  for (var i = 0; i < probe; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

enum _PreviewState { loading, text, image, info, error }

/// Rich rendering available for a text file beyond the raw source view.
enum _RichKind {
  /// Plain text: source view only, no toggle.
  none,

  /// Markdown: rendered via `flutter_markdown` with the app's stylesheet.
  markdown,

  /// HTML: rendered via the platform [HtmlFilePreview].
  html,
}

/// Which pane of a rich text preview is shown.
enum _TextViewMode { preview, source }

/// Read-only preview of a single file in an [ExecutionEnv].
///
/// Text files render as scrollable monospace (truncated past
/// [kTextPreviewCapChars]); Markdown (`.md`/`.markdown`) and HTML
/// (`.html`/`.htm`) files additionally get a Preview|Source toggle — the
/// preview renders formatted Markdown or the page itself, the source is
/// the monospace view. Images (by extension and magic bytes) render via
/// [Image.memory]; anything else shows an info placeholder. Used embedded
/// in the wide-layout file panel and inside [FilePreviewScreen] on narrow
/// layouts.
class FilePreviewView extends StatefulWidget {
  const FilePreviewView({
    super.key,
    required this.env,
    required this.path,
    required this.name,
    this.htmlPreviewBuilder,
  });

  /// The environment to read the file from.
  final ExecutionEnv env;

  /// Path of the file in [env]'s namespace.
  final String path;

  /// Display name (basename) of the file.
  final String name;

  /// Override for the HTML rendering surface; tests inject a fake because
  /// the webview plugin has no platform implementation on the host.
  final HtmlPreviewBuilder? htmlPreviewBuilder;

  @override
  State<FilePreviewView> createState() => _FilePreviewViewState();
}

class _FilePreviewViewState extends State<FilePreviewView> {
  _PreviewState _state = _PreviewState.loading;
  String? _text;
  bool _truncated = false;
  Uint8List? _imageBytes;
  int _size = 0;
  String? _message;

  /// Rich rendering available for the loaded text file (by extension).
  _RichKind _richKind = _RichKind.none;

  /// Which pane is shown when [_richKind] offers a rendered preview.
  _TextViewMode _viewMode = _TextViewMode.preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final infoResult = await widget.env.fileInfo(widget.path);
      if (!mounted) return;
      final info = infoResult.valueOrNull;
      if (info == null) {
        _showError(
          infoResult.errorOrNull?.message ?? context.l10n.filePreviewCannotStat,
        );
        return;
      }
      _size = info.size;
      if (info.size > kPreviewReadCapBytes) {
        _showInfo(context.l10n.filePreviewTooLarge);
        return;
      }
      final bytesResult = await widget.env.readBinaryFile(widget.path);
      if (!mounted) return;
      final bytes = bytesResult.valueOrNull;
      if (bytes == null) {
        _showError(
          bytesResult.errorOrNull?.message ??
              context.l10n.filePreviewCannotRead,
        );
        return;
      }
      if (_kImageExtensions.contains(fileExtension(widget.name))) {
        if (!_sniffsAsImage(bytes)) {
          _showInfo(context.l10n.filePreviewNoPreview);
        } else {
          setState(() {
            _imageBytes = bytes;
            _state = _PreviewState.image;
          });
        }
        return;
      }
      if (_looksBinary(bytes)) {
        _showInfo(context.l10n.filePreviewNoPreview);
        return;
      }
      var text = utf8.decode(bytes, allowMalformed: true);
      final truncated = text.length > kTextPreviewCapChars;
      if (truncated) text = text.substring(0, kTextPreviewCapChars);
      setState(() {
        _text = text;
        _truncated = truncated;
        _richKind = _richKindFor(widget.name);
        _state = _PreviewState.text;
      });
    } on Object catch (e) {
      // Defensive: the FileSystem contract says operations never throw, but
      // a broken backend must not take down the browser UI.
      if (mounted) _showError(e.toString());
    }
  }

  void _showError(String message) {
    setState(() {
      _message = message;
      _state = _PreviewState.error;
    });
  }

  void _showInfo(String message) {
    setState(() {
      _message = message;
      _state = _PreviewState.info;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (_state) {
      _PreviewState.loading => const Center(child: CircularProgressIndicator()),
      _PreviewState.error => _CenteredMessage(
        icon: Icons.error_outline,
        iconColor: theme.colorScheme.error,
        title: context.l10n.filePreviewLoadError,
        detail: _message,
      ),
      _PreviewState.info => _CenteredMessage(
        icon: Icons.insert_drive_file_outlined,
        title: widget.name,
        detail: '${formatFileSize(_size)} — $_message',
      ),
      _PreviewState.image => InteractiveViewer(
        child: Center(
          child: Image.memory(
            _imageBytes!,
            errorBuilder: (context, error, stackTrace) => _CenteredMessage(
              icon: Icons.broken_image_outlined,
              title: context.l10n.filePreviewDecodeError,
            ),
          ),
        ),
      ),
      _PreviewState.text => _buildTextPreview(theme),
    };
  }

  /// Text preview: raw monospace source, plus a Preview|Source toggle and
  /// a rendered pane for Markdown/HTML files.
  Widget _buildTextPreview(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_richKind != _RichKind.none)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: SegmentedButton<_TextViewMode>(
                segments: [
                  ButtonSegment(
                    value: _TextViewMode.preview,
                    label: Text(context.l10n.filePreviewTabPreview),
                  ),
                  ButtonSegment(
                    value: _TextViewMode.source,
                    label: Text(context.l10n.filePreviewTabSource),
                  ),
                ],
                selected: {_viewMode},
                onSelectionChanged: (selection) =>
                    setState(() => _viewMode = selection.first),
              ),
            ),
          ),
        if (_truncated)
          Container(
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              context.l10n.filePreviewTruncated(
                formatFileSize(kTextPreviewCapChars),
              ),
              style: theme.textTheme.labelSmall,
            ),
          ),
        Expanded(
          child: _showSource
              ? _buildSourceView(theme)
              : _buildRichPreview(theme),
        ),
      ],
    );
  }

  bool get _showSource =>
      _richKind == _RichKind.none || _viewMode == _TextViewMode.source;

  /// The rendered pane for Markdown/HTML files.
  Widget _buildRichPreview(ThemeData theme) {
    return switch (_richKind) {
      _RichKind.markdown => SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: MarkdownBody(
          data: _text!,
          selectable: true,
          styleSheet: fahMarkdownStyleSheet(theme),
        ),
      ),
      _RichKind.html => _buildHtmlPreview(context),
      _RichKind.none => _buildSourceView(
        theme,
      ), // unreachable, keeps switch total
    };
  }

  Widget _buildHtmlPreview(BuildContext context) {
    final builder =
        widget.htmlPreviewBuilder ??
        (context, html) => HtmlFilePreview(html: html);
    return builder(context, _text!);
  }

  /// The raw monospace view used for plain text and the Source pane.
  Widget _buildSourceView(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        _text!,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Courier', 'monospace'],
        ),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.title,
    this.detail,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: iconColor ?? theme.disabledColor),
            const SizedBox(height: 12),
            Text(
              title,
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(
                detail!,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Full-screen wrapper around [FilePreviewView], pushed as a route on narrow
/// layouts.
///
/// When [fsRevision] is provided, the preview reloads itself whenever the
/// revision changes (the agent may have mutated the viewed file) — the new
/// [ValueKey] forces a fresh [FilePreviewView] that re-reads the file.
class FilePreviewScreen extends StatelessWidget {
  const FilePreviewScreen({
    super.key,
    required this.env,
    required this.path,
    required this.name,
    this.htmlPreviewBuilder,
    this.fsRevision,
  });

  /// The environment to read the file from.
  final ExecutionEnv env;

  /// Path of the file in [env]'s namespace.
  final String path;

  /// Display name (basename) of the file.
  final String name;

  /// Override for the HTML rendering surface; tests inject a fake because
  /// the webview plugin has no platform implementation on the host.
  final HtmlPreviewBuilder? htmlPreviewBuilder;

  /// Agent filesystem revision (see `AgentService.fsRevision`); bumps
  /// reload the viewed file. `null` disables auto-reload.
  final ValueListenable<int>? fsRevision;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name, overflow: TextOverflow.ellipsis)),
      body: SafeArea(
        child: fsRevision == null
            ? _preview(0)
            : ValueListenableBuilder<int>(
                valueListenable: fsRevision!,
                builder: (context, revision, _) => _preview(revision),
              ),
      ),
    );
  }

  Widget _preview(int revision) {
    return FilePreviewView(
      key: ValueKey('$path#$revision'),
      env: env,
      path: path,
      name: name,
      htmlPreviewBuilder: htmlPreviewBuilder,
    );
  }
}
