// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/material.dart';

import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/markdown_style.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:fa/ui/widgets/chat_message_tile.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/media_player.dart';

/// The session chat bottom sheet floating over the apps launcher (narrow
/// home). Two states, following the [FaChatOverlay] pattern/constants:
///
/// - **Collapsed**: a floating Fa button bottom-right (tap → expand); while
///   the active session streams, the [FaWorkBar] takes its place (pull-up or
///   its expand button opens the sheet).
/// - **Expanded**: a 92% bottom sheet — drag-handle header with the session
///   title (via [SessionNamesStore], like the sidebar) and a 3-dots menu
///   (New session / Open full chat / Collapse), a horizontal [PageView]
///   paging the live sessions (page change → `manager.switchTo`), the
///   embedded [FaWorkBar] status row, and the shared [ChatComposer].
///
/// Collapsing happens via the menu, a pull-down on the header (past 48px or
/// a 300px/s fling), or a pull-down on the work bar.
class SessionChatSheet extends StatefulWidget {
  const SessionChatSheet({
    super.key,
    required this.manager,
    this.registry,
    this.lastConnectionStore,
    this.sessionNamesStore,
    this.uploadPicker,
    this.asr,
    this.asrTranscriber,
    this.audioControllerFactory,
    this.videoControllerFactory,
  });

  /// The multi-session manager paged by the expanded sheet.
  final FlutterSessionManager manager;

  /// Forwarded to the full chat screen ("Open full chat" menu action).
  final ProviderRegistry? registry;

  /// Forwarded to the full chat screen ("Open full chat" menu action).
  final LastConnectionStore? lastConnectionStore;

  /// The user-given session titles shown in the header; `null` loads the
  /// store from the env (like the session sidebar).
  final SessionNamesStore? sessionNamesStore;

  /// Forwarded to the composer (and the full chat screen).
  final UploadPicker? uploadPicker;

  /// Microphone backend override for the composer (tests).
  final AsrApi? asr;

  /// Transcriber override for the composer (tests).
  final AsrTranscriber? asrTranscriber;

  /// Playback engine factory for inline audio players in the transcript.
  final SandboxAudioControllerFactory? audioControllerFactory;

  /// Playback engine factory for inline video players in the transcript.
  final SandboxVideoControllerFactory? videoControllerFactory;

  @override
  State<SessionChatSheet> createState() => _SessionChatSheetState();
}

class _SessionChatSheetState extends State<SessionChatSheet> {
  /// Travel (px) beyond which a header release collapses the sheet.
  static const double _dragThreshold = 48;

  /// Downward fling velocity (px/s) that collapses on its own.
  static const double _flingVelocity = 300;

  /// How far the header visually follows the finger before resisting.
  static const double _maxDragTravel = 120;

  bool _expanded = false;
  late final PageController _pager;
  SessionNamesStore? _namesStore;
  double _dragOffset = 0;
  bool _dragging = false;

  List<FlutterManagedSession> get _sessions => widget.manager.sessions;

  AgentService? get _activeService => widget.manager.active?.service;

  @override
  void initState() {
    super.initState();
    _pager = PageController(initialPage: _activeIndex(_sessions));
    _namesStore = widget.sessionNamesStore;
    _namesStore?.addListener(_onNamesChanged);
    if (_namesStore == null) unawaited(_loadNamesStore());
    widget.manager.addListener(_onManagerChanged);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _namesStore?.removeListener(_onNamesChanged);
    _pager.dispose();
    super.dispose();
  }

  Future<void> _loadNamesStore() async {
    final service = _activeService;
    if (service == null) return;
    final store = await SessionNamesStore.load(service.env);
    if (!mounted || _namesStore != null) return;
    setState(() => _namesStore = store..addListener(_onNamesChanged));
  }

  void _onNamesChanged() {
    if (mounted) setState(() {});
  }

  int _activeIndex(List<FlutterManagedSession> sessions) {
    final activeId = widget.manager.activeId;
    final index = sessions.indexWhere((s) => s.id == activeId);
    return index < 0 ? 0 : index;
  }

  /// External active-session changes (menu New session, another surface's
  /// switch) keep the pager on the active session.
  void _onManagerChanged() {
    if (!mounted) return;
    final sessions = _sessions;
    final index = _activeIndex(sessions);
    if (_pager.hasClients && sessions.isNotEmpty) {
      final current = _pager.page?.round() ?? _pager.initialPage;
      if (current != index && index < sessions.length) {
        _pager.jumpToPage(index);
      }
    }
    setState(() {});
  }

  void _expand() => setState(() => _expanded = true);

  void _collapse() => setState(() => _expanded = false);

  Future<void> _newSession() async {
    final manager = widget.manager;
    final source = manager.active?.service;
    final config =
        source?.configForClone ??
        manager.sessions.firstOrNull?.service.configForClone;
    if (source == null || config == null) return;
    await manager.createSession(
      config: config,
      serviceFactory: () async => source.clone(),
    );
  }

