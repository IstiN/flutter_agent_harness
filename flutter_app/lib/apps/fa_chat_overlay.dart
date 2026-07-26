// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/markdown_style.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/ui/widgets/media_player.dart';

/// Expanded in-place Fa chat panel for a JS app view: anchored to the bottom
/// of the view's stack (full width, ~92% of its height), it shows the bound
/// session's transcript — user bubbles, Markdown answers, thinking notes,
/// compact tool lines — plus the streaming status bar and an always-visible
/// composer, so the user chats with Fa without leaving the app.
///
/// Collapsing back to the app chrome happens via the header button, a
/// pull-down drag on the header, or a pull-down on the [FaWorkBar] footer
/// (all fire [onCollapse]); [onOpenFullChat] keeps the old behavior of
/// leaving the app for the full chat screen.
class FaChatOverlay extends StatefulWidget {
  const FaChatOverlay({
    super.key,
    required this.service,
    this.onSend,
    this.onCollapse,
    this.onOpenFullChat,
  });

  /// The session whose transcript and streaming status the panel shows.
  final AgentService service;

  /// Sends a message to the agent (the caller attaches the app state +
  /// screenshot when useful). Null hides nothing — the composer stays but
  /// its send action is disabled.
  final Future<void> Function(String text)? onSend;

  /// Collapses the panel back to the compact Fa chrome.
  final VoidCallback? onCollapse;

  /// Leaves the app view for the full chat screen.
  final VoidCallback? onOpenFullChat;

  @override
  State<FaChatOverlay> createState() => _FaChatOverlayState();
}

class _FaChatOverlayState extends State<FaChatOverlay> {
  /// Travel (px) beyond which a header release collapses the panel.
  static const double _dragThreshold = 48;

  /// Downward fling velocity (px/s) that collapses on its own.
  static const double _flingVelocity = 300;

  /// How far the header visually follows the finger before resisting.
  static const double _maxDragTravel = 120;

  final _scrollController = ScrollController();
  final _inputController = TextEditingController();
  bool _sending = false;
  double _dragOffset = 0;
  bool _dragging = false;

  /// Loads sandbox images referenced from Markdown through the bound
  /// session's env (memoized — see [SandboxImageResolver]).
  SandboxImageResolver? _sandboxImages;

  SandboxImageResolver get _images {
    final env = widget.service.env;
    final resolver = _sandboxImages;
    if (resolver == null || resolver.env != env) {
      return _sandboxImages = SandboxImageResolver(env);
    }
    return resolver;
  }

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_scrollToEnd);
  }

  @override
  void didUpdateWidget(covariant FaChatOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_scrollToEnd);
      widget.service.addListener(_scrollToEnd);
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_scrollToEnd);
    _scrollController.dispose();
    _inputController.dispose();
    super.dispose();
  }

  /// New transcript content keeps the view pinned to the latest message.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.maxScrollExtent > position.pixels) {
        position.jumpTo(position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    final onSend = widget.onSend;
    if (text.isEmpty || onSend == null || _sending) return;
    setState(() => _sending = true);
    try {
      _inputController.clear();
      await onSend(text);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // Pull-down on the header collapses the panel: it follows the finger
  // (clamped, like the FaWorkBar's pull) and springs back unless the drag
  // passes the threshold or ends in a downward fling.
  void _onHeaderDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragging = true;
      _dragOffset = (_dragOffset + details.delta.dy).clamp(0.0, _maxDragTravel);
    });
  }

  void _onHeaderDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_dragOffset >= _dragThreshold || velocity >= _flingVelocity) {
      widget.onCollapse?.call();
    }
    setState(() {
      _dragging = false;
      _dragOffset = 0;
    });
  }

  void _onHeaderDragCancel() {
    setState(() {
      _dragging = false;
      _dragOffset = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = FahColors.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        widthFactor: 1,
        heightFactor: 0.92,
        child: Container(
          decoration: BoxDecoration(
            color: colors.panelAlt.withValues(alpha: 0.97),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(color: colors.border),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 20,
                offset: Offset(0, -4),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                _buildHeader(colors),
                Divider(height: 1, color: colors.border),
                Expanded(child: _buildTranscript(theme, colors)),
                FaWorkBar(
                  service: widget.service,
                  onCollapse: widget.onCollapse,
                ),
                _buildComposer(colors),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(FahColors colors) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onHeaderDragUpdate,
      onVerticalDragEnd: _onHeaderDragEnd,
      onVerticalDragCancel: _onHeaderDragCancel,
      child: AnimatedContainer(
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _dragOffset, 0),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const ValueKey('faChatOverlayHandle'),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.dim.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const FaMark(size: 18),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 16),
                  tooltip: context.l10n.appsOpenFullChatTooltip,
                  visualDensity: VisualDensity.compact,
                  color: colors.dim,
                  onPressed: widget.onOpenFullChat,
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                  tooltip: context.l10n.appsCollapseChatTooltip,
                  visualDensity: VisualDensity.compact,
                  color: colors.dim,
                  onPressed: widget.onCollapse,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscript(ThemeData theme, FahColors colors) {
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final messages = widget.service.messages;
        if (messages.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                context.l10n.appsChatEmptyHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.dim),
              ),
            ),
          );
        }
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          itemCount: messages.length,
          itemBuilder: (context, index) =>
              _messageTile(theme, colors, messages[index]),
        );
      },
    );
  }

  Widget _messageTile(ThemeData theme, FahColors colors, FahChatMessage m) {
    switch (m.role) {
      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 560),
            margin: const EdgeInsets.only(left: 48, bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: colors.userBubble,
              border: Border.all(color: colors.userBubbleBorder),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              m.content,
              style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
            ),
          ),
        );
      case 'assistant':
        return Padding(
          padding: const EdgeInsets.only(right: 24, bottom: 8),
          child: MarkdownBody(
            data: m.content,
            styleSheet: fahMarkdownStyleSheet(theme),
            // Sandbox paths (`![alt](generated/x.png)`) load through the
            // session env; taps open the fullscreen preview.
            sizedImageBuilder: _images.sizedImageBuilder(
              onImageTap: (bytes) => showFahImagePreview(context, bytes),
            ),
            // Audio/video sandbox links open a small inline-player dialog
            // (same behavior as the full chat screen).
            onTapLink: (text, href, title) {
              if (href == null) return;
              final kind = sandboxMediaKind(href);
              if (kind == null) return;
              showFahMediaDialog(
                context,
                bytes: _images.load(href),
                kind: kind,
              );
            },
          ),
        );
      case 'thinking':
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            m.content,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.dim,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      case 'tool':
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '[${m.toolName}] ✓',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: colors.mono(
              color: m.isError ? colors.error : colors.dim,
              fontSize: 12,
            ),
          ),
        );
      default: // 'system' and anything else
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            m.content.split('\n').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.dim,
              fontSize: 11,
            ),
          ),
        );
    }
  }

  Widget _buildComposer(FahColors colors) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputController,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: context.l10n.appsFollowUpHint,
                  hintStyle: TextStyle(color: colors.dim, fontSize: 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.black26,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                onSubmitted: (_) => unawaited(_send()),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.send, size: 16),
              tooltip: context.l10n.appsSendTooltip,
              visualDensity: VisualDensity.compact,
              color: colors.indigo,
              onPressed: _sending || widget.onSend == null
                  ? null
                  : () => unawaited(_send()),
            ),
          ],
        ),
      ),
    );
  }
}
