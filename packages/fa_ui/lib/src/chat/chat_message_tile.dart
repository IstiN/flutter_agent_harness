// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show authExpiredProvider, stripAuthExpiredMarker;

import '../theme/app_theme.dart';
import 'chat_strings.dart';
import 'fa_chat_service.dart';
import 'fa_glyphs.dart';
import 'markdown_style.dart';
import 'media_player.dart';
import 'media_tool_names.dart';

/// Builds the leading avatar for a transcript message [role] (`user` /
/// `assistant` / `system` / `tool`); return null for roles without one.
typedef FaChatAvatarBuilder =
    Widget? Function(BuildContext context, String role);

/// Called when the user taps an action button on a permission-denied card.
/// [permission] is the service name (e.g. 'calendar', 'contacts', 'home').
/// [action] is 'openSettings' or 'tryAgain'.
typedef FaPermissionActionCallback =
    void Function(String permission, String action);

/// Called when the user taps the "Authorize" button on an auth-expired card.
/// [providerId] is the provider identifier from [authExpiredProvider]
/// (e.g. 'codemie').
typedef FaAuthRecoveryCallback = void Function(String providerId);

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
    this.onPermissionAction,
    this.onAuthRecovery,
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

  /// Called when the user taps a permission card action button ("Open
  /// Settings" or "Try again"). The host should open system settings or
  /// retry the permission request.
  final FaPermissionActionCallback? onPermissionAction;

  /// Called when the user taps the "Authorize" button on an auth-expired
  /// card. The host should launch the provider's SSO/re-authorization flow.
  final FaAuthRecoveryCallback? onAuthRecovery;

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
      // AI messages can carry long code/report text: let the bubble span
      // 90% of the viewport instead of a cramped fixed 560px cap. User
      // bubbles keep the compact fixed width.
      constraints: BoxConstraints(
        maxWidth: isUser ? 560 : MediaQuery.sizeOf(context).width * 0.9,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isUser ? palette.userBubble : palette.panel,
        // Light theme: AI bubbles use subtle shadow instead of border,
        // matching the prototype's card style. Dark theme keeps the border.
        border: Theme.of(context).brightness == Brightness.light && !isUser
            ? null
            : Border.all(color: isUser ? palette.userBubbleBorder : border),
        borderRadius: BorderRadius.circular(12),
        boxShadow: Theme.of(context).brightness == Brightness.light && !isUser
            ? [
                BoxShadow(
                  color: const Color(0xFF000000).withValues(alpha: 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 1),
                ),
                BoxShadow(
                  color: const Color(0xFF000000).withValues(alpha: 0.06),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: SelectionArea(
        // ONE selection region for the whole bubble: MarkdownBody's own
        // `selectable: true` creates an independent region per block, so a
        // drag stopped at every paragraph boundary. The SelectionArea
        // handles selection; the body renders non-selectable Markdown.
        child: MarkdownBody(
          data: message.content,
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
      ),
    );
    final avatar = isUser
        ? null
        : (avatarBuilder?.call(context, message.role) ??
              _defaultAiAvatar(context));
    // The raw-content copy button: hover-revealed on desktop for text
    // bubbles, always visible in tool tile headers.
    final withCopy = _wrapWithCopyButton(context, bubble, alwaysVisible: false);
    if (avatar == null) return withCopy;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        avatar,
        const SizedBox(width: 8),
        Flexible(child: withCopy),
      ],
    );
  }

  /// The default AI avatar: the Fa brand `>_` tile ([FaAiAvatar]) — the
  /// launcher brand-tile language, not a stock sparkle. Shown when no
  /// [avatarBuilder] is provided.
  Widget _defaultAiAvatar(BuildContext context) {
    return const FaAiAvatar(size: 28);
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
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      margin: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isLight
            ? const Color(0xFFF9FAFB)
            : palette.panelAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: isLight
            ? null
            : Border.all(
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
    final isLight = Theme.of(context).brightness == Brightness.light;

    // Permission-denied tool results get a special card: orange badge +
    // action buttons (Open Settings / Try again) matching the prototype.
    // We check the CONTENT, not just isError — some tools return the denial
    // as a plain text result, not an error. AND the tool name: arbitrary
    // tool results whose body text happens to mention 'X access required'
    // (e.g. a `read` of a skill that documents the permission flow) keep
    // the normal collapsible tile instead of hijacking the visual.
    if (_isPermissionError(toolName: toolName, content: content)) {
      return _permissionCard(
        context,
        palette,
        content,
        isLight,
        onPermissionAction,
      );
    }

    // Auth-expired provider errors (SSO session expired) get a special card
    // with an Authorize button that re-launches the SSO flow.
    final expiredProvider = authExpiredProvider(content);
    if (expiredProvider != null) {
      return _authExpiredCard(
        context,
        palette,
        content,
        isLight,
        expiredProvider,
        onAuthRecovery,
      );
    }

    return Container(
      margin: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // Light theme: very subtle gray bg without border; dark theme: bordered.
        color: isLight ? const Color(0xFFF9FAFB) : palette.panelAlt,
        borderRadius: BorderRadius.circular(10),
        border: isLight
            ? (isError
                  ? Border.all(color: palette.error.withValues(alpha: 0.3))
                  : null)
            : Border.all(
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
                  color: isError
                      ? palette.error
                      : (isLight ? palette.indigo : palette.teal),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    // Prototype style: "Checked Calendar" not "[ calendar ]".
                    // Capitalize the tool name and prefix with a verb.
                    _toolDisplayName(toolName),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isError ? palette.error : palette.indigo,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                // Dropdown arrow like the prototype's tool rows.
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: palette.dim.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 8),
                // Copy the RAW tool output (the whole body, not a
                // selection) — tool output is the thing users most often
                // need verbatim.
                _CopyIconButton(
                  text: content,
                  color: palette.dim.withValues(alpha: 0.7),
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
                // Tool output is selectable text (one region for the whole
                // tile — the collapsible body used to swallow selection).
                : SelectionArea(
                    child: _CollapsibleToolOutput(
                      content: content,
                      style: palette.mono(color: palette.dim),
                    ),
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

  /// Wraps [child] with a hover-revealed raw-copy button (desktop): the
  /// icon appears at the bubble's top-right on pointer enter, clicking
  /// copies the message's FULL raw content (markdown source, not the
  /// rendered text).
  Widget _wrapWithCopyButton(
    BuildContext context,
    Widget child, {
    required bool alwaysVisible,
  }) {
    if (message.content.trim().isEmpty) return child;
    return _HoverCopyWrap(
      copy: message.content,
      alwaysVisible: alwaysVisible,
      child: child,
    );
  }
}

/// Hover-reveal copy affordance for a message: the button sits at the
/// bubble's top-right, invisible until the pointer enters the area
/// (desktop pattern; [alwaysVisible] shows it permanently).
class _HoverCopyWrap extends StatefulWidget {
  const _HoverCopyWrap({
    required this.copy,
    required this.alwaysVisible,
    required this.child,
  });

  final String copy;
  final bool alwaysVisible;
  final Widget child;

  @override
  State<_HoverCopyWrap> createState() => _HoverCopyWrapState();
}

class _HoverCopyWrapState extends State<_HoverCopyWrap> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final show = widget.alwaysVisible || _hovering;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (show)
            Positioned(
              // Sits half-outside the bubble's padding: breathing room
              // from the text without covering the first line.
              top: -6,
              right: -6,
              child: _CopyIconButton(
                text: widget.copy,
                color: FahColors.of(context).dim.withValues(alpha: 0.7),
              ),
            ),
        ],
      ),
    );
  }
}

