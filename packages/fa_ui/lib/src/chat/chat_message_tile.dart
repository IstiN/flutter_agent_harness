// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../theme/app_theme.dart';
import 'chat_strings.dart';
import 'fa_chat_service.dart';
import 'markdown_style.dart';
import 'media_player.dart';
import 'media_tool_names.dart';

/// Builds the leading avatar for a transcript message [role] (`user` /
/// `assistant` / `system` / `tool`); return null for roles without one.
typedef FaChatAvatarBuilder =
    Widget? Function(BuildContext context, String role);

/// One transcript message, rendered the same way on every chat surface: the
/// full chat screen (through its `flutter_chat_ui` builders) and the in-app
/// Fa chat overlay both delegate to this widget, so user bubbles, assistant
/// Markdown (with sandbox images), thinking notes, tool tiles and system
/// lines never drift apart.
///
/// The chat screen passes [compact] = false (its list owns the outer
/// spacing through the chat theme); the overlay passes true for the tighter
/// padding its bottom panel needs.
class ChatMessageTile extends StatelessWidget {
  const ChatMessageTile({
    super.key,
    required this.message,
    required this.images,
    this.audioControllerFactory,
    this.videoControllerFactory,
    this.avatarBuilder,
    this.compact = false,
  });

  /// The message to render (`user` / `assistant` / `thinking` / `tool` /
  /// `system`).
  final FaChatMessage message;

  /// Sandbox image/byte loader shared by the surface (memoized — one per
  /// transcript, see [SandboxImageResolver]).
  final SandboxImageResolver images;

  /// Playback engine factory for inline audio players; null uses the real
  /// `audioplayers`-backed controller. Tests/goldens inject fakes.
  final SandboxAudioControllerFactory? audioControllerFactory;

  /// Playback engine factory for inline video players; null uses the real
  /// `video_player`-backed controller. Tests/goldens inject fakes.
  final SandboxVideoControllerFactory? videoControllerFactory;

  /// Leading-widget builder for non-user bubbles (e.g. the host's brand
  /// avatar for `assistant`); a null return (or a null builder) renders no
  /// leading widget — the stock look.
  final FaChatAvatarBuilder? avatarBuilder;