  Future<void> _openFullChat() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          manager: widget.manager,
          registry: widget.registry,
          lastConnectionStore: widget.lastConnectionStore,
          uploadPicker: widget.uploadPicker,
          asr: widget.asr,
          asrTranscriber: widget.asrTranscriber,
          audioControllerFactory: widget.audioControllerFactory,
          videoControllerFactory: widget.videoControllerFactory,
        ),
      ),
    );
  }

  // Pull-down on the header collapses the sheet (same constants as the
  // FaChatOverlay's header): it follows the finger and springs back unless
  // the drag passes the threshold or ends in a downward fling.
  void _onHeaderDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragging = true;
      _dragOffset = (_dragOffset + details.delta.dy).clamp(0.0, _maxDragTravel);
    });
  }

  void _onHeaderDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_dragOffset >= _dragThreshold || velocity >= _flingVelocity) {
      _collapse();
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
    final service = _activeService;
    if (service == null) return const SizedBox.shrink();
    if (!_expanded) {
      return ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          if (service.isStreaming) {
            // Full-width compact status bar (it renders only while
            // streaming) — pull-up or the expand button opens the sheet.
            return Align(
              alignment: Alignment.bottomCenter,
              child: FaWorkBar(
                service: service,
                onSend: service.sendText,
                onExpand: _expand,
              ),
            );
          }
          return Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 24),
              child: _FaLauncherButton(onTap: _expand),
            ),
          );
        },
      );
    }
    return _buildExpanded(context, service);
  }

  Widget _buildExpanded(BuildContext context, AgentService service) {
    final colors = FahColors.of(context);
    final sessions = _sessions;
    // The same panel as the collapsed FaWorkBar, grown: identical side and
    // bottom margins, radius, surface, border, and shadow — one component
    // in two states, never two stacked cards.
    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        widthFactor: 1,
        heightFactor: 0.92,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: colors.panelAlt.withValues(alpha: 0.97),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
                bottom: Radius.circular(16),
              ),
              border: Border.all(color: colors.border),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  _buildHeader(colors, service),
                  Divider(height: 1, color: colors.border),
                  Expanded(
                    child: PageView.builder(
                      key: const ValueKey('sessionChatPager'),
                      controller: _pager,
                      itemCount: sessions.length,
                      onPageChanged: (index) {
                        if (index < sessions.length) {
                          widget.manager.switchTo(sessions[index].id);
                        }
                      },
                      itemBuilder: (context, index) => _SessionTranscript(
                        key: ValueKey(
                          'sessionTranscript:${sessions[index].id}',
                        ),
                        service: sessions[index].service,
                        audioControllerFactory: widget.audioControllerFactory,
                        videoControllerFactory: widget.videoControllerFactory,
                      ),
                    ),
                  ),
                  Divider(height: 1, color: colors.border),
                  FaWorkBar(
                    service: service,
                    onCollapse: _collapse,
                    embedded: true,
                  ),
                  ChatComposer(
                    service: service,
                    uploadPicker: widget.uploadPicker,
                    asr: widget.asr,
                    asrTranscriber: widget.asrTranscriber,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(FahColors colors, AgentService service) {
    final activeId = widget.manager.activeId ?? '';
    final title =
        _namesStore?.titleFor(activeId) ??
        context.l10n.sidebarSessionTitle(
          activeId.length > 8 ? activeId.substring(0, 8) : activeId,
        );
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
              key: const ValueKey('sessionChatSheetHandle'),
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
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                PopupMenuButton<String>(
                  key: const ValueKey('sessionChatMenu'),
                  icon: const Icon(Icons.more_vert, size: 20),
                  tooltip: context.l10n.launcherChatActionsTooltip,
                  color: colors.panelAlt,
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'new',
                      child: Text(context.l10n.sidebarNewSessionTooltip),
                    ),
                    PopupMenuItem(
                      value: 'full',
                      child: Text(context.l10n.appsOpenFullChatTooltip),
                    ),
                    PopupMenuItem(
                      value: 'collapse',
                      child: Text(context.l10n.appsCollapseChatTooltip),
                    ),
                  ],
                  onSelected: (value) {
                    switch (value) {
                      case 'new':
                        unawaited(_newSession());
                      case 'full':
                        unawaited(_openFullChat());
                      case 'collapse':
                        _collapse();
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The collapsed state's floating Fa button (bottom-right of the launcher):
/// a brand-gradient circle with the Fa mark; tap expands the sheet.
class _FaLauncherButton extends StatelessWidget {
  const _FaLauncherButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Material(
      key: const ValueKey('sessionChatFaButton'),
      shape: const CircleBorder(),
      elevation: 8,
      color: colors.panelAlt,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Ink(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colors.border),
          ),
          child: Tooltip(
            message: context.l10n.appsOpenChatTooltip,
            child: const Center(child: FaMark(size: 26)),
          ),
        ),
      ),
    );
  }
}

/// One session's transcript page inside the pager: user bubbles, Markdown
/// answers, thinking notes, compact tool lines — the shared
/// [ChatMessageTile] renderer, pinned to the tail on new content.
class _SessionTranscript extends StatefulWidget {
  const _SessionTranscript({
    super.key,
    required this.service,
    this.audioControllerFactory,
    this.videoControllerFactory,
  });

  final AgentService service;
  final SandboxAudioControllerFactory? audioControllerFactory;
  final SandboxVideoControllerFactory? videoControllerFactory;

  @override
  State<_SessionTranscript> createState() => _SessionTranscriptState();
}

class _SessionTranscriptState extends State<_SessionTranscript>
    with AutomaticKeepAliveClientMixin {
  final _scrollController = ScrollController();

  /// Loads sandbox images referenced from Markdown through the session's
  /// env (memoized — see [SandboxImageResolver]).
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
  void dispose() {
    widget.service.removeListener(_scrollToEnd);
    _scrollController.dispose();
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

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final colors = FahColors.of(context);
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final messages = widget.service.messages;
        if (messages.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                context.l10n.launcherChatEmptyHint,
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
          itemBuilder: (context, index) {
            final message = messages[index];
            return ChatMessageTile(
              message: message,
              images: _images,
              compact: true,
              audioControllerFactory: widget.audioControllerFactory,
              videoControllerFactory: widget.videoControllerFactory,
            );
          },
        );
      },
    );
  }
}
