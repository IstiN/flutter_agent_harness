// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:flutter_agent_harness/flutter_agent_harness.dart' hide KeyEvent;
import 'package:flutter_map/flutter_map.dart' show TileProvider;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/media_tools.dart';
import 'package:fa/services/video_tool.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/markdown_style.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/secret_request_sheet.dart';
import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/fa_chat_overlay.dart';
import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/js_theme.dart';

/// Payload delivered when the user talks to Fa from inside an app: their
/// message, the app's exported state, and a screenshot of the app.
class FaAppMessage {
  const FaAppMessage({
    required this.text,
    this.appId,
    this.appStateJson,
    this.themeLine,
    this.screenshot,
  });

  final String text;

  /// The app the message came from — sessions started inside an app stay
  /// bound to it (`apps/<id>/session.json`).
  final String? appId;
  final String? appStateJson;

  /// Compact one-line theme summary (see [jsThemeSummaryLine]) appended to
  /// the agent message so the model never guesses colors.
  final String? themeLine;
  final Uint8List? screenshot;
}

/// Full-screen host for one JS app: renders the JS-driven UI via
/// [JsonWidgetRenderer], offers reload + permissions in the app bar (or in a
/// floating overlay menu when the app's manifest asks for `chrome: 'full'`),
/// and a floating Fa button that sends the agent a message with the app's
/// current state and a screenshot.
class JsAppView extends StatefulWidget {
  const JsAppView({
    super.key,
    required this.app,
    required this.env,
    required this.permissionsStore,
    this.llmHandler,
    this.platformHandler,
    this.onSendToAgent,
    this.fsRevision,
    this.agentService,
    this.asrTranscriber,
    this.mediaGateway,
    this.videoReader,
    this.mapTileProvider,
  });

  final JsAppInfo app;
  final ExecutionEnv env;
  final AppPermissionsStore permissionsStore;
  final FaLlmHandler? llmHandler;
  final FaPlatformHandler? platformHandler;

  /// Transcriber behind the `jsr.fa.asr.transcribe` bridge call; `null`
  /// derives one from [agentService]'s active provider (an
  /// OpenAI-compatible endpoint), which may still resolve to none.
  final AsrTranscriber? asrTranscriber;

  /// Media generation backend behind the `jsr.fa.media.*` bridge calls;
  /// `null` derives it from [agentService] (the same gateway the agent's
  /// media tools use).
  final MediaGateway? mediaGateway;

  /// Video-reading backend behind `jsr.fa.media.readVideo`; `null` derives
  /// it from [agentService] (the same reader the agent's `read_video` tool
  /// uses).
  final VideoReader? videoReader;

  /// Optional tile provider for `map` nodes — tests inject an offline
  /// provider; null uses the runtime default (OSM over the network).
  final TileProvider? mapTileProvider;

  /// Called with the composed Fa message; typically forwards to
  /// `AgentService.sendImage`/`sendText` of the app-bound session. Returns
  /// the session service that actually received the message — on first
  /// contact that is a NEWLY created app-bound session — so the view can
  /// rebind its Fa chrome (work bar, reply sheet) to it; null keeps the
  /// current binding.
  final Future<AgentService?> Function(FaAppMessage message)? onSendToAgent;

  /// Bumped when the agent edits files (AgentService.fsRevision) — the app
  /// reloads itself so agent-written code shows up live.
  final ValueNotifier<int>? fsRevision;

  /// The active session's service — drives the compact [FaWorkBar] while
  /// the agent runs (status, stop, expand, inline follow-up).
  final AgentService? agentService;

  @override
  State<JsAppView> createState() => _JsAppViewState();
}

class _JsAppViewState extends State<JsAppView> {
  JsAppEngine? _engine;
  Object? _startError;
  final _boundaryKey = GlobalKey();
  bool _faSheetOpen = false;
  Timer? _reloadDebounce;
  int _lastFsRevision = -1;

  /// The session service the Fa chrome (work bar, reply sheet) listens to.
  /// Seeded from [JsAppView.agentService]; rebound to the service returned
  /// by [JsAppView.onSendToAgent] when a send lands in a different session
  /// (first contact creates the app-bound session — without the rebind the
  /// bar never shows and the reply is lost to the chat screen).
  AgentService? _agentService;

