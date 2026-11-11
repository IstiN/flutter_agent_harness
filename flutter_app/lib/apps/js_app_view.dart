// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fa/apps/app_state_context.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/apps/js_theme_bridge_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa_ui/fa_ui.dart'
    show
        FaChatHost,
        FaChatStrings,
        FaDesignTokens,
        FaDuoControlRail,
        FaHeaderAction,
        FaIconActionBand,
        FaVisualDirection,
        FahColors;
import 'package:flutter_map/flutter_map.dart' show TileProvider;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:fa/apps/fa_js3d_host.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/media_tools.dart';
import 'package:fa/services/video_tool.dart';
import 'package:fa/ui/markdown_style.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/secret_request_sheet.dart';
import 'package:fa/ui/widgets/fa_route_header.dart'
    show FaWindowChrome, faAppBar;
import 'package:fa/ui/widgets/messenger_section_header.dart'
    show MessengerGlassUnderlay;
import 'package:fa/apps/app_icon.dart';
import 'package:fa/apps/fa_media_host.dart';
import 'package:fa/apps/fa_webview_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/fa_chat_overlay.dart';
import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/js_theme.dart';
import 'package:fa/apps/viewport_reporter.dart';

/// Payload delivered when the user talks to Fa from inside an app: their
/// message, the app's exported state, and a screenshot of the app.
class FaAppMessage {
  const FaAppMessage({
    required this.text,
    this.appId,
    this.appStateJson,
    this.themeLine,
    this.viewportLine,
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

  /// One-line viewport summary (logical size, orientation, safe areas —
  /// see [viewportContextLine], issue #692 C) so generated UI fits the
  /// real canvas.
  final String? viewportLine;

  final Uint8List? screenshot;
}

/// Messenger app-panel chrome: Pin, Full/Exit full, and Close are owned by
/// the shell while permissions and reload stay with the app view.
final class JsAppPanelChrome {
  const JsAppPanelChrome({
    required this.fullScreen,
    required this.pinned,
    required this.onFullScreen,
    required this.onPin,
    required this.onClose,
    this.onMinimize,
    this.onBack,
    this.onQuickApps,
  });

  final bool fullScreen;
  final bool pinned;
  final VoidCallback onFullScreen;
  final VoidCallback onPin;
  final VoidCallback onClose;
  final VoidCallback? onMinimize;

  /// Leading minimize action for a shell-presented desktop app; null on the
  /// phone root, where minimize stays in the trailing action capsule.
  final VoidCallback? onBack;

  /// Opens the shell's installed/running app chooser without replacing the
  /// center destination. Exposed as a Duo rail action only.
  final VoidCallback? onQuickApps;
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
    this.mediaHost,
    this.webViewHost,
    this.embeddedInPanel = false,
    this.panelChrome,
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

  /// Media backend for the renderer's `video`/`audio` nodes; `null` wires
  /// the real [FaMediaHost] (video_player/audioplayers). Tests inject
  /// fakes to stay off native plugins.
  final JsMediaHost? mediaHost;

  /// Web-view host for the engine config AND the renderer's `webView`
  /// nodes; `null` uses the platform default (see [createFaWebViewHost] —
  /// a real `flutter_inappwebview` surface on iOS/Android/macOS, the
  /// renderer's placeholder elsewhere). Tests inject fakes to stay off
  /// the native plugin.
  final JsWebViewHost? webViewHost;

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

  /// Whether the app renders inside the wide-shell apps side panel instead
  /// of a standalone full-screen route. The Fa chrome stays available in
  /// either host; embedded apps report their panel canvas as the viewport.
  final bool embeddedInPanel;

  /// Non-null replaces route chrome with the messenger panel header.
  final JsAppPanelChrome? panelChrome;

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
    _reloadDebounce = Timer(const Duration(milliseconds: 600), _reloadWhenIdle);
  }

  /// The debounced restart body (gh-1848 split): only a live view with no
  /// reply sheet open restarts.
  void _reloadWhenIdle() {
    if (mounted && !_faSheetOpen) unawaited(_restartIfAppChanged());
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

  /// Generation of the latest [_restart] call. Overlapping restarts (reload
  /// button + fs-revision debounce + dialog paths) used to each boot an
  /// engine and the last writer won, leaking the others' workers/timers
  /// while the shared lifecycle chain kept the spinner up. A superseded
  /// run now bails out and disposes whatever it already built.
  int _restartGen = 0;

  Future<void> _restart() async {
    final gen = ++_restartGen;
    // Yield one microtask: on the first call (from initState) this lets
    // didChangeDependencies run first and record _themeJson, so the engine
    // boots with the real theme instead of an empty map. A microtask (not
    // Future(...)/Timer) keeps widget tests' fake-async zone clean.
    await Future<void>.value();
    if (_supersededRestart(gen)) return;
    final initialTheme = _initialRestartTheme();
    final old = _engine;
    setState(() {
      _engine = null;
      _startError = null;
    });
    if (old != null) await old.dispose();
    if (_supersededRestart(gen)) return;
    await _bootEngine(initialTheme, gen);
  }

  /// A newer [_restart] call (or an unmounted State) makes this run's
  /// results unwanted — it bails out and disposes whatever it built.
  bool _supersededRestart(int gen) => !mounted || gen != _restartGen;

  Map<String, dynamic> _initialRestartTheme() {
    final themeJson = _themeJson;
    return themeJson == null
        ? jsThemeMap(context)
        : jsonDecode(themeJson) as Map<String, dynamic>;
  }

  Future<void> _bootEngine(Map<String, dynamic> initialTheme, int gen) async {
    try {
      final engine = await _buildEngine(initialTheme);
      engine.onCloseRequested = _closeFromJs;
      await engine.start();
      await _adoptBootedEngine(engine, gen);
    } on Object catch (error) {
      _reportBootFailure(error, gen);
    }
  }

  Future<JsAppEngine> _buildEngine(Map<String, dynamic> initialTheme) async {
    final effective = widget.permissionsStore.forApp(widget.app).effective();
    return JsAppEngine(
      app: widget.app,
      env: widget.env,
      permissions: effective,
      llmHandler: widget.llmHandler,
      platformHandler: widget.platformHandler,
      asrTranscriber:
          widget.asrTranscriber ??
          await widget.agentService?.resolveAsrTranscriber(),
      mediaGateway: widget.mediaGateway ?? widget.agentService?.mediaGateway,
      videoReader: widget.videoReader ?? widget.agentService?.videoReader,
      keysSource: widget.agentService?.hostSecrets,
      keyRequestHandler: _requestHostSecret,
      themeBridge: _themeBridge(),
      webViewHost: widget.webViewHost,
      // ignore: use_build_context_synchronously
      hostLocale: Localizations.localeOf(context).languageCode,
      initialTheme: initialTheme,
    );
  }

  /// A still-current boot owns the surface; a superseded one is disposed.
  Future<void> _adoptBootedEngine(JsAppEngine engine, int gen) async {
    if (_supersededRestart(gen)) {
      await engine.dispose();
      return;
    }
    setState(() => _engine = engine);
    // Restart ONLY when this app's files change afterwards (see
    // [_restartIfAppChanged]) — record the signature we booted from.
    _appSignature = await _readAppSignature();
  }

  void _reportBootFailure(Object error, int gen) {
    AppLog.i('apps', 'app start failed: ${widget.app.id} — $error');
    if (mounted && gen == _restartGen) setState(() => _startError = error);
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
    final service = _mountedAgentService();
    if (service == null) return null;
    final result = await showSecretRequestSheet(context, name, reason);
    if (result == null) return null;
    return service.acceptSecretGrant(result);
  }

  /// The session + mounted guard of the secret-request sheet (gh-1848
  /// split): no sheet can render without an agent session, and the view
  /// must still be on screen.
  AgentService? _mountedAgentService() {
    final service = widget.agentService;
    if (service == null || !mounted) return null;
    return service;
  }

  /// The theme bridge for this app's engine: the installed packs + active
  /// choice from the app scopes, with a consent prompt per apply (issue
  /// #169). Null (no store/controller in scope, e.g. tests) leaves the
  /// `jsr.fa.theme.*` calls answering "not available".
  FaThemeBridge? _themeBridge() {
    final store = ThemePackScope.maybeOf(context);
    final controller = FahThemeScope.maybeOf(context);
    if (store == null || controller == null) return null;
    return FaThemeBridgeHost(
      store: store,
      controller: controller,
      prompt: (pack) async {
        if (!mounted) return false;
        return showThemePackConsent(
          context,
          appName: widget.app.name,
          pack: pack,
        );
      },
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
    // Issue #692 C: the agent designs generated UI for THIS canvas —
    // logical size, orientation and safe areas ride the message.
    final view = View.of(context);
    final pixelRatio = view.devicePixelRatio;
    // In the shell's nested Apps navigator the window also contains the
    // main chat. Report the actual app canvas, just like the screenshot,
    // rather than telling the agent to design for the whole shell.
    final logical = widget.embeddedInPanel
        ? _boundaryKey.currentContext?.size ?? view.physicalSize / pixelRatio
        : view.physicalSize / pixelRatio;
    final padding = MediaQuery.paddingOf(context);
    final used = await onSend(
      FaAppMessage(
        text: trimmed,
        appId: widget.app.id,
        appStateJson: state == null ? null : jsonEncode(state),
        themeLine: jsThemeSummaryLine(jsThemeMap(context)),
        viewportLine: viewportContextLine(
          size: logical,
          orientation: logical.width >= logical.height
              ? Orientation.landscape
              : Orientation.portrait,
          safeAreas: padding,
        ),
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
      final close = widget.panelChrome?.onClose;
      if (close != null) {
        close();
      } else {
        Navigator.of(context).pop();
      }
      return;
    }
    unawaited(engine.callEvent('back'));
  }

  /// The JS app declined to consume a back event — close the app. Uses
  /// [Navigator.pop], not maybePop: with canPop false maybePop would just
  /// re-enter the back flow it came from.
  void _closeFromJs() {
    if (!mounted) return;
    final close = widget.panelChrome?.onClose;
    if (close != null) {
      close();
    } else {
      Navigator.of(context).pop();
    }
  }

  PreferredSizeWidget? _buildAppBar(bool fullChrome) {
    final chrome = widget.panelChrome;
    if (fullChrome && chrome == null) return null;
    if (chrome == null) return _defaultAppBar();
    return _panelAppBar(chrome);
  }

  PreferredSizeWidget _defaultAppBar() {
    return faAppBar(
      context: context,
      title: Row(
        children: [
          AppIcon(app: widget.app, env: widget.env, size: 24),
          const SizedBox(width: 8),
          Flexible(
            child: Text(widget.app.name, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
      trafficLightClearance: FaWindowChrome.presentedAppClearance(
        context,
        embeddedInPanel: widget.embeddedInPanel,
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
    );
  }

  List<FaHeaderAction> _panelChromeActions(
    JsAppPanelChrome chrome,
    double duoRailWidth,
  ) {
    final onBack = chrome.onBack;
    final returnAction = onBack ?? chrome.onMinimize;
    return <FaHeaderAction>[
      if (duoRailWidth > 0 && returnAction != null)
        FaHeaderAction(
          key: const ValueKey('duoAppBack'),
          icon: Icons.arrow_back_ios_new_rounded,
          label: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: returnAction,
        ),
      if (duoRailWidth > 0 && chrome.onQuickApps != null)
        FaHeaderAction(
          key: const ValueKey('appQuickApps'),
          icon: Icons.apps_outlined,
          label: context.l10n.appsQuickOpen,
          onPressed: chrome.onQuickApps!,
        ),
      FaHeaderAction(
        key: const ValueKey('appFull'),
        icon: chrome.fullScreen ? Icons.close_fullscreen : Icons.open_in_full,
        label: chrome.fullScreen
            ? context.l10n.appsExitFullTooltip
            : context.l10n.appsFullTooltip,
        onPressed: chrome.onFullScreen,
      ),
      FaHeaderAction(
        key: const ValueKey('appPin'),
        icon: chrome.pinned ? Icons.push_pin : Icons.push_pin_outlined,
        label: chrome.pinned
            ? context.l10n.appsUnpinTooltip
            : context.l10n.appsPinTooltip,
        onPressed: chrome.onPin,
      ),
      if (onBack == null && duoRailWidth == 0)
        if (chrome.onMinimize case final minimize?)
          FaHeaderAction(
            key: const ValueKey('appMinimize'),
            icon: Icons.remove_rounded,
            label: context.l10n.chatCollapse,
            onPressed: minimize,
          ),
      if (duoRailWidth > 0) ...[
        FaHeaderAction(
          key: const ValueKey('appPermissions'),
          icon: Icons.shield_outlined,
          label: context.l10n.appsPermissionsTooltip,
          onPressed: () => unawaited(_openPermissions()),
        ),
        FaHeaderAction(
          key: const ValueKey('appReload'),
          icon: Icons.refresh,
          label: context.l10n.appsReloadTooltip,
          onPressed: () {
            AppAnalytics.instance.jsAppReloaded();
            unawaited(_restart());
          },
        ),
      ],
      FaHeaderAction(
        key: const ValueKey('appClose'),
        icon: Icons.close,
        label: context.l10n.appsCloseTooltip,
        onPressed: chrome.onClose,
      ),
    ];
  }

  PreferredSizeWidget _panelAppBar(JsAppPanelChrome chrome) {
    final trafficLightLeading = _panelTrafficLightLeading();
    // The card floats 8pt below the window top, so only the remainder of
    // the platform safe area is needed above the toolbar. Compact macOS
    // window controls are cleared horizontally by [trafficLightLeading].
    final titlebarTop = math.max(0.0, MediaQuery.paddingOf(context).top - 8);
    final glass =
        FaDesignTokens.of(context).direction == FaVisualDirection.glass;
    final colors = FahColors.of(context);
    final onBack = chrome.onBack;
    final duoRailWidth = FaDuoControlRail.widthOf(context);
    final chromeActions = _panelChromeActions(chrome, duoRailWidth);
    final chromeMenuEntries = _chromeMenuEntries();
    final panelWidth = MediaQuery.sizeOf(context).width;
    final densePanel = duoRailWidth == 0 && panelWidth <= 360;
    final denseActionsInline = panelWidth >= 280;
    final denseChromeActions = _denseChromeActions(chromeActions);
    final denseChromeMenuEntries = _denseChromeMenuEntries(denseChromeActions);
    return PreferredSize(
      // The vertical rail is a body overlay, never an app-bar height input.
      // Only this ordinary horizontal title band offsets the JS canvas.
      preferredSize: Size.fromHeight(titlebarTop + kToolbarHeight),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (glass)
            const Positioned.fill(
              child: MessengerGlassUnderlay(
                underlayKey: ValueKey('appChromeGlassUnderlay'),
              ),
            ),
          Positioned(
            top: titlebarTop,
            left: 0,
            right: 0,
            height: kToolbarHeight,
            child: AppBar(
              // This toolbar is manually positioned below the platform inset
              // by titlebarTop. primary=true would SafeArea its 56pt child
              // again and clip the whole title to 56 - 59 = 0 on folded Duo.
              primary: false,
              backgroundColor: glass ? Colors.transparent : null,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              centerTitle: false,
              automaticallyImplyLeading: false,
              leadingWidth: _panelLeadingWidth(onBack, duoRailWidth, trafficLightLeading),
              leading: _panelLeading(onBack, duoRailWidth, trafficLightLeading),
              title: _panelAppBarTitle(colors, onBack, trafficLightLeading),
              actions: [
                // The vertical Duo rail overlays the canvas's right edge;
                // the title band keeps its actions clear of it.
                if (duoRailWidth > 0)
                  SizedBox(width: duoRailWidth)
                else if (densePanel)
                  _denseChromeActionBand(
                    inline: denseActionsInline,
                    actions: denseChromeActions,
                    menuEntries: denseChromeMenuEntries,
                  )
                else
                  _chromeActionBand(
                    actions: chromeActions,
                    menuEntries: chromeMenuEntries,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Only compact/full presented chrome owns the window's leading edge.
  double _panelTrafficLightLeading() {
    return FaWindowChrome.presentedAppClearance(
      context,
      embeddedInPanel: widget.embeddedInPanel,
    )
        ? FaWindowChrome.compactLeadingInset
        : 0.0;
  }

  /// The minimize control's clearance: no back action or a Duo rail lane
  /// leaves the leading edge empty.
  double? _panelLeadingWidth(
    VoidCallback? onBack,
    double duoRailWidth,
    double trafficLightLeading,
  ) {
    return onBack == null || duoRailWidth > 0
        ? null
        : kToolbarHeight + trafficLightLeading;
  }

  /// The presented app's minimize button, inset past the compact macOS
  /// window controls.
  Widget? _panelLeading(
    VoidCallback? onBack,
    double duoRailWidth,
    double trafficLightLeading,
  ) {
    return onBack == null || duoRailWidth > 0
        ? null
        : Padding(
            padding: EdgeInsets.only(left: trafficLightLeading),
            child: IconButton(
              key: const ValueKey('presentedAppMinimizeButton'),
              tooltip: context.l10n.chatCollapse,
              onPressed: onBack,
              icon: const Icon(Icons.remove_rounded, size: 20),
            ),
          );
  }

  /// The app-bar title: icon + name, inset past the compact macOS window
  /// controls only while no minimize button owns the leading edge.
  Widget _panelAppBarTitle(
    FahColors colors,
    VoidCallback? onBack,
    double trafficLightLeading,
  ) {
    return Padding(
      padding: EdgeInsets.only(left: onBack == null ? trafficLightLeading : 0),
      child: Row(
        children: [
          AppIcon(app: widget.app, env: widget.env, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              widget.app.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The dense panel's action set: every chrome action except the close
  /// affordance, plus the permissions and reload actions, closed by the
  /// original trailing action.
  List<FaHeaderAction> _denseChromeActions(List<FaHeaderAction> chromeActions) {
    return [
      ...chromeActions.take(chromeActions.length - 1),
      FaHeaderAction(
        key: const ValueKey('appPermissions'),
        icon: Icons.shield_outlined,
        label: context.l10n.appsPermissionsTooltip,
        onPressed: () => unawaited(_openPermissions()),
      ),
      FaHeaderAction(
        key: const ValueKey('appReload'),
        icon: Icons.refresh,
        label: context.l10n.appsReloadTooltip,
        onPressed: () {
          AppAnalytics.instance.jsAppReloaded();
          unawaited(_restart());
        },
      ),
      chromeActions.last,
    ];
  }

  /// The dense action set's overflow menu, keyed off each action's ValueKey.
  List<PopupMenuItem<String>> _denseChromeMenuEntries(
    List<FaHeaderAction> denseChromeActions,
  ) {
    return [
      for (final action in denseChromeActions)
        _chromeMenuEntry(
          value: _denseMenuValue((action.key as ValueKey<String>).value),
          icon: action.icon!,
          label: action.label,
        ),
    ];
  }

  /// The overflow-menu value for a dense chrome action key.
  String _denseMenuValue(String key) {
    return switch (key) {
      'appFull' => 'full',
      'appPin' => 'pin',
      'appMinimize' => 'minimize',
      'appPermissions' => 'permissions',
      'appReload' => 'reload',
      _ => 'close',
    };
  }

  /// The tight-window action band: inline actions while they fit, the
  /// overflow menu below the inline threshold.
  FaIconActionBand<String> _denseChromeActionBand({
    required bool inline,
    required List<FaHeaderAction> actions,
    required List<PopupMenuItem<String>> menuEntries,
  }) {
    return FaIconActionBand<String>(
      key: const ValueKey('appChromeActions'),
      glass: true,
      actionSize: 28,
      iconSize: 16,
      actions: inline ? actions : const [],
      overflowItems: inline ? const [] : menuEntries,
      onOverflowSelected: _onChromeMenuSelection,
      overflowMenuKey: const ValueKey('appOverflow'),
      overflowTooltip: FaChatStrings.of(context).chatMoreTooltip,
    );
  }

  /// The ordinary action band with the panel's full chrome action set.
  FaIconActionBand<String> _chromeActionBand({
    required List<FaHeaderAction> actions,
    required List<PopupMenuItem<String>> menuEntries,
  }) {
    return FaIconActionBand<String>(
      key: const ValueKey('appChromeActions'),
      glass: true,
      actions: actions,
      overflowItems: menuEntries,
      onOverflowSelected: _onChromeMenuSelection,
      overflowMenuKey: const ValueKey('appOverflow'),
      overflowTooltip: FaChatStrings.of(context).chatMoreTooltip,
    );
  }

  Widget _duoPanelRail(JsAppPanelChrome chrome, double width) {
    return Positioned(
      top: FaDuoControlRail.topOf(context),
      right: 0,
      bottom: 0,
      width: width,
      child: FaDuoControlRail(
        key: const ValueKey('appChromeActions'),
        actions: _panelChromeActions(chrome, width),
        menuColor: FahColors.of(context).panelAlt,
      ),
    );
  }

  void _onAppPopInvoked(bool didPop, bool backRegistered) {
    if (didPop) return;
    final chrome = widget.panelChrome;
    if (chrome != null && !backRegistered) {
      chrome.onClose();
    } else {
      _forwardBackToApp();
    }
  }

  Widget _appCanvas(ThemeData theme, bool fullChrome, double topInset) {
    return Padding(
      key: const ValueKey('appCanvasHeaderInset'),
      padding: EdgeInsets.only(top: topInset),
      child: RepaintBoundary(
        key: _boundaryKey,
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor,
          child: fullChrome && widget.panelChrome == null
              ? SafeArea(bottom: false, child: _keyboardWrappedBody(theme))
              : SafeArea(top: false, child: _keyboardWrappedBody(theme)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fullChrome = widget.app.isFullChrome;
    final duoRailWidth = FaDuoControlRail.widthOf(context);
    final titlebarTop = widget.panelChrome == null
        ? 0.0
        : math.max(0.0, MediaQuery.paddingOf(context).top - 8);
    // The panel chrome's PreferredSize ALREADY positions its title band
    // below the platform inset (titlebarTop above). The Scaffold must not
    // stretch that slot by the safe area a second time — primary Scaffold
    // layout adds MediaQuery.padding.top to the app-bar height, which on a
    // phone painted a ~59pt dead glass band under the toolbar and pushed
    // the canvas down with it. Desktop (padding.top = 0) is unchanged.
    final canvasTopInset = widget.panelChrome == null
        ? 0.0
        : titlebarTop + kToolbarHeight;
    // With a jsr.onBack handler registered the app owns back navigation:
    // the native pop (iOS edge swipe, system back) is vetoed and the
    // attempt forwards to JS instead. Without one the route pops natively.
    return ValueListenableBuilder<bool>(
      valueListenable: _engine?.backHandlerRegistered ?? _noBackHandler,
      builder: (context, backRegistered, _) {
        return PopScope(
          canPop: widget.panelChrome == null && !backRegistered,
          onPopInvokedWithResult: (didPop, _) =>
              _onAppPopInvoked(didPop, backRegistered),
          child: Scaffold(
            // The panel-chrome app bar is a manually positioned PreferredSize
            // that owns the platform inset itself (see canvasTopInset): the
            // Scaffold must treat it as non-primary so the safe area is not
            // added to the slot a second time.
            primary: widget.panelChrome == null,
            extendBodyBehindAppBar: widget.panelChrome != null,
            appBar: _buildAppBar(fullChrome),
            body: Stack(
              children: [
                Positioned.fill(
                  child: _appCanvas(theme, fullChrome, canvasTopInset),
                ),
                if (widget.panelChrome != null && duoRailWidth > 0)
                  _duoPanelRail(widget.panelChrome!, duoRailWidth),
                // Full chrome has no AppBar — permissions/reload live in a small
                // floating menu so immersive apps (maps) keep the whole canvas.
                if (fullChrome && widget.panelChrome == null)
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
                // The local Stack keeps every Fa affordance inside the
                // nested Apps panel; embedding must not remove app access
                // to the same session, work controls, and app context.
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
                          // The shell owns section + route changes so narrow
                          // Apps lands on ChatScreen, not back on the grid.
                          onOpenFullChat: () {
                            final reveal = FaChatHost.revealActiveChat;
                            if (reveal == null) {
                              Navigator.of(context).pop();
                            } else if (widget.embeddedInPanel) {
                              unawaited(reveal());
                            } else {
                              Navigator.of(context).pop();
                              unawaited(reveal());
                            }
                          },
                        ),
                      ),
                  ],
                ],
              ],
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
        onSelected: _onChromeMenuSelection,
        itemBuilder: (context) => _chromeMenuEntries(),
      ),
    );
  }

  PopupMenuItem<String> _chromeMenuEntry({
    required String value,
    required IconData icon,
    required String label,
  }) => PopupMenuItem(
    value: value,
    // Popup menus measure intrinsic rows. Flexible keeps a narrow Duo label
    // inside its bounds without LayoutBuilder, which intrinsics forbid.
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    ),
  );

  /// The ⋮ menu rows shared by the app-bar circle and the floating
  /// full-chrome menu.
  List<PopupMenuItem<String>> _chromeMenuEntries() => [
    _chromeMenuEntry(
      value: 'permissions',
      icon: Icons.shield_outlined,
      label: context.l10n.appsPermissionsTooltip,
    ),
    _chromeMenuEntry(
      value: 'reload',
      icon: Icons.refresh,
      label: context.l10n.appsReloadTooltip,
    ),
    _chromeMenuEntry(
      value: 'close',
      icon: Icons.close,
      label: context.l10n.appsCloseTooltip,
    ),
  ];

  /// Dispatches a full-chrome menu selection — the same actions the
  /// header AppBar offers.
  void _onChromeMenuSelection(String value) {
    switch (value) {
      case 'full':
        widget.panelChrome?.onFullScreen();
      case 'pin':
        widget.panelChrome?.onPin();
      case 'minimize':
        widget.panelChrome?.onMinimize?.call();
      case 'permissions':
        unawaited(_openPermissions());
      case 'reload':
        AppAnalytics.instance.jsAppReloaded();
        unawaited(_restart());
      case 'close':
        _closeFromMenu();
    }
  }

  /// Menu close mirrors the system-back contract: an app that registered
  /// `jsr.onBack` owns the close flow, otherwise pop directly. Full-chrome
  /// apps (maps) have no AppBar back arrow and the canvas swallows the iOS
  /// edge swipe, so this menu item is their only reliable exit.
  void _closeFromMenu() {
    if (_engine?.backHandlerRegistered.value ?? false) {
      _forwardBackToApp();
    } else {
      _closeFromJs();
    }
  }

  /// Wraps the app body in the runtime's [JsKeyboardCapture] when an engine
  /// is running: every hardware key becomes a `jsr.onKey` payload
  /// (`{key, code, down, repeat}`) delivered via
  /// `engine.dispatchHostEvent('key', ...)`. The capture yields to editable
  /// text fields automatically, and claims keyboard focus on first tap so
  /// embedded hosts (boards, panels) also receive keys.
  ///
  /// Falls back to the raw body before the engine starts or when the app
  /// errors out — no engine, no listener.
  Widget _keyboardWrappedBody(ThemeData theme) {
    final body = _buildBody(theme);
    final engine = _engine;
    if (engine == null) return body;
    return JsKeyboardCapture(
      onEvent: (payload) => engine.dispatchHostEvent('key', payload),
      child: body,
    );
  }

  /// The shared start/boot error card: one message style for a failed
  /// start and a never-rendered boot (gh-1336 review).
  Widget _errorCard(ThemeData theme, Object error) => Center(
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

  Widget _buildBody(ThemeData theme) {
    final error = _startError;
    if (error != null) {
      return _errorCard(theme, error);
    }
    final engine = _engine;
    if (engine == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // Issue #1336: an engine that booted but never rendered (eval failed
    // before the first render) must not spin forever — same error card
    // as a failed start.
    return ValueListenableBuilder<String?>(
      valueListenable: engine.bootError,
      builder: (context, bootError, _) {
        if (bootError != null) {
          return _errorCard(theme, bootError);
        }
        return _treeView(theme, engine);
      },
    );
  }

  /// The app tree once the boot is trusted (gh-1336): a spinner until the
  /// first render lands, then the JSON widget tree. Extracted from
  /// [_buildBody] to keep both halves under the CRAP ratchet — the lines
  /// here are covered by the native-bridge suites, which skip on hosted
  /// Linux, so the CI analyzer measures ~0% widget-test coverage.
  Widget _treeView(ThemeData theme, JsAppEngine engine) {
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
          mediaHost: widget.mediaHost ?? const FaMediaHost(),
          // Embedded web content: the SAME host the engine's JsRuntimeConfig
          // got (see JsAppEngine.start), so a `webView` node renders
          // identically wherever the tree is drawn.
          webViewHost: widget.webViewHost ?? createFaWebViewHost(),
          // 3D scenes: the dispatcher singleton shared with the engine's
          // JsRuntimeConfig (see JsAppEngine.start); taps raycast into
          // `jsr.scene3d.onTap` handlers in the app.
          js3dHost: createFaJs3dHost(widget.env),
          // Voxel worlds: the bridge-owned world the engine's backend
          // created at start — the SAME world every `voxel.*` hostCall
          // lands in (see JsAppEngine.voxelWorld). Without it the renderer
          // swaps every `voxel` node for the "Voxel world" placeholder
          // while the engine side reports success (gh-1441).
          voxelWorld: engine.voxelWorld,
          onScene3dTap: (sceneId, payload) =>
              engine.dispatchHostEvent('scene3d.tap:$sceneId', payload),
          // gh-1784: high-frequency gesture streams (onPanUpdate,
          // onLongPressMoveUpdate, onScroll) bypass the serialized callEvent
          // queue via the fire-and-forget host-event lane (`gesture:<id>`).
          onGestureEvent: (actionId, payload) =>
              engine.dispatchHostEvent('gesture:$actionId', payload),
          onEvent: (actionId, payload) {
            unawaited(engine.callEvent(actionId, payload));
          },
        );
        // gh-1441 AC3: a null world on a voxel tree must never be silent —
        // one line tells "host did not wire voxelWorld" from "broken
        // widget" (one-shot; never fires on shipped backends).
        engine.noteUnwiredVoxelWorld(tree);
        // gh-1164 Part B: a host-side render/build failure is reported to
        // the authoring agent through the same gate as JS-side errors —
        // the framework still renders its own error UI for the user.
        Widget rendered;
        try {
          rendered = renderer.build(tree, context);
        } on Object catch (error, stackTrace) {
          engine.reportHostError(
            'render: $error',
            kind: 'render',
            stack: '$stackTrace',
          );
          rethrow;
        }
        return ViewportReporter(
          onSize: (size) => engine.dispatchHostEvent('viewport', {
            'width': size.width,
            'height': size.height,
          }),
          child: ClipRect(child: rendered),
        );
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
          _toggle(
            context.l10n.appsPermissionTheme,
            context.l10n.appsPermissionThemeDesc,
            _current.theme,
            (v) => _set(_current.copyWith(theme: v)),
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
