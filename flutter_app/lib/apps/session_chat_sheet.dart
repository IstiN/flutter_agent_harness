// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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
/// home). One continuous component driven by a single animation value:
///
/// - **Mini** (default): a compact bottom bar — drag handle, the Fa mark,
///   an inline input and send/expand buttons. Always visible, so a quick
///   message never needs the full sheet; pull up (or tap the expand icon)
///   to grow.
/// - **Expanded**: the same panel grown to 92% — drag-handle header with
///   the session title (via [SessionNamesStore]) and a 3-dots menu (New
///   session / Open full chat / Collapse), a horizontal [PageView] paging
///   live AND persisted sessions (page change → `manager.switchTo`, or
///   opens a persisted one lazily), the embedded [FaWorkBar] status row,
///   and the shared [ChatComposer].
///
/// The transition is physics-y: the mini bar and the full sheet are two
/// layers — the sheet slides up from below while the mini bar fades — so
/// expand/collapse is a smooth animated morph, and a vertical drag on the
/// handle zone moves the whole thing with the finger (release flings to
/// the nearest state).
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

class _SessionChatSheetState extends State<SessionChatSheet>
    with SingleTickerProviderStateMixin {
  /// Diameter of the fully-collapsed round Fa button.
  static const double _iconSize = 56;

  /// Height of the mini state (handle + composer row) without safe area.
  static const double _miniHeight = 100;

  /// Expanded height as a fraction of the screen.
  static const double _expandedFraction = 0.92;

  /// Animation value where the mini state sits (icon 0 → mini → sheet 1).
  static const double _miniValue = 0.3;

  /// Downward/upward fling velocity (px/s) that completes the gesture.
  static const double _flingVelocity = 300;

  late final AnimationController _anim;
  late final PageController _pager;
  SessionNamesStore? _namesStore;

  /// Persisted (on-disk, not live) sessions merged into the pager after the
  /// live ones — the sidebar's merge, so swiping reaches every session.
  List<SessionMetadata> _persisted = const [];
  var _openingPersisted = false;

  /// One-shot guard for the stream-start auto-grow to the mini state.
  var _autoMini = false;

  List<FlutterManagedSession> get _liveSessions => widget.manager.sessions;

  AgentService? get _activeService => widget.manager.active?.service;

  bool get _isExpanded => _anim.value > 0.5;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _pager = PageController(initialPage: _activeIndex());
    _namesStore = widget.sessionNamesStore;
    _namesStore?.addListener(_onChanged);
    if (_namesStore == null) unawaited(_loadNamesStore());
    widget.manager.addListener(_onManagerChanged);
    unawaited(_reloadPersisted());
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _namesStore?.removeListener(_onChanged);
    _pager.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadNamesStore() async {
    final service = _activeService;
    if (service == null) return;
    final store = await SessionNamesStore.load(service.env);
    if (!mounted || _namesStore != null) return;
    setState(() => _namesStore = store..addListener(_onChanged));
  }

  /// The disk-persisted sessions minus the live ones, oldest-positioned
  /// after the live pages (the session sidebar's merge).
  Future<void> _reloadPersisted() async {
    final service = _activeService;
    if (service == null) return;
    try {
      final all = await service.listSessions();
      final liveIds = _liveSessions.map((s) => s.id).toSet();
      final persisted = [
        for (final metadata in all)
          if (!liveIds.contains(metadata.id)) metadata,
      ];
      if (mounted) setState(() => _persisted = persisted);
    } on Object {
      // A broken sessions dir must not break the sheet.
    }
  }

  /// Pager entries: live sessions first, then persisted-only metadata.
  int get _pageCount => _liveSessions.length + _persisted.length;

  int _activeIndex() {
    final activeId = widget.manager.activeId;
    final index = _liveSessions.indexWhere((s) => s.id == activeId);
    return index < 0 ? 0 : index;
  }

  /// External active-session changes (menu New session, another surface's
  /// switch) keep the pager on the active session.
  void _onManagerChanged() {
    if (!mounted) return;
    final index = _activeIndex();
    if (_pager.hasClients && _liveSessions.isNotEmpty) {
      final current = _pager.page?.round() ?? _pager.initialPage;
      if (current != index && index < _liveSessions.length) {
        _pager.jumpToPage(index);
      }
    }
    setState(() {});
  }

  void _onPageChanged(int index) {
    if (index < _liveSessions.length) {
      widget.manager.switchTo(_liveSessions[index].id);
      return;
    }
    final metadata = _persisted[index - _liveSessions.length];
    if (_openingPersisted) return;
    _openingPersisted = true;
    () async {
      try {
        final active = _activeService;
        if (active == null) return;
        await widget.manager.openSession(
          metadata,
          config:
              active.configForClone ??
              AgentConfig(
                providerKind: active.providerKind,
                modelId: active.modelId,
                baseUrl: '',
                apiKey: '',
              ),
          serviceFactory: () async => active.clone(),
        );
      } finally {
        _openingPersisted = false;
      }
    }();
  }

  Future<void> _expand() => _anim.animateTo(
    1,
    duration: const Duration(milliseconds: 260),
    curve: Curves.easeOutCubic,
  );

  Future<void> _collapse() => _anim.animateTo(
    0,
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeInCubic,
  );

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

  // --- the drag: the whole panel follows the finger ------------------------

  double get _sheetPixels {
    final screenH = MediaQuery.sizeOf(context).height;
    return screenH * _expandedFraction;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _anim.stop();
    _anim.value = (_anim.value - details.delta.dy / _sheetPixels).clamp(
      0.0,
      1.0,
    );
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (velocity <= -_flingVelocity) {
      unawaited(_expand());
    } else if (velocity >= _flingVelocity) {
      unawaited(_collapse());
    } else {
      // Nearest state: icon (0), mini bar (_miniValue), full sheet (1).
      final v = _anim.value;
      final target = v < _miniValue / 2
          ? 0.0
          : (v < (_miniValue + 1) / 2 ? _miniValue : 1.0);
      unawaited(
        _anim.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  void _onDragCancel() {
    unawaited(_anim.value < (_miniValue + 1) / 2 ? _collapse() : _expand());
  }

  @override
  Widget build(BuildContext context) {
    final service = _activeService;
    if (service == null) return const SizedBox.shrink();
    final colors = FahColors.of(context);
    final size = MediaQuery.sizeOf(context);
    final expandedH = size.height * _expandedFraction;
    // ONE panel, three states driven by a single value: round Fa button
    // (0) ↔ mini bar (handle + status + composer, _miniValue) ↔ full sheet
    // (1). The container's height/width/radius lerp; the body inside is an
    // OverflowBox pinned to the BOTTOM, so the composer row never moves —
    // only the messages area above it stretches.
    return Align(
      alignment: Alignment.bottomRight,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final v = _anim.value;
          final miniT = (v / _miniValue).clamp(0.0, 1.0);
          final sheetT = ((v - _miniValue) / (1 - _miniValue)).clamp(0.0, 1.0);
          // Icon (56px) → mini (natural body height) → sheet (92%). The
          // mini state's height is the body's own, so the status row and
          // composer are never clipped out of the panel. While streaming
          // the icon state is skipped entirely (the mini body shows).
          final double? height = (v < _miniValue * 0.7 && !service.isStreaming)
              ? _iconSize
              : (sheetT > 0
                    ? _miniHeight + (expandedH - _miniHeight) * sheetT
                    : null);
          final width = sheetT > 0 || miniT >= 1
              ? size.width
              : _iconSize + (size.width - _iconSize) * miniT;
          final radius = sheetT > 0 || miniT >= 1
              ? const BorderRadius.vertical(top: Radius.circular(16))
              : BorderRadius.circular(28 - 12 * miniT);
          return Padding(
            padding: EdgeInsets.only(
              right: (1 - miniT) * 16,
              bottom: (1 - miniT) * 16,
            ),
            child: Container(
              width: width,
              height: height,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: colors.panelAlt.withValues(alpha: 0.97),
                borderRadius: radius,
                border: Border(top: BorderSide(color: colors.border)),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 12,
                    offset: Offset(0, -2),
                  ),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                child: ClipRect(
                  // Rebuild on service events too (streaming flips the
                  // status row and hides the collapsed icon).
                  child: ListenableBuilder(
                    listenable: service,
                    builder: (context, _) {
                      // Fa starts working while hidden: grow to the mini
                      // state so the status row and composer are usable.
                      if (service.isStreaming &&
                          _anim.value < _miniValue - 0.01 &&
                          !_autoMini) {
                        _autoMini = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            unawaited(
                              _anim.animateTo(
                                _miniValue,
                                duration: const Duration(milliseconds: 260),
                                curve: Curves.easeOutCubic,
                              ),
                            );
                          }
                        });
                      } else if (!service.isStreaming) {
                        _autoMini = false;
                      }
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          if (sheetT > 0)
                            OverflowBox(
                              maxWidth: size.width,
                              maxHeight: expandedH,
                              alignment: Alignment.bottomRight,
                              child: _panelContent(colors, service, v, sheetT),
                            )
                          else
                            OverflowBox(
                              maxWidth: size.width,
                              alignment: Alignment.bottomRight,
                              child: _panelContent(colors, service, v, sheetT),
                            ),
                          // The round Fa button (collapsed state): fills
                          // the 56px container, NOT the overflowed body.
                          if (v < _miniValue * 0.7 && !service.isStreaming)
                            GestureDetector(
                              key: const ValueKey('sessionChatFaButton'),
                              behavior: HitTestBehavior.opaque,
                              onTap: () => unawaited(_expand()),
                              onVerticalDragUpdate: _onDragUpdate,
                              onVerticalDragEnd: _onDragEnd,
                              onVerticalDragCancel: _onDragCancel,
                              child: const Center(child: FaMark(size: 26)),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The one continuous body: drag handle, the expanded zone (header +
  /// session pager, appearing with [sheetT]), the streaming status row, and
  /// the always-fixed [ChatComposer] at the bottom.
  Widget _panelContent(
    FahColors colors,
    AgentService service,
    double v,
    double sheetT,
  ) {
    // No body below the icon threshold (the container is too small for the
    // composer); while Fa starts working the auto-grow animates the panel
    // to the mini state within 260 ms and the body fades in there.
    if (v < _miniValue * 0.7) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // A tap anywhere outside the interactive children opens the sheet.
      onTap: () => unawaited(_expand()),
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      onVerticalDragCancel: _onDragCancel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(colors),
          if (sheetT > 0) ...[
            Opacity(opacity: sheetT, child: _buildHeader(colors, service)),
            Divider(height: 1, color: colors.border),
            Expanded(child: _buildPager()),
            Divider(height: 1, color: colors.border),
          ] else
            const SizedBox(height: 4),
          if (service.isStreaming)
            FaWorkBar(
              service: service,
              onExpand: _expand,
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
    );
  }

  /// The session pager (live + persisted sessions) — the expanded zone.
  Widget _buildPager() {
    return PageView.builder(
      key: const ValueKey('sessionChatPager'),
      controller: _pager,
      itemCount: _pageCount,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) => index < _liveSessions.length
          ? _SessionTranscript(
              key: ValueKey('sessionTranscript:${_liveSessions[index].id}'),
              service: _liveSessions[index].service,
              audioControllerFactory: widget.audioControllerFactory,
              videoControllerFactory: widget.videoControllerFactory,
            )
          : _PersistedPage(
              key: ValueKey(
                'persistedPage:${_persisted[index - _liveSessions.length].id}',
              ),
              metadata: _persisted[index - _liveSessions.length],
              namesStore: _namesStore,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
                      unawaited(_collapse());
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _handle(FahColors colors) {
    return Container(
      key: const ValueKey('sessionChatSheetHandle'),
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: colors.dim.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  BoxDecoration _panelDecoration(FahColors colors) => BoxDecoration(
    color: colors.panelAlt.withValues(alpha: 0.97),
    borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
    border: Border(top: BorderSide(color: colors.border)),
    boxShadow: const [
      BoxShadow(color: Colors.black38, blurRadius: 12, offset: Offset(0, -2)),
    ],
  );
}

/// A pager page for a persisted (not yet opened) session: opening it is in
/// flight (the page change opens it lazily via the manager).
class _PersistedPage extends StatelessWidget {
  const _PersistedPage({super.key, required this.metadata, this.namesStore});

  final SessionMetadata metadata;
  final SessionNamesStore? namesStore;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final id = metadata.id;
    final title =
        namesStore?.titleFor(id) ??
        context.l10n.sidebarSessionTitle(
          id.length > 8 ? id.substring(0, 8) : id,
        );
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            context.l10n.appsFaStatusWorking,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.dim),
          ),
        ],
      ),
    );
  }
}

/// One session's transcript page inside the pager: the shared
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