  /// The reply shown on the mini reply sheet; null while it is hidden.
  String? _faReply;

  /// The last assistant text already accounted for (shown, or present when
  /// the view opened) — the sheet never re-shows it.
  String? _seenReplyText;

  /// The reply the user dismissed — never re-shown for the same text.
  String? _dismissedReplyText;

  /// Whether the expanded in-place Fa chat panel is showing; while true it
  /// supersedes the compact chrome (work bar, reply sheet, floating Fa
  /// button).
  bool _faChatExpanded = false;

  /// The last theme map handed to the engine (JSON-encoded for cheap
  /// change detection in [didChangeDependencies]).
  String? _themeJson;

  /// Fallback for the PopScope's registration listenable while no engine
  /// is running: no `jsr.onBack`, so the route may pop natively.
  static final ValueNotifier<bool> _noBackHandler = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.screenOpened('js_app');
    _agentService = widget.agentService;
    widget.fsRevision?.addListener(_onFsRevision);
    _agentService?.addListener(_onAgentServiceEvent);
    _seenReplyText = _lastAssistantText(_agentService);
    unawaited(_restart());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Runs before the first build and again on every ambient theme change:
    // push live theme updates into the running JS app (`jsr._onThemeChange`).
    final next = jsonEncode(jsThemeMap(context));
    if (next == _themeJson) return;
    _themeJson = next;
    final engine = _engine;
    if (engine != null) {
      unawaited(engine.updateTheme(jsonDecode(next) as Map<String, dynamic>));
    }
  }

  @override
  void didUpdateWidget(JsAppView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fsRevision != widget.fsRevision) {
      oldWidget.fsRevision?.removeListener(_onFsRevision);
      widget.fsRevision?.addListener(_onFsRevision);
    }
    if (oldWidget.agentService != widget.agentService &&
        widget.agentService != _agentService) {
      _bindAgentService(widget.agentService);
    }
  }

  /// Moves the Fa chrome's listener + reply tracking to [service].
  ///
  /// [fromSend] marks the rebind after OUR send: the run may legitimately
  /// be over already (fast providers) or still streaming — either way the
  /// latest assistant text is the answer the user is waiting for, so the
  /// reply history is NOT pre-seeded as seen and the current state is
  /// evaluated immediately (a finished run shows its reply at once; a
  /// streaming run is caught by the listener when it ends).
  void _bindAgentService(AgentService? service, {bool fromSend = false}) {
    if (service == _agentService) return;
    _agentService?.removeListener(_onAgentServiceEvent);
    _agentService = service;
    _agentService?.addListener(_onAgentServiceEvent);
    setState(() {
      _faReply = null;
      _dismissedReplyText = null;
      _seenReplyText = fromSend ? null : _lastAssistantText(service);
    });
    if (fromSend) _onAgentServiceEvent();
  }

  @override
  void dispose() {
    widget.fsRevision?.removeListener(_onFsRevision);
    _agentService?.removeListener(_onAgentServiceEvent);
    _reloadDebounce?.cancel();
    unawaited(_engine?.dispose() ?? Future.value());
    super.dispose();
  }

  void _onFsRevision() {
    final revision = widget.fsRevision?.value ?? 0;
    if (revision == _lastFsRevision) return;
    _lastFsRevision = revision;
    // Debounce: agent edits often write manifest + widget.js back to back.
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted && !_faSheetOpen) unawaited(_restartIfAppChanged());
    });
  }

  /// The content signature of this app's code files (manifest + entry) at
  /// the last engine start — the view restarts ONLY when its own app
  /// changed, not on every fsRevision bump from unrelated agent writes
  /// (the native context churn behind the TestFlight SIGSEGV).
  String _appSignature = '';

  Future<String> _readAppSignature() async {
    final manifest = (await widget.env.readTextFile(
      widget.app.manifestPath,
    )).valueOrNull;
    final entry = (await widget.env.readTextFile(
      widget.app.widgetPath,
    )).valueOrNull;
    return '${manifest?.length}:${entry?.length}:${manifest?.hashCode}:${entry?.hashCode}';
  }

  Future<void> _restartIfAppChanged() async {
    final signature = await _readAppSignature();
    if (!mounted || signature == _appSignature) return;
    await _restart();
  }

  Future<void> _restart() async {
    // Yield one microtask: on the first call (from initState) this lets
    // didChangeDependencies run first and record _themeJson, so the engine
    // boots with the real theme instead of an empty map. A microtask (not
    // Future(...)/Timer) keeps widget tests' fake-async zone clean.
    await Future<void>.value();
    if (!mounted) return;
    final themeJson = _themeJson;
    final initialTheme = themeJson == null
        ? jsThemeMap(context)
        : jsonDecode(themeJson) as Map<String, dynamic>;
    final old = _engine;
    setState(() {
      _engine = null;
      _startError = null;
    });
    if (old != null) await old.dispose();
    try {
      final effective = widget.permissionsStore.forApp(widget.app).effective();
      final engine = JsAppEngine(
        app: widget.app,
        env: widget.env,
        permissions: effective,
        llmHandler: widget.llmHandler,
        platformHandler: widget.platformHandler,
        asrTranscriber: widget.asrTranscriber ?? await _serviceAsrTranscriber(),
        mediaGateway: widget.mediaGateway ?? widget.agentService?.mediaGateway,
        videoReader: widget.videoReader ?? widget.agentService?.videoReader,
        keysSource: widget.agentService?.hostSecrets,
        keyRequestHandler: _requestHostSecret,
        hostLocale: Localizations.localeOf(context).languageCode,
        initialTheme: initialTheme,
      );
      engine.onCloseRequested = _closeFromJs;
      await engine.start();
      if (!mounted) {
        await engine.dispose();
        return;
      }
      setState(() => _engine = engine);
      // Restart ONLY when this app's files change afterwards (see
      // [_restartIfAppChanged]) — record the signature we booted from.
      _appSignature = await _readAppSignature();
    } on Object catch (error) {
      AppLog.i('apps', 'app start failed: ${widget.app.id} — $error');
      if (mounted) setState(() => _startError = error);
    }
  }

  Future<Uint8List?> _captureScreenshot() async {
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return null;
      // Best effort: a hung capture (headless/test environments) must never
      // eat the user's message — the timeout lands in the catch below.
      final image = await boundary
          .toImage(pixelRatio: 1.5)
          .timeout(const Duration(seconds: 5));
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes?.buffer.asUint8List();
    } on Object {
      return null;
    }
  }

  /// The newest assistant TEXT message in the transcript (tool, system and
  /// thinking entries are skipped); null when there is none.
  static String? _lastAssistantText(AgentService? service) {
    if (service == null) return null;
    for (final message in service.messages.reversed) {
      if (message.role == 'assistant' && message.content.trim().isNotEmpty) {
        return message.content.trim();
      }
    }
    return null;
  }

  /// The `jsr.fa.keys.request` backend: renders the shared secret-request
  /// sheet (the same one the agent's `request_secret` tool uses) and routes
  /// a grant through the session's persist+activate flow, so the key lands
  /// in the Keys store, the shell env, and the redactor exactly like an
  /// agent-requested secret. Null (declined) when there is no session or
  /// the user dismisses the sheet.
  Future<RequestSecretResult?> _requestHostSecret(
    String name,
    String reason,
  ) async {
    final service = widget.agentService;
    if (service == null || !mounted) return null;
    final result = await showSecretRequestSheet(context, name, reason);
    if (result == null) return null;
    return service.acceptSecretGrant(result);
  }

  /// Derives the ASR transcriber through the session's media gateway (the
  /// media_models.json `transcription` slot, falling back to the active
  /// provider); null when no ASR-capable (OpenAI-compatible) endpoint is
  /// configured — the bridge then answers with an actionable error.
  Future<AsrTranscriber?> _serviceAsrTranscriber() async {
    final service = widget.agentService;
    if (service == null) return null;
    final gateway = service.mediaGateway;
    if (gateway != null) return whisperTranscriberForGateway(gateway);
    final config = service.configForClone;
    return whisperTranscriberFor(
      providerKind: service.providerKind,
      baseUrl: config?.baseUrl ?? '',
      apiKey: config?.apiKey ?? '',
    );
  }

  /// Shows the mini reply sheet when a run ENDS with a new assistant text
  /// message; while the run streams the [FaWorkBar] is the indicator and the
  /// sheet stays hidden.
  void _onAgentServiceEvent() {
    final service = _agentService;
    if (service == null || !mounted) return;
    if (service.isStreaming) {
      if (_faReply != null) setState(() => _faReply = null);
      return;
    }
    final reply = _lastAssistantText(service);
    if (reply == null ||
        reply == _seenReplyText ||
        reply == _dismissedReplyText) {
      return;
    }
    _seenReplyText = reply;
    setState(() => _faReply = reply);
  }

  void _dismissFaReply() {
    setState(() {
      _dismissedReplyText = _faReply;
      _faReply = null;
    });
  }

  Future<void> _sendFaMessage(String text) async {
    final onSend = widget.onSendToAgent;
    final trimmed = text.trim();
    if (onSend == null || trimmed.isEmpty) return;
    // A new question hides the mini reply sheet; the work bar takes over.
    if (_faReply != null) setState(() => _faReply = null);
    final state = _engine?.exportedState;
    final screenshot = await _captureScreenshot();
    if (!mounted) return;
    final used = await onSend(
      FaAppMessage(
        text: trimmed,
        appId: widget.app.id,
        appStateJson: state == null ? null : jsonEncode(state),
        themeLine: jsThemeSummaryLine(jsThemeMap(context)),
        screenshot: screenshot,
      ),
    );
    // First contact creates the app-bound session: rebind the Fa chrome so
    // the work bar and the reply sheet follow the session that actually
    // received the message.
    if (mounted && used != null && used != _agentService) {
      _bindAgentService(used, fromSend: true);
    }
  }

  Future<void> _openFaSheet() async {
    if (widget.onSendToAgent == null) return;
    setState(() => _faSheetOpen = true);
    try {
      final message = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _FaMessageSheet(app: widget.app),
      );
      if (message == null || message.trim().isEmpty || !mounted) return;
      await _sendFaMessage(message);
    } finally {
      if (mounted) setState(() => _faSheetOpen = false);
    }
  }

  Future<void> _openPermissions() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => AppPermissionsDialog(
        app: widget.app,
        env: widget.env,
        store: widget.permissionsStore,
      ),
    );
    if (changed == true) await _restart();
  }

  /// A back attempt (system back, edge swipe, app-bar arrow) while the app
  /// has a `jsr.onBack` handler: forward it to JS as the reserved 'back'
  /// event. The app may consume it for internal navigation; otherwise the
  /// bootstrap bridges `back.close` back to us and [_closeFromJs] pops.
  void _forwardBackToApp() {
    final engine = _engine;
    if (engine == null) {
      Navigator.of(context).pop();
      return;
    }
    unawaited(engine.callEvent('back'));
  }

  /// Every hardware key event the host sees while this view is on top is
  /// streamed into the JS app as the reserved 'key' action
  /// ({ key, modifiers, kind: 'down'|'up' }). The widget subscribes via
  /// `jsr.onKey(fn)` — used for app-level shortcuts (arrow-key 2048
  /// moves, WASD movement, Cmd+K palettes). Text fields inside the app
  /// still receive their own keys because we ignore the event after
  /// dispatching, letting the standard focus chain continue.
  KeyEventResult _onAppKeyEvent(FocusNode node, KeyEvent event) {
    final engine = _engine;
    if (engine == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyName = _logicalKeyName(key);
    if (keyName == null) return KeyEventResult.ignored;
    final kind = event is KeyDownEvent ? 'down' : 'up';
    final payload = <String, dynamic>{
      'key': keyName,
      'kind': kind,
      'modifiers': _modifierFlags(),
    };
    unawaited(engine.callEvent('key', payload));
    return KeyEventResult.ignored;
  }

  /// Map a [LogicalKeyboardKey] to the JS-facing name — mirrors the keys
  /// the host can actually deliver: printable characters, named special
  /// keys (ArrowUp, Enter, Backspace, Escape, Tab, Space) and a few common
  /// function keys. Unmapped keys return null so the focus chain handles
  /// them natively (text editing, accessibility shortcuts).
  static String? _logicalKeyName(LogicalKeyboardKey key) {
    final named = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.arrowUp: 'ArrowUp',
      LogicalKeyboardKey.arrowDown: 'ArrowDown',
      LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
      LogicalKeyboardKey.arrowRight: 'ArrowRight',
      LogicalKeyboardKey.enter: 'Enter',
      LogicalKeyboardKey.numpadEnter: 'Enter',
      LogicalKeyboardKey.escape: 'Escape',
      LogicalKeyboardKey.tab: 'Tab',
      LogicalKeyboardKey.backspace: 'Backspace',
      LogicalKeyboardKey.delete: 'Delete',
      LogicalKeyboardKey.home: 'Home',
      LogicalKeyboardKey.end: 'End',
      LogicalKeyboardKey.pageUp: 'PageUp',
      LogicalKeyboardKey.pageDown: 'PageDown',
      LogicalKeyboardKey.space: 'Space',
      LogicalKeyboardKey.f1: 'F1',
      LogicalKeyboardKey.f2: 'F2',
      LogicalKeyboardKey.f3: 'F3',
      LogicalKeyboardKey.f4: 'F4',
      LogicalKeyboardKey.f5: 'F5',
      LogicalKeyboardKey.f6: 'F6',
      LogicalKeyboardKey.f7: 'F7',
      LogicalKeyboardKey.f8: 'F8',
      LogicalKeyboardKey.f9: 'F9',
      LogicalKeyboardKey.f10: 'F10',
      LogicalKeyboardKey.f11: 'F11',
      LogicalKeyboardKey.f12: 'F12',
    };
    final namedHit = named[key];
    if (namedHit != null) return namedHit;
    final char = key.keyLabel;
    if (char.isEmpty || char.length > 1) return null;
    return char;
  }

  /// Synthesize a `ctrl/meta/alt/shift` flag bag from the hardware-keyboard
  /// modifier state. Widget reads it as `payload.modifiers.ctrl` etc.
  static Map<String, bool> _modifierFlags() {
    return <String, bool>{
      'ctrl': HardwareKeyboard.instance.isControlPressed,
      'meta': HardwareKeyboard.instance.isMetaPressed,
      'alt': HardwareKeyboard.instance.isAltPressed,
      'shift': HardwareKeyboard.instance.isShiftPressed,
    };
  }

  /// The JS app declined to consume a back event — close the app. Uses
  /// [Navigator.pop], not maybePop: with canPop false maybePop would just
  /// re-enter the back flow it came from.
  void _closeFromJs() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fullChrome = widget.app.isFullChrome;
    // With a jsr.onBack handler registered the app owns back navigation:
    // the native pop (iOS edge swipe, system back) is vetoed and the
    // attempt forwards to JS instead. Without one the route pops natively.
    return ValueListenableBuilder<bool>(
      valueListenable: _engine?.backHandlerRegistered ?? _noBackHandler,
      builder: (context, backRegistered, _) {
        return PopScope(
          canPop: !backRegistered,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _forwardBackToApp();
          },
          // App-level keyboard capture. Autofocus: the JS app owns the
          // screen and is the natural focus owner — pressing an arrow key
          // should move the in-app cursor (or 2048 tile) without the user
          // first having to tap anywhere. We return `ignored` after
          // dispatching the event so the focus chain keeps delivering
          // text editing to whatever widget is focused inside the engine.
          child: Focus(
            autofocus: true,
            onKeyEvent: _onAppKeyEvent,
            child: Scaffold(
              appBar: fullChrome
                  ? null
                  : AppBar(
                      title: Row(
                        children: [
                          AppIcon(app: widget.app, env: widget.env, size: 24),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              widget.app.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      actions: [
                        IconButton(
                          icon: const Icon(Icons.shield_outlined),
                          tooltip: context.l10n.appsPermissionsTooltip,
                          onPressed: _openPermissions,
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          tooltip: context.l10n.appsReloadTooltip,
                          onPressed: () {
                            AppAnalytics.instance.jsAppReloaded();
                            unawaited(_restart());
                          },
                        ),
                      ],
                    ),
              body: Stack(
                children: [
                  Positioned.fill(
                    child: RepaintBoundary(
                      key: _boundaryKey,
                      child: ColoredBox(
                        color: theme.scaffoldBackgroundColor,
                        // Chrome apps (with the AppBar) keep their content
                        // above the home indicator — HUD rows at the very
                        // bottom must not clip into it. Full-chrome apps (map)
                        // stay edge-to-edge at the bottom but drop below the
                        // status bar: they draw their own opaque header, and
                        // edge-to-edge top slid it under the system tray.
                        child: fullChrome
                            ? SafeArea(bottom: false, child: _buildBody(theme))
                            : SafeArea(top: false, child: _buildBody(theme)),
                      ),
                    ),
                  ),
                  // Full chrome has no AppBar — permissions/reload live in a small
                  // floating menu so immersive apps (maps) keep the whole canvas.
                  if (fullChrome)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: _chromeMenu(theme),
                        ),
                      ),
                    ),
                  if (widget.onSendToAgent != null) ...[
                    if (!_faChatExpanded)
                      Positioned(
                        right: 16,
                        bottom: 16,
                        child: FloatingActionButton.small(
                          heroTag: 'fa-${widget.app.id}',
                          tooltip: context.l10n.appsAskFaTooltip,
                          onPressed: _openFaSheet,
                          child: const FaMark(size: 18),
                        ),
                      ),
                    if (_agentService != null) ...[
                      if (!_faChatExpanded)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: FaWorkBar(
                            service: _agentService!,
                            onSend: _sendFaMessage,
                            onExpand: () =>
                                setState(() => _faChatExpanded = true),
                          ),
                        ),
                      if (!_faChatExpanded && _faReply != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: FaReplySheet(
                            service: _agentService!,
                            reply: _faReply!,
                            onExpand: () =>
                                setState(() => _faChatExpanded = true),
                            onDismiss: _dismissFaReply,
                          ),
                        ),
                      if (_faChatExpanded)
                        Positioned.fill(
                          child: FaChatOverlay(
                            service: _agentService!,
                            onSend: _sendFaMessage,
                            onCollapse: () =>
                                setState(() => _faChatExpanded = false),
                            // Expand-to-full-chat always leaves the app (an
                            // explicit tap, not a back gesture) — pop directly,
                            // bypassing canPop.
                            onOpenFullChat: () => Navigator.of(context).pop(),
                          ),
                        ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The floating app-controls menu used in full chrome: a semi-transparent
  /// circular button (top-right) opening a popup with Permissions and
  /// Reload — the same actions the header AppBar offers.
  Widget _chromeMenu(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.65),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        onSelected: (value) {
          switch (value) {
            case 'permissions':
              unawaited(_openPermissions());
            case 'reload':
              AppAnalytics.instance.jsAppReloaded();
              unawaited(_restart());
            case 'close':
              // Mirror the system-back contract: an app that registered
              // `jsr.onBack` owns the close flow, otherwise pop directly.
              // Full-chrome apps (maps) have no AppBar back arrow and the
              // canvas swallows the iOS edge swipe, so this menu item is
              // their only reliable exit.
              if (_engine?.backHandlerRegistered.value ?? false) {
                _forwardBackToApp();
              } else {
                _closeFromJs();
              }
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'permissions',
            child: Row(
              children: [
                const Icon(Icons.shield_outlined, size: 20),
                const SizedBox(width: 12),
                Text(context.l10n.appsPermissionsTooltip),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'reload',
            child: Row(
              children: [
                const Icon(Icons.refresh, size: 20),
                const SizedBox(width: 12),
                Text(context.l10n.appsReloadTooltip),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'close',
            child: Row(
              children: [
                const Icon(Icons.close, size: 20),
                const SizedBox(width: 12),
                Text(context.l10n.appsCloseTooltip),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final error = _startError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            context.l10n.appsStartError('$error', widget.app.name),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      );
    }
    final engine = _engine;
    if (engine == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: engine.tree,
      builder: (context, tree, _) {
        if (tree == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final renderer = JsonWidgetRenderer(
          theme: JsonWidgetTheme.fromAccent(
            theme.colorScheme.primary,
            brightness: theme.brightness,
          ),
          mapTileProvider: widget.mapTileProvider,
          // 3D scenes: the dispatcher singleton shared with the engine's
          // JsRuntimeConfig (see JsAppEngine.start); taps raycast into
          // `jsr.scene3d.onTap` handlers in the app.
          js3dHost: createJs3dHost(),
          onScene3dTap: (sceneId, payload) =>
              engine.dispatchHostEvent('scene3d.tap:$sceneId', payload),
          onEvent: (actionId, payload) {
            unawaited(engine.callEvent(actionId, payload));
          },
        );
        return ClipRect(child: renderer.build(tree, context));
      },
    );
  }
}

/// Mini reply sheet shown above the [FaWorkBar] when the bound session's
/// run ends with a new assistant text message: a compact card with the Fa
/// mark, the reply rendered as Markdown (the chat's style sheet, capped at
/// five lines with a soft fade at the cut), tap-to-expand-chat and a dismiss
/// button. It slides up and fades in (~200 ms) on appearance; the work bar
/// stays the progress indicator while the run streams.
class FaReplySheet extends StatefulWidget {
  const FaReplySheet({
    super.key,
    required this.service,
    required this.reply,
    this.onExpand,
    this.onDismiss,
  });

  /// The session's service — only used for the orbit treatment: the Fa mark
  /// spins while the agent streams and is static otherwise.
  final AgentService service;

  /// The assistant reply text (Markdown).
  final String reply;

  /// Expands the in-place chat panel when the card body is tapped.
  final VoidCallback? onExpand;

  /// Dismisses the sheet until the next reply.
  final VoidCallback? onDismiss;

  @override
  State<FaReplySheet> createState() => _FaReplySheetState();
}

class _FaReplySheetState extends State<FaReplySheet>
    with SingleTickerProviderStateMixin {
  /// Markdown lines shown before the fade cuts the reply off.
  static const int _maxLines = 5;

  late final AnimationController _orbit;
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    _orbit = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    widget.service.addListener(_syncOrbit);
    _syncOrbit();
    // Entrance: start slightly lowered + transparent, spring up on the
    // first frame so the AnimatedSlide/Fade actually animate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _entered = true);
    });
  }

  @override
  void didUpdateWidget(covariant FaReplySheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_syncOrbit);
      widget.service.addListener(_syncOrbit);
      _syncOrbit();
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_syncOrbit);
    _orbit.dispose();
    super.dispose();
  }

  void _syncOrbit() {
    if (widget.service.isStreaming) {
      if (!_orbit.isAnimating) _orbit.repeat();
    } else if (_orbit.isAnimating) {
      _orbit.stop();
      _orbit.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = FahColors.of(context);
    final styleSheet = fahMarkdownStyleSheet(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.45),
    );
    final textStyle = styleSheet.p;
    final lineHeight =
        (textStyle?.fontSize ?? 13) * (textStyle?.height ?? 1.45);
    final maxHeight = lineHeight * _maxLines;
    return AnimatedSlide(
      offset: _entered ? Offset.zero : const Offset(0, 0.3),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: AnimatedOpacity(
        opacity: _entered ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          decoration: BoxDecoration(
            color: colors.panelAlt.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.border),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onExpand,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: ListenableBuilder(
                        listenable: widget.service,
                        builder: (context, _) => widget.service.isStreaming
                            ? FaOrbitIndicator(animation: _orbit, size: 22)
                            : const FaMark(size: 18),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (rect) {
                          // Uncut replies (shorter than the cap) get a solid
                          // mask; only a reply cut at the cap fades out.
                          if (rect.height < maxHeight - 0.5) {
                            return const LinearGradient(
                              colors: [Colors.white, Colors.white],
                            ).createShader(rect);
                          }
                          return LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white,
                              Colors.white.withValues(alpha: 0),
                            ],
                            stops: [(rect.height - 20) / rect.height, 1.0],
                          ).createShader(rect);
                        },
                        child: ClipRect(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: maxHeight),
                            child: MarkdownBody(
                              data: widget.reply,
                              styleSheet: styleSheet,
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: context.l10n.appsDismissReplyTooltip,
                      visualDensity: VisualDensity.compact,
                      color: colors.dim,
                      onPressed: widget.onDismiss,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet collecting the user's message to Fa about the current app.
class _FaMessageSheet extends StatefulWidget {
  const _FaMessageSheet({required this.app});

  final JsAppInfo app;

  @override
  State<_FaMessageSheet> createState() => _FaMessageSheetState();
}

class _FaMessageSheetState extends State<_FaMessageSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.appsAskFaAbout(widget.app.name),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.appsAskFaSubtitle,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: context.l10n.appsAskFaHint,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.send),
            label: Text(context.l10n.appsSendToFa),
            onPressed: () => Navigator.of(context).pop(_controller.text),
          ),
        ],
      ),
    );
  }
}

/// Per-app permission toggles; writes overrides to [AppPermissionsStore].
class AppPermissionsDialog extends StatefulWidget {
  const AppPermissionsDialog({
    super.key,
    required this.app,
    required this.env,
    required this.store,
  });

  final JsAppInfo app;
  final ExecutionEnv env;
  final AppPermissionsStore store;

  @override
  State<AppPermissionsDialog> createState() => AppPermissionsDialogState();
}

class AppPermissionsDialogState extends State<AppPermissionsDialog> {
  late AppPermissions _current;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _current = widget.store.forApp(widget.app).effective();
  }

  void _set(AppPermissions next) {
    setState(() {
      _current = next;
      _changed = true;
    });
    unawaited(widget.store.setOverride(widget.app.id, next));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Ten toggles + title can exceed small window heights.
      scrollable: true,
      title: Row(
        children: [
          AppIcon(app: widget.app, env: widget.env, size: 22),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              context.l10n.appsPermissionsTitle(widget.app.name),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toggle(
            context.l10n.appsPermissionNetwork,
            context.l10n.appsPermissionNetworkDesc,
            _current.network,
            (v) => _set(_current.copyWith(network: v)),
          ),
          _toggle(
            context.l10n.appsPermissionLlm,
            context.l10n.appsPermissionLlmDesc,
            _current.llm,
            (v) => _set(_current.copyWith(llm: v)),
          ),
          _toggle(
            context.l10n.appsPermissionHomekit,
            context.l10n.appsPermissionHomekitDesc,
            _current.homekit,
            (v) => _set(_current.copyWith(homekit: v)),
          ),
          _toggle(
            context.l10n.appsPermissionHealth,
            context.l10n.appsPermissionHealthDesc,
            _current.health,
            (v) => _set(_current.copyWith(health: v)),
          ),
          _toggle(
            context.l10n.appsPermissionContacts,
            context.l10n.appsPermissionContactsDesc,
            _current.contacts,
            (v) => _set(_current.copyWith(contacts: v)),
          ),
          _toggle(
            context.l10n.appsPermissionCalendar,
            context.l10n.appsPermissionCalendarDesc,
            _current.calendar,
            (v) => _set(_current.copyWith(calendar: v)),
          ),
          _toggle(
            context.l10n.appsPermissionMicrophone,
            context.l10n.appsPermissionMicrophoneDesc,
            _current.microphone,
            (v) => _set(_current.copyWith(microphone: v)),
          ),
          _toggle(
            context.l10n.appsPermissionNotifications,
            context.l10n.appsPermissionNotificationsDesc,
            _current.notifications,
            (v) => _set(_current.copyWith(notifications: v)),
          ),
          _toggle(
            context.l10n.appsPermissionMedia,
            context.l10n.appsPermissionMediaDesc,
            _current.media,
            (v) => _set(_current.copyWith(media: v)),
          ),
          _toggle(
            context.l10n.appsPermissionKeys,
            context.l10n.appsPermissionKeysDesc,
            _current.keys,
            (v) => _set(_current.copyWith(keys: v)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_changed),
          child: Text(context.l10n.appsPermissionsDone),
        ),
      ],
    );
  }

  Widget _toggle(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
      dense: true,
      contentPadding: EdgeInsets.zero,
    );
  }
}