/// The copy icon itself: Clipboard.setData + a transient "copied" tick.
class _CopyIconButton extends StatefulWidget {
  const _CopyIconButton({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  State<_CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<_CopyIconButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final strings = FaChatStrings.of(context);
    return Tooltip(
      message: _copied
          ? strings.chatMessageCopiedToClipboard
          : strings.chatCopyMessageTooltip,
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        padding: const EdgeInsets.all(5),
        iconSize: 14,
        color: widget.color,
        onPressed: _copy,
        icon: Icon(_copied ? Icons.check : Icons.copy_rounded),
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

/// Converts a tool name to a prototype-style display string:
/// "calendar_events" → "Checked Calendar", "read" → "Read file", etc.
String _toolDisplayName(String toolName) {
  const verbMap = {
    'read': 'Read',
    'write': 'Wrote',
    'edit': 'Patched',
    'bash': 'Ran',
    'calendar_events': 'Checked Calendar',
    'calendar_calendars': 'Checked Calendar',
    'calendar_add': 'Added to Calendar',
    'calendar_update': 'Updated Calendar',
    'calendar_delete': 'Deleted from Calendar',
    'home_devices': 'Listed Devices',
    'home_turn_on': 'Turned On',
    'home_turn_off': 'Turned Off',
    'home_set': 'Set',
    'generate_image': 'Generated Image',
    'speak': 'Generated Speech',
    'generate_music': 'Generated Music',
    'generate_video': 'Generated Video',
    'open_app': 'Opened App',
    'search': 'Searched',
    'web_search': 'Searched',
    'web_fetch': 'Fetched',
  };
  final verb = verbMap[toolName];
  if (verb != null) return verb;
  // Fallback: capitalize each word.
  return toolName
      .split('_')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

/// Whether a tool error is a permission/access denial (calendar, contacts,
/// Tool names whose denial surface renders as a permission card instead of
/// a generic tool tile. Adding a new OS-permission tool = adding it here.
const _permissionToolNames = <String>{
  // Calendar (EventKit).
  'calendar_events',
  'calendar_calendars',
  'calendar_add',
  'calendar_update',
  'calendar_delete',
  // Home (HomeKit).
  'home_devices',
  'home_turn_on',
  'home_turn_off',
  'home_set',
  // Health (HealthKit).
  'health_summary',
  // Contacts.
  'contacts_search',
  'contacts_add',
  'contacts_call',
  'contacts_sms',
  // Notifications / microphone / media library (future agents).
  'notify',
  'microphone',
  'media',
};

/// True for tool results that should render as the orange permission card:
/// the tool is one that can require an OS permission AND the content text
/// matches the permission-denial signature.
bool _isPermissionError({required String? toolName, required String content}) {
  final isPermissionTool =
      toolName == null || _permissionToolNames.contains(toolName);
  if (!isPermissionTool) return false;
  final lower = content.toLowerCase();
  return lower.contains('access') &&
      (lower.contains('required') ||
          lower.contains('denied') ||
          lower.contains('permission'));
}

/// A permission-denied card matching the prototype: orange badge +
/// explanatory text + action buttons that actually work.
Widget _permissionCard(
  BuildContext context,
  FahColors palette,
  String content,
  bool isLight,
  FaPermissionActionCallback? onAction,
) {
  final theme = Theme.of(context);
  // Extract the permission name from the error message.
  final match = RegExp(
    r'(\w+)\s+access',
    caseSensitive: false,
  ).firstMatch(content);
  final permName = match?.group(1) ?? 'Calendar';
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: isLight ? Colors.white : palette.panelAlt,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 8,
          offset: const Offset(0, 1),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Orange badge.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 14, color: palette.pending),
              const SizedBox(width: 4),
              Text(
                '$permName access required',
                style: TextStyle(
                  color: palette.pending,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Title.
        Text(
          "I can't access your $permName yet.",
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        // Body text.
        Text(
          content,
          style: theme.textTheme.bodySmall?.copyWith(color: palette.dim),
        ),
        const SizedBox(height: 16),
        // Action buttons.
        Row(
          children: [
            FilledButton.icon(
              onPressed: () => onAction?.call(permName, 'openSettings'),
              icon: const Icon(Icons.lock_open, size: 16),
              label: const Text('Open Settings'),
              style: FilledButton.styleFrom(
                backgroundColor: palette.indigo,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => onAction?.call(permName, 'tryAgain'),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Try again'),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: palette.borderBright),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// An auth-expired card for provider SSO sessions that have expired:
/// red badge + explanatory text + Authorize button. Mirrors the
/// permission-denied card pattern.
Widget _authExpiredCard(
  BuildContext context,
  FahColors palette,
  String content,
  bool isLight,
  String providerId,
  FaAuthRecoveryCallback? onAuthorize,
) {
  final theme = Theme.of(context);
  final displayText = stripAuthExpiredMarker(content);
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: isLight ? Colors.white : palette.panelAlt,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 8,
          offset: const Offset(0, 1),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Red badge.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: palette.error.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.key_off, size: 14, color: palette.error),
              const SizedBox(width: 4),
              Text(
                'Session expired',
                style: TextStyle(
                  color: palette.error,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Title.
        Text(
          'Your $providerId session has expired.',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        // Body text.
        Text(
          displayText,
          style: theme.textTheme.bodySmall?.copyWith(color: palette.dim),
        ),
        const SizedBox(height: 16),
        // Authorize button.
        FilledButton.icon(
          onPressed: () => onAuthorize?.call(providerId),
          icon: const Icon(Icons.login, size: 16),
          label: const Text('Authorize'),
          style: FilledButton.styleFrom(
            backgroundColor: palette.indigo,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    ),
  );
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