  /// Tighter outer spacing for the in-app Fa overlay, whose panel already
  /// pads the transcript list.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tile = switch (message.role) {
      'user' => _textBubble(context, isUser: true),
      'assistant' => _textBubble(context, isUser: false),
      'thinking' => _thinkingTile(context),
      // 'tool', 'system' and anything else.
      _ => _toolOrSystemTile(context),
    };
    if (!compact) return tile;
    return switch (message.role) {
      'user' => Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(left: 48, bottom: 8),
          child: tile,
        ),
      ),
      'assistant' => Padding(
        padding: const EdgeInsets.only(right: 24, bottom: 8),
        child: tile,
      ),
      _ => Padding(padding: const EdgeInsets.only(bottom: 8), child: tile),
    };
  }

  Widget _textBubble(BuildContext context, {required bool isUser}) {
    // Empty assistant bubbles (model returned no text) render as nothing —
    // they would otherwise show as a blank gray rectangle between tool calls.
    if (message.content.trim().isEmpty && !isUser) {
      return const SizedBox.shrink();
    }
    final styleSheet = fahMarkdownStyleSheet(Theme.of(context));
    final palette = fahChatColorsOf(context);
    final border = Theme.of(context).dividerColor;

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isUser ? palette.userBubble : palette.panel,
        border: Border.all(color: isUser ? palette.userBubbleBorder : border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: MarkdownBody(
        data: message.content,
        selectable: true,
        styleSheet: styleSheet,
        // Sandbox paths (`![alt](generated/x.png)`) load through the
        // session env; taps open the fullscreen preview.
        sizedImageBuilder: images.sizedImageBuilder(
          onImageTap: (bytes) => showFahImagePreview(context, bytes),
        ),
        // Audio/video sandbox links open a small inline-player dialog.
        onTapLink: (text, href, title) =>
            _onMarkdownLink(context, text, href, title),
      ),
    );
    final avatar = isUser ? null : avatarBuilder?.call(context, message.role);
    if (avatar == null) return bubble;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        avatar,
        const SizedBox(width: 8),
        Flexible(child: bubble),
      ],
    );
  }

  /// `onTapLink` for chat Markdown: audio/video sandbox links open a small
  /// player dialog (flutter_markdown has no custom link renderer — only
  /// images render inline). Other links stay dead, as before.
  void _onMarkdownLink(
    BuildContext context,
    String text,
    String? href,
    String title,
  ) {
    if (href == null) return;
    final kind = sandboxMediaKind(href);
    if (kind == null) return;
    showFahMediaDialog(
      context,
      bytes: images.load(href),
      kind: kind,
      audioControllerFactory: audioControllerFactory,
      videoControllerFactory: videoControllerFactory,
    );
  }

  Widget _thinkingTile(BuildContext context) {
    final palette = fahChatColorsOf(context);
    return Container(
      margin: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.panelAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.psychology_outlined, size: 14, color: palette.dim),
          const SizedBox(width: 6),
          Expanded(
            // Reasoning can run to thousands of lines (and small models
            // sometimes loop there) — collapse like long tool output, but
            // keep the NEWEST reasoning visible (the tail, not the head).
            child: _CollapsibleToolOutput(
              content: message.content,
              showTail: true,
              style: palette
                  .mono(color: palette.dim, fontSize: 12)
                  .copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolOrSystemTile(BuildContext context) {
    final toolName = message.toolName;
    final content = message.content;
    final isError = message.isError;
    final palette = fahChatColorsOf(context);
    // generate_image results carry the saved sandbox path — show the image
    // inline under the tool tile instead of waiting for the model to
    // reference it. Errors ("Error: …") simply don't match.
    final generatedImagePath = toolName == generateImageToolName
        ? _generatedImagePath(content)
        : null;
    // speak/generate_music (and any non-read tool result mentioning a
    // media path) get an inline audio/video player under the tile.
    final toolMedia = _toolMedia(toolName, content, isError);

    return Container(
      margin: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.panelAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isError
              ? palette.error.withValues(alpha: 0.45)
              : Theme.of(context).dividerColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (toolName != null) ...[
            Row(
              children: [
                Icon(
                  isError ? Icons.close : Icons.check,
                  size: 14,
                  color: isError ? palette.error : palette.teal,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '[ $toolName ]',
                    overflow: TextOverflow.ellipsis,
                    style: palette.mono(
                      color: isError ? palette.error : palette.indigo,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (content.isNotEmpty) const SizedBox(height: 6),
          ],
          if (content.isNotEmpty)
            toolName == null
                // System rows (e.g. tool-call echoes) read like shell input:
                // a teal `$` prompt followed by dim mono text.
                ? Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: r'$ ',
                          style: palette.mono(color: palette.teal),
                        ),
                        TextSpan(
                          text: content,
                          style: palette.mono(color: palette.dim),
                        ),
                      ],
                    ),
                  )
                : _CollapsibleToolOutput(
                    content: content,
                    style: palette.mono(color: palette.dim),
                  ),
          if (generatedImagePath != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: images.image(
                  path: generatedImagePath,
                  onTap: (bytes) => showFahImagePreview(context, bytes),
                ),
              ),
            ),
          if (toolMedia != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: switch (toolMedia.kind) {
                  SandboxMediaKind.audio => SandboxAudioPlayer(
                    bytes: images.load(toolMedia.path),
                    controllerFactory: audioControllerFactory,
                  ),
                  SandboxMediaKind.video => SandboxVideoPlayer(
                    path: toolMedia.path,
                    bytes: images.load(toolMedia.path),
                    controllerFactory: videoControllerFactory,
                  ),
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Extracts the saved sandbox path from a `generate_image` tool result
/// (`Generated image saved to <path> (<n> bytes, …)`); null for errors
/// or any other text.
final _generatedImagePathPattern = RegExp(
  r'Generated image saved to (\S+\.png)',
);

String? _generatedImagePath(String content) =>
    _generatedImagePathPattern.firstMatch(content)?.group(1);

/// Extracts the saved sandbox path from a `speak` / `generate_music`
/// tool result (`Speech saved to <path> …` / `Music saved to <path> …`);
/// null for errors or any other text.
String? _generatedAudioPath(String toolName, String content) {
  final prefix = switch (toolName) {
    speakToolName => 'Speech saved to ',
    generateMusicToolName => 'Music saved to ',
    _ => null,
  };
  if (prefix == null || !content.startsWith(prefix)) return null;
  return mediaPathInText(content, audioFileExtensions);
}

/// The sandbox media path a successful tool result should render an
/// inline player for: explicit for `speak`/`generate_music`, otherwise
/// any path-like token with a media extension (`.mp3/.wav/.m4a` → audio,
/// `.mp4/.mov/.webm` → video). The `read` tool is NEVER sniffed — it
/// legitimately prints file paths as text (same exclusion as images).
({SandboxMediaKind kind, String path})? _toolMedia(
  String? toolName,
  String content,
  bool isError,
) {
  if (toolName == null || toolName == 'read' || isError) return null;
  final audioPath = _generatedAudioPath(toolName, content);
  if (audioPath != null) {
    return (kind: SandboxMediaKind.audio, path: audioPath);
  }
  final fallbackAudio = mediaPathInText(content, audioFileExtensions);
  if (fallbackAudio != null) {
    return (kind: SandboxMediaKind.audio, path: fallbackAudio);
  }
  final videoPath = mediaPathInText(content, videoFileExtensions);
  if (videoPath != null) {
    return (kind: SandboxMediaKind.video, path: videoPath);
  }
  return null;
}

/// Tool-output block that caps long dumps (file reads, big writes) at a few
/// lines with an expand/collapse toggle — keeps the transcript scannable
/// while the full output stays one tap away.
class _CollapsibleToolOutput extends StatefulWidget {
  const _CollapsibleToolOutput({
    required this.content,
    required this.style,
    this.showTail = false,
  });

  final String content;
  final TextStyle style;

  /// Collapse to the LAST lines instead of the first — used for thinking
  /// bubbles, where the newest reasoning matters more than the preamble.
  final bool showTail;

  /// Outputs longer than this collapse by default.
  static const int collapsedLineCount = 8;
  static const int longLineThreshold = 12;
  static const int longCharThreshold = 700;

  @override
  State<_CollapsibleToolOutput> createState() => _CollapsibleToolOutputState();
}

class _CollapsibleToolOutputState extends State<_CollapsibleToolOutput> {
  bool _expanded = false;

  bool get _isLong {
    final lines = widget.content.split('\n');
    return lines.length > _CollapsibleToolOutput.longLineThreshold ||
        widget.content.length > _CollapsibleToolOutput.longCharThreshold;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLong) {
      return Text(widget.content, style: widget.style);
    }
    final palette = FahColors.of(context);
    final strings = FaChatStrings.of(context);
    final lines = widget.content.split('\n');
    final shown = _expanded
        ? lines
        : widget.showTail
        ? lines
              .skip(
                lines.length > _CollapsibleToolOutput.collapsedLineCount
                    ? lines.length - _CollapsibleToolOutput.collapsedLineCount
                    : 0,
              )
              .toList()
        : lines.take(_CollapsibleToolOutput.collapsedLineCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(shown.join('\n'), style: widget.style),
        const SizedBox(height: 4),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 14,
                color: palette.indigo,
              ),
              const SizedBox(width: 4),
              Text(
                _expanded
                    ? strings.chatCollapse
                    : strings.chatShowAll(lines.length.toString()),
                style: palette.mono(color: palette.indigo, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
