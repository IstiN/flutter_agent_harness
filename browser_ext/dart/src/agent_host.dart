// The fa agent host inside the extension service worker (self-contained
// mode, issue #23 G4): core Agent + ToolRegistry (browser ops over the
// sw/ops.js dispatch table + core fs tools over the storage env) +
// ApprovalManager with a panel prompt surface + JSONL session persistence
// and auto-compaction on the storage env.
//
// Keys never leave the SW: provider config incl. apiKey is read from
// chrome.storage by agent_main.dart and passed in as [HostConfig]; nothing
// here is ever exposed to content scripts or pages (AC8).
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/config/config_service.dart';
import 'package:flutter_agent_harness/src/config/config_tool.dart';
import 'package:flutter_agent_harness/src/web_search/web_search.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/agent/agent.dart';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/agent/agent_tool.dart';
import 'package:flutter_agent_harness/src/agent/auto_compactor.dart';
import 'package:flutter_agent_harness/src/agent/tool_registry.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/approval/approval_hook.dart';
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/compaction/compaction.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/session/session_storage.dart';
import 'package:flutter_agent_harness/src/session/uuid.dart';
import 'package:flutter_agent_harness/src/session/session_tree.dart';
import 'package:flutter_agent_harness/src/tools/builtin_tools.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:http/http.dart' as http;

import 'active_tab_context.dart';
import 'approval_flow.dart';
import 'ext_ops.dart';
import 'host_event_map.dart'
    show hostEventOf, messageToJs, transcriptReplayOf, v1OpToolResult;
import 'browser_api_tools.dart';
import 'bridge_tools.dart';
import 'security/exfil_gate.dart' show OutboundKind, originOf;
import 'chrome_api.dart';
import 'run_script_tool.dart';
import 'chrome_storage_env.dart';
import 'fetch_client.dart';
import 'dap/dap_frames.dart';
import 'dap/dap_integration.dart';
import 'dap/bound_session_routing.dart';
import 'providers.dart';
import 'session_reset.dart';
import 'tool_gate.dart';
import 'ui_protocol.dart';
import 'ui_host_adapter.dart';

/// Calls the browser op table bound by sw/main.js (`globalThis.__faOps` →
/// ops.dispatch). Same op names as the wire protocol (`navigate`, `click`,
/// `read_dom`, …); returns the `{ok, result | error}` envelope.
typedef OpCaller =
    Future<Map<String, dynamic>> Function(String op, Map<String, dynamic> args);

/// Host event sink wired to the panel via agent_main (one JSON-able map per
/// event: delta, message_done, tool_result, approval_request, status, error).
typedef HostEventSink = void Function(Map<String, dynamic> event);

/// Boot/re-boot configuration resolved from chrome.storage by agent_main.
typedef HostConfig = ({
  ProviderConfig? provider,
  String approvalMode, // 'ask' | 'write' | 'yolo' | 'unattended'
  String mailbox,
  DapConfig? dap, // null = no hub presence
  /// Second-tier browser tools the user enabled in Settings (issue #34
  /// AC4d): tool name → enabled. Actual registration still requires the
  /// chrome permission to be granted (#19 capability floor).
  Map<String, bool> browserTools,
});

const _sessionPath = '/session.jsonl';

const _systemPrompt =
    'You are fa, an agent running inside a Chrome extension service worker. '
    'You can act on the web through two tool families: the browser_* page '
    'ops (navigate, read_dom, click, type, screenshot, …) and the v2 power '
    'surface (tabs_open/tabs_close, windows_*, groups_*, history_search, '
    'bookmarks_*, downloads_*, cookies_*, inject_js, cdp_eval, …). Scripting '
    'and debugging tools refuse restricted pages (chrome://, extension '
    'pages, the Web Store) — tab management still works there. Keep small '
    'notes under / through the read/write/edit/ls file tools. There is no '
    'shell. Be terse. '
    'Tool results are NOT shown to the user and must never be echoed back: '
    'answer in your own words, quoting only the fragments you actually '
    'need. '
    'A turn may open with a `[context] active tab:` line naming the page '
    'focused when the turn started (or `restricted page, tools '
    'unavailable`); it is environment context, not part of the request, '
    'and is only resent when that page changed.';

/// Owns the agent, its tools, approvals, session, and the event bridge.
final class AgentHost implements UiHostBackend {
  AgentHost._(this._env, this._ops, this._sink)
    : _flow = ApprovalFlow(sink: _sink) {
    // Provider diagnostics ride the relay into the panel console — the
    // SW's own console is a separate DevTools window nobody opens.
    hostEventSink = _sink;
  }

  final ChromeStorageEnv _env;
  final OpCaller _ops;
  final HostEventSink _sink;

  late ApprovalManager _approvals;
  late ToolRegistry _registry;

  /// Panel-driven per-tool enable/disable (issue #34 `tools_put`); owns
  /// the desired state, [_registry] mirrors it via [_gate].sync.
  late ToolGate _gate;
  late Agent _agent;
  Session? _session;
  ProviderConfig? _provider;
  String _mailbox = '';
  bool _running = false;
  bool _booted = false;

  /// Hub presence (null when no faDap config).
  DapIntegration? _dap;
  DapConfig? _dapConfig;

  /// The browser-API surface, when the host booted with a [ChromeApi]:
  /// the registered tools, the per-turn active-tab context injector, and
  /// the second-tier gate (issue #34 AC4d) all read it.
  BrowserApiToolSurface? _browserSurface;

  /// The chrome binding kept for the ext_request op surface (cookies /
  /// tabs); null on a v1-only boot.
  ChromeApi? _chromeApi;

  /// Second-tier gate state: the enabled-set it reflects and the
  /// serialized re-apply chain keeping overlapping settings and
  /// permission events ordered.
  Set<String> _enabledTools = {};
  Future<void> _gateSync = Future.value();

  /// Per-turn active-tab memory: the last (url, title) announced to the
  /// model, in-memory only — a SW restart re-announces once (safe
  /// direction), and each host instance owns its own session.
  final _tabContext = ActiveTabContext();

  /// AC18: one deduper across bridge + DAP mail, so a peer message that
  /// arrives on both links is delivered once (bridge copy wins — it lands
  /// first).
  final _mailDedupe = MailDeduper();

  /// Bridge mail waiting for the next turn boundary (drained as steering).
  final _mail = <({String from, String text})>[];

  /// Live visited-origin set shared with the browser tools' exfil gate
  /// (the same instance agent_main passes in); null = gate off.
  Set<String>? _visitedOrigins;

  /// Pending-approval flow (pure core: approval_flow.dart, VM-tested).
  /// Owns prompt ids (`ap-N`), the 120s deny backstop, and the mid-run
  /// rescue: a live approval-mode flip to yolo/unattended resolves every
  /// pending prompt as allowed instead of stalling the turn for the full
  /// timeout per gated tool call. A panel ALLOW surfaces the call's
  /// target origin here, which the host seeds into the exfil gate's
  /// visited set — the user explicitly approved a call targeting it,
  /// which is exactly what cross_origin asks for.
  late final ApprovalFlow _flow;

  /// Messages already persisted this SW lifetime (identity set — partial
  /// assistant snapshots share objects with the final message).
  final _persisted = <Message>{};

  /// Last [_refreshArchives] snapshot (sessionsList is sync, the fs is not).
  List<Map<String, dynamic>>? _archivesCache;

  /// Constructs the host: restores the storage env, opens (or creates) the
  /// JSONL session, and builds the agent over the restored transcript.
  /// [chrome] non-null joins the v2 browser-API family (34 core power
  /// tools plus the Settings-gated second tier, issue #34 AC4d)
  /// to the v1 browser_* ops — [visitedOrigins] wires their exfil gate to
  /// the caller's LIVE set (the SW wiring keeps updating it as the user
  /// navigates; the gate reads it at call time).
  static Future<AgentHost> boot({
    required HostEventSink sink,
    required OpCaller ops,
    required HostConfig config,
    ChromeApi? chrome,
    Set<String>? visitedOrigins,
    RunScriptExecutor? runScript,
    WebSearchConfig? webSearch,
  }) async {
    final env = await ChromeStorageEnv.restore();
    final host = AgentHost._(env, ops, sink);
    await host._init(
      config,
      chrome: chrome,
      visitedOrigins: visitedOrigins,
      runScript: runScript,
      webSearch: webSearch,
    );
    return host;
  }

  Future<void> _init(
    HostConfig config, {
    ChromeApi? chrome,
    Set<String>? visitedOrigins,
    RunScriptExecutor? runScript,
    WebSearchConfig? webSearch,
  }) async {
    _mailbox = config.mailbox;
    _registry = ToolRegistry([
      ...builtinTools(
        _env,
        webSearch: webSearch,
      ).where((tool) => tool.name != 'bash'),
      // AC11 (issue #29): the config tool on the browser-storage surface.
      // chrome.storage has no home dir and the SW cannot spawn host-side
      // processes — the service refuses stdio servers with the named
      // "not applicable on this host" answer instead of writing them.
      configTool(
        ConfigService(env: _env, homeDir: null, supportsProcesses: false),
      ),
      // Sandboxed script interpreters (python/javascript) in the offscreen
      // document — the web-app sandbox parity the SW otherwise lacks.
      if (runScript != null) runScriptTool(execute: runScript),
      for (final MapEntry(:key, :value) in _browserOps.entries)
        _browserTool(key, value),
    ]);
    if (chrome != null) {
      _chromeApi = chrome;
      _enabledTools = _enabledOf(config.browserTools);
      _browserSurface = await registerBrowserApiTools(
        _registry,
        chrome,
        visitedOrigins: visitedOrigins,
        enabledSecondTier: _enabledTools,
        exfilApproval: _askOutbound,
      );
      // Generic chrome.* bridge (issue #137): catalog + path calls over
      // every declared namespace, exec-tier gated by the dynamic ask.
      await registerBridgeTools(
        _registry,
        chrome,
        riskAsk: _askBridgeRisk,
        onFirstCall: _onFirstBridgeCall,
      );
    }
    _visitedOrigins = visitedOrigins;
    _gate = ToolGate({for (final t in _registry.agentTools) t.name: t});
    _approvals = ApprovalManager(
      mode:
          approvalModeFromLabel(config.approvalMode) ?? ApprovalMode.alwaysAsk,
      // alwaysPrompts (inject_js) rides the per-tool prompt override, which
      // outranks the session mode, turn grants and the always-allow set —
      // except in yolo, which means EVERYTHING (see applyModePromptOverrides).
      overrides: alwaysPromptOverrides(),
      prompt: _promptApproval,
    );
    applyModePromptOverrides(_approvals, _approvals.mode);

    final storage = await _openSession();
    _session = Session(storage);
    _provider = config.provider;
    _agent = Agent(
      model: _currentModel(),
      systemPrompt: _systemPrompt,
      messages: await _session!.buildContextMessages(),
      streamFunction: _streamFn(),
      toolRegistry: _registry,
      externalSteeringSource: _drainMail,
    );
    _agent.externalSteeringProbe = () async => _mail.isNotEmpty;
    attachApproval(_agent, _approvals);
    _agent.subscribe(_onAgentEvent);
    _booted = true;
    // DAP attach must happen on the boot path too, not only in
    // reconfigure: after an extension reload the auto-boot reads faDap
    // from storage, and without this call the hub presence silently never
    // starts (config parses, no socket, panel shows "Unreachable").
    _applyDapConfig(config.dap);
    unawaited(_refreshArchives());
    _emitStatus();
  }

  /// Re-reads provider/approval/tool config (panel "Save"): swaps the
  /// stream function, model, approval mode, and the second-tier tool gate
  /// in place. The approval mode applies LIVE — mid-run included — and a
  /// flip to yolo/unattended resolves pending prompts as allowed; every
  /// other field is ignored mid-run with the busy error (unsafe to swap
  /// under a running turn).
  void reconfigure(HostConfig config) {
    if (!_booted) return;
    final mode =
        approvalModeFromLabel(config.approvalMode) ?? ApprovalMode.alwaysAsk;
    final modeChanged = mode != _approvals.mode;
    _approvals.mode = mode;
    // yolo drops the inject_js always-prompt guard; other modes restore
    // it (a per-tool prompt override outranks the session mode).
    applyModePromptOverrides(_approvals, mode);
    if (modeChanged &&
        (mode == ApprovalMode.yolo || mode == ApprovalMode.unattended)) {
      final resolved = _flow.resolveAll(
        allow: true,
        note: 'approval mode → ${mode.label}: pending prompts allowed',
      );
      print('[fah][sw] reconfigure: mode=${mode.label} resolved=$resolved');
    }
    final needsIdle = reconfigureNeedsIdle(
      mailboxChanged: _mailbox != config.mailbox,
      providerChanged: _provider != config.provider,
      dapChanged: !_sameDapTarget(config.dap),
      toolsChanged: !_sameEnabledTools(config.browserTools),
    );
    if (_running) {
      if (needsIdle) {
        _sink({
          'type': 'error',
          'error': 'busy: finish the current turn first',
        });
      }
      return;
    }
    _mailbox = config.mailbox;
    _provider = config.provider;
    _applyDapConfig(config.dap);
    applyToolVisibility(config.browserTools);
    _agent.streamFunction = _streamFn();
    _agent.state.model = _currentModel();
    _emitStatus();
  }

  /// Whether [next] targets the same hub as the live DAP config (null ≡
  /// null; otherwise sameTargetAs — url + name).
  bool _sameDapTarget(DapConfig? next) {
    final current = _dapConfig;
    if (next == null && current == null) return true;
    if (next == null || current == null) return false;
    return next.sameTargetAs(current);
  }

  /// Whether [next] enables the same second-tier set the gate currently
  /// reflects (extra false entries are semantically absent).
  bool _sameEnabledTools(Map<String, bool> next) {
    final enabled = _enabledOf(next);
    return enabled.length == _enabledTools.length &&
        enabled.containsAll(_enabledTools);
  }

  /// Live second-tier re-surface (issue #19 semantics): the panel pushes
  /// the enabled-map on settings changes; a permission granted
  /// out-of-band surfaces its enabled tool immediately, a revocation
  /// hides it. The registry sync is chained through [_gateSync] so
  /// overlapping settings and permission events stay ordered.
  void applyToolVisibility(Map<String, bool> enabled) {
    _enabledTools = _enabledOf(enabled);
    reapplyToolGate();
  }

  /// Re-applies the gate with the CURRENT enabled-set — the permission-
  /// event path (chrome.permissions.onAdded/onRemoved): config unchanged,
  /// only the capability floor moved. No-op without a browser surface.
  void reapplyToolGate() {
    final surface = _browserSurface;
    if (surface == null) return; // v1-only boot: nothing gated exists
    _gateSync = _gateSync
        .then((_) => syncSecondTierTools(_registry, surface, _enabledTools))
        .then((_) => _syncAgentTools())
        .catchError((Object _) {
          // A failed re-apply must not poison the chain; the next event
          // retries the full idempotent sync.
        });
  }

  /// Enabled-tool keys with a true value (absent/false = hidden).
  Set<String> _enabledOf(Map<String, bool> browserTools) => {
    for (final MapEntry(:key, :value) in browserTools.entries)
      if (value) key,
  };

  /// Starts/stops/retargets the hub presence without touching the agent.
  void _applyDapConfig(DapConfig? dap) {
    final current = _dapConfig;
    if (current != null && dap != null && current.sameTargetAs(dap)) {
      // Same hub target — keep the live client (no reconnect), but take
      // the new config object: the session binding rides it and must
      // apply immediately (mail routing reads _dapConfig).
      _dapConfig = dap;
      return;
    }
    _detachDap();
    if (dap != null) _attachDap(dap);
  }

  void _attachDap(DapConfig config) {
    _dapConfig = config;
    final integration = DapIntegration(
      config: config,
      pushMail: pushMail,
      onStatusChanged: _emitStatus,
    );
    _dap = integration;
    _registry.registerAll(integration.tools);
    _syncAgentTools();
    unawaited(integration.start());
  }

  void _detachDap() {
    final integration = _dap;
    if (integration == null) return;
    _dap = null;
    _dapConfig = null;
    _registry.unregister('dap_dm');
    _registry.unregister('dap_peers');
    _syncAgentTools();
    unawaited(integration.stop());
  }

  /// `Agent(toolRegistry:)` SEEDS its tool list at construction — late
  /// registrations (DAP attach/detach after boot) must be pushed to the
  /// live agent or the model sees "tool not found".
  void _syncAgentTools() {
    if (!_booted) return; // _agent is late — nothing to sync pre-init
    _agent.state.tools = _registry.tools;
  }

  @override
  List<UiToolState> toolsList() => _gate.snapshot();

  @override
  void toolsPut(List<UiToolState> tools) {
    if (!_gate.apply(tools)) return;
    _gate.sync(_registry);
    _syncAgentTools();
  }

  Model _currentModel() {
    final provider = _provider;
    if (provider == null || provider.model.isEmpty) {
      // No provider configured yet: a fake model keeps the host inspectable;
      // sends run against the scripted provider and fail soft.
      return modelForConfig((
        baseUrl: '',
        apiKey: '',
        model: 'fake:not-configured',
      ));
    }
    return modelForConfig(provider);
  }

  StreamFunction _streamFn() {
    final provider = _provider;
    if (provider == null || provider.model.isEmpty) return fakeStream;
    return resolveStreamFn(provider);
  }

  Future<JsonlSessionStorage> _openSession({bool fresh = false}) async {
    if (!fresh && (await _env.exists(_sessionPath)).valueOrNull == true) {
      return JsonlSessionStorage.open(_env, _sessionPath);
    }
    return JsonlSessionStorage.create(
      _env,
      _sessionPath,
      cwd: _env.cwd,
      sessionId: _uuid(),
    );
  }

  // -- Public surface (mirrored on globalThis.faAgent by agent_main) ---------

  /// User turn from the panel composer (or CI). While a run is active the
  /// text is steered into the current run, sender-attributed.
  @override
  void sendUser(String text, {String from = 'user'}) {
    final attributed = from == 'user' ? text : '[from $from] $text';
    if (_running) {
      _agent.steer(UserMessage.text(attributed));
      return;
    }
    unawaited(_runTurn(attributed));
  }

  /// Panel/protocol cancel (v2): aborts the active run. `_runTurn`'s
  /// finally block resets `running` and emits the status event through
  /// the normal sink, so callers get the settled state for free.
  @override
  void cancelTurn() {
    if (_running) _agent.abort();
  }

  /// `session_new` (panel "New session"): archive the live JSONL via
  /// [archiveLiveSession] (failure aborts the reset — overwriting the
  /// live file after a failed archive would destroy the only copy), then
  /// start a fresh session IN PLACE — same registry, approvals, stream
  /// function and provider; only the transcript resets. Refused while a
  /// turn runs: killing a live run mid-flight is worse than a busy error.
  @override
  Future<void> newSession() async {
    if (!_booted) throw StateError('not booted');
    if (_running) throw StateError('busy: finish the current turn first');
    final oldId = sessionId;
    print('[dap-host] session_new: archiving $oldId');
    if (oldId.isNotEmpty) {
      await archiveLiveSession(
        fs: _env,
        sessionPath: _sessionPath,
        sessionId: oldId,
      );
    }
    _session = Session(await _openSession(fresh: true));
    _persisted.clear();
    _agent.state.messages = const [];
    unawaited(_refreshArchives());
    _emitStatus();
  }

  /// `session_open` (panel taps a past session): archive the current live
  /// session (same rules as [newSession]), restore the archive onto the
  /// live path and load its transcript into the agent. Refused while a
  /// turn runs, or when the archive does not exist.
  @override
  Future<void> openSession(String requestedId) async {
    if (!_booted) throw StateError('not booted');
    if (_running) {
      print(
        '[dap-host] session_open($requestedId) REFUSED: a turn is '
        'running — finish or cancel it first',
      );
      throw StateError('busy: finish the current turn first');
    }
    final archivePath = sessionArchivePath(requestedId);
    print('[dap-host] session_open($requestedId): switching from $sessionId');
    if ((await _env.exists(archivePath)).valueOrNull != true) {
      throw StateError('no such session: $requestedId');
    }
    final currentId = _session?.cachedId ?? '';
    if (currentId.isNotEmpty && currentId != requestedId) {
      await archiveLiveSession(
        fs: _env,
        sessionPath: _sessionPath,
        sessionId: currentId,
      );
    }
    await restoreArchivedSession(
      fs: _env,
      sessionPath: _sessionPath,
      archivePath: archivePath,
    );
    _session = Session(await JsonlSessionStorage.open(_env, _sessionPath));
    _persisted.clear();
    _agent.state.messages = await _session!.buildContextMessages();
    unawaited(_refreshArchives());
    _emitStatus();
  }

  /// Attach backlog for a first attach: the loaded transcript rendered as
  /// replay events (see [transcriptReplayOf]).
  @override
  List<Map<String, dynamic>> transcriptReplay() =>
      !_booted ? const [] : transcriptReplayOf(_agent.state.messages);

  /// The live JSONL session id from the header (parsed at open — no disk
  /// read), or '' before the session exists.
  @override
  String get sessionId => _session?.cachedId ?? '';

  /// Known sessions for the v2 UI: the live JSONL plus every archived one
  /// (`/session-<id>.jsonl`, written by session_new / session_open). The
  /// interface is sync but the fs listing is async — this reads the last
  /// [_refreshArchives] snapshot; the sheet polls every 3s and every
  /// mutation (new/open) refreshes, so the list converges within a poll.
  @override
  List<Map<String, dynamic>> sessionsList() {
    final live = sessionId;
    return [
      {
        'id': live,
        'messages': _booted ? _agent.state.messages.length : 0,
        'running': _running,
        if (_session?.cachedMetadata?.createdAt != null)
          'createdAt': _session!.cachedMetadata!.createdAt.toIso8601String(),
        'cwd': _env.cwd,
      },
      // A restored session keeps its archive copy on disk; the live row
      // already represents it — drop the twin or the drawer lists the
      // same session twice.
      ...?_archivesCache?.where((row) => row['id'] != live),
    ];
  }

  /// Rescans `/session-*.jsonl` (names + header line for id/timestamp).
  /// Never throws: a broken entry is skipped — the drawer listing must
  /// not break the host.
  Future<void> _refreshArchives() async {
    final listed = await _env.listDir('/');
    final entries = listed.valueOrNull ?? const <FileInfo>[];
    final rows = <Map<String, dynamic>>[];
    for (final entry in entries) {
      if (entry.kind != FileKind.file) continue;
      final name = entry.name;
      const prefix = 'session-';
      const suffix = '.jsonl';
      if (!name.startsWith(prefix) || !name.endsWith(suffix)) continue;
      final id = name.substring(prefix.length, name.length - suffix.length);
      if (id.isEmpty) continue;
      String? createdAt;
      final header = (await _env.readTextLines(
        '/$name',
        maxLines: 1,
      )).valueOrNull?.firstOrNull;
      if (header != null) {
        try {
          final decoded = jsonDecode(header);
          if (decoded is Map) {
            final ts = decoded['timestamp'];
            if (ts is String) createdAt = ts;
          }
        } on Object {
          // Header parse failure keeps the entry, just undated.
        }
      }
      rows.add({
        'id': id,
        'messages': 0,
        'running': false,
        if (createdAt != null) 'createdAt': createdAt,
        'cwd': _env.cwd,
        'archived': true,
      });
    }
    rows.sort((a, b) {
      final aT = a['createdAt'] as String? ?? '';
      final bT = b['createdAt'] as String? ?? '';
      return bT.compareTo(aT); // newest first
    });
    _archivesCache = rows;
  }

  /// Peer mail intake (bridge + DAP): deduped (AC18), queued for steering
  /// mid-run, starts a turn when idle.
  void pushMail(String from, String text) {
    if (!_mailDedupe.first(from, text)) return; // AC18: bridge/DAP duplicate
    unawaited(_routeMail(from, text));
  }

  /// Routes one inbound mail: the session binding (faDap.boundSession)
  /// pins hub mail to a dedicated or user-picked session — when idle, that
  /// session becomes live BEFORE the turn so the conversation lands where
  /// the user pointed it. A running turn keeps the classic behavior: the
  /// mail steers into the active session (switching mid-run is refused).
  Future<void> _routeMail(String from, String text) async {
    if (!_running) await _ensureBoundSession();
    if (_running) {
      _mail.add((from: from, text: text));
      return;
    }
    await _runTurn('[from $from] $text');
  }

  /// Switches to the bound session when the binding asks for it: the
  /// decision table is pure ([boundSessionAction]); failures degrade to
  /// the current session — mail must never be lost over routing.
  Future<void> _ensureBoundSession() async {
    final config = _dapConfig;
    if (config == null || !_booted) return;
    final action = boundSessionAction(
      mode: config.boundSessionMode,
      boundId: config.boundSessionId,
      currentId: sessionId,
      pristineLive: _agent.state.messages.isEmpty,
    );
    switch (action) {
      case BoundSessionAction.stay:
        return;
      case BoundSessionAction.openBound:
        print(
          '[dap-host] inbound mail: switching to the bound session '
          '${config.boundSessionId} (was $sessionId)',
        );
        try {
          await openSession(config.boundSessionId!);
        } on Object {
          // No such archive (cleared, never synced) — in dedicated mode
          // fall through to minting a fresh dedicated session; in named
          // mode stay on the current session rather than dropping mail.
          if (config.boundSessionMode != 'dedicated') return;
          await _createDedicatedSession(config);
        }
      case BoundSessionAction.createDedicated:
        await _createDedicatedSession(config);
    }
  }

  /// Mints (or adopts the pristine live session as) the dedicated agent
  /// session and persists its id back into faDap so the same session
  /// keeps receiving mail across SW restarts.
  Future<void> _createDedicatedSession(DapConfig config) async {
    try {
      if (_agent.state.messages.isNotEmpty) await newSession();
      await config.persistBoundSessionId?.call(sessionId);
    } on Object {
      // Busy/unbooted raced in — the current session takes the mail.
    }
  }

  Future<List<Message>> _drainMail() async {
    if (_mail.isEmpty) return const [];
    final drained = [
      for (final m in _mail) UserMessage.text('[from ${m.from}] ${m.text}'),
    ];
    _mail.clear();
    return drained;
  }

  /// Panel answered an approval banner.
  @override
  void decide(String id, bool allow) {
    final outcome = _flow.decide(id, allow);
    print('[fah][sw] decide id=$id allow=$allow found=${outcome.found}');
    // An ALLOW registers the target origin with the exfil gate's visited
    // set: the user just explicitly approved a call targeting it. A deny
    // (or a late double-answer, found=false) must never seed it.
    final origin = outcome.origin;
    if (allow && origin != null) _visitedOrigins?.add(origin);
  }

  /// The `ext_request` op surface (panel-only host capabilities): the
  /// user's live cookie jar (chrome.cookies), SW-relayed HTTP (MV3 +
  /// `<all_urls>` = no CORS for provider endpoints) and tab creation.
  /// Dispatch is pure (ext_ops.dart, VM-tested); this wires it to the
  /// chrome binding and the fetch client.
  @override
  Future<Map<String, dynamic>> extRequest(
    String op,
    Map<String, dynamic> params,
  ) => handleExtOp(_ExtOpsBackend(this), op, params);

  Future<ExtHttpResponse> _extFetch(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final client = FetchClient();
    final request = http.Request(method, Uri.parse(url))
      ..headers.addAll(headers);
    if (body != null) request.body = body;
    final response = await client.send(request).then(http.Response.fromStream);
    return ExtHttpResponse(status: response.statusCode, body: response.body);
  }

  @override
  Map<String, dynamic> getState() {
    final provider = _provider;
    return {
      'running': _running,
      'booted': _booted,
      'mailbox': _mailbox,
      'provider': {
        'configured': provider != null && provider.model.isNotEmpty,
        'model': provider?.model ?? '',
        'baseUrl': provider?.baseUrl ?? '',
        'fake': provider == null || isFakeModel(provider.model),
      },
      'approval': _approvals.mode.label,
      if (_dap case final dap?) 'hub': dap.snapshot(),
      'session': {
        'path': _sessionPath,
        'messages': _booted ? _agent.state.messages.length : 0,
      },
    };
  }

  /// CI hook (AC2): one scripted fake-provider turn on a throwaway agent
  /// with the SAME tool registry — echoes text, executes browser_navigate,
  /// and verifies the tool result lands in the transcript. Never touches
  /// the real session.
  Future<Map<String, dynamic>> selfTest() async {
    final testAgent = Agent(
      model: modelForConfig((baseUrl: '', apiKey: '', model: 'fake:selftest')),
      systemPrompt: _systemPrompt,
      streamFunction: fakeStream,
      toolRegistry: _registry,
    );
    attachApproval(testAgent, ApprovalManager(mode: ApprovalMode.unattended));
    final transcript = <Map<String, dynamic>>[];
    testAgent.subscribe((event, token) async {
      if (event is MessageEndEvent) transcript.add(messageToJs(event.message));
    });
    try {
      await testAgent.prompt(
        'selftest: navigate data:text/html,<h1>fa-selftest</h1>',
      );
    } on Object catch (error) {
      return {'ok': false, 'error': '$error', 'transcript': transcript};
    }
    final toolOk = transcript.any(
      (m) =>
          m['role'] == 'toolResult' &&
          m['toolName'] == 'browser_navigate' &&
          m['isError'] != true,
    );
    return {
      'ok': toolOk,
      'transcript': transcript,
      if (!toolOk) 'error': 'no successful browser_navigate tool result',
    };
  }

  // -- Run flow ---------------------------------------------------------------

  Future<void> _runTurn(String text) async {
    if (_running || !_booted) return;
    _running = true;
    _emitStatus();
    try {
      await _agent.prompt(await _turnTextWithTabContext(text));
    } on Object catch (error) {
      _sink({'type': 'error', 'error': '$error'});
    } finally {
      _running = false;
      _emitStatus();
    }
  }

  /// Per-turn active-tab context (issue #34): prepends the
  /// `[context] active tab:` line when the focused page changed since the
  /// last injected turn. Best-effort on both ends — hosts booted without
  /// the v2 browser surface have no accessor (no line), and a failed
  /// probe never blocks the turn.
  Future<String> _turnTextWithTabContext(String text) async {
    final surface = _browserSurface;
    if (surface == null) return text;
    final Tab? tab;
    try {
      tab = await surface.activeTab();
    } on Object {
      return text; // probe failed: run the turn bare instead
    }
    final line = _tabContext.lineFor(tab);
    return line == null ? text : '$line\n$text';
  }

  Future<void> _onAgentEvent(AgentEvent event, CancelToken token) async {
    // Persist before announcing: a panel that reacts to message_done by
    // reloading sees the persisted transcript, not a stale one.
    if (event is MessageEndEvent) await _persistMessage(event.message);
    if (event case AgentSettledEvent()) {
      await _env.flush();
      await _compactIfDue();
      return;
    }
    final uiEvent = hostEventOf(event);
    if (uiEvent != null) _sink(uiEvent);
  }

  Future<void> _persistMessage(Message message) async {
    final session = _session;
    if (session == null) return;
    if (!_persisted.add(message)) return;
    try {
      await session.appendMessage(message);
    } on Object {
      // Persistence must never break a live turn; the next flush retries.
      _persisted.remove(message);
    }
  }

  /// AC10: compaction stays functional — the shared AutoCompactor runs
  /// against the session tree after every settled run.
  Future<void> _compactIfDue() async {
    final session = _session;
    if (session == null) return;
    final window = _agent.state.model.contextWindow;
    await AutoCompactorFactory(
      session: session,
      state: _agent.state,
      window: window,
      settings: CompactionSettings.forWindow(window),
      sources: AutoCompactorSources(
        smolStream: _agent.streamFunction,
        smolModel: _agent.state.model,
        mainStream: _agent.streamFunction,
        mainModel: _agent.state.model,
      ),
      hooks: _SilentHooks(),
    ).run();
    await _env.flush();
  }

  // -- Approvals ---------------------------------------------------------------

  Future<ApprovalDecision> _promptApproval(ApprovalRequest request) async {
    final allow = await _flow.request(
      toolName: request.toolName,
      arguments: request.arguments,
      reason: request.reason,
    );
    return allow ? ApprovalDecision.approveOnce : ApprovalDecision.deny;
  }

  /// The exfil gate's ask (cross_origin / data_exit outbound actions),
  /// routed through the SAME prompt surface as ordinary approvals — the
  /// gate used to hard-error without asking anybody, so even the
  /// interactive modes could not open a never-visited origin and the
  /// model looped on the tool error. The user's contract for the
  /// extension: yolo = ZERO prompts (there is no bash there to carry
  /// critical patterns) — yolo and unattended answer the ask silently;
  /// only ask/write show the dialog. An allow seeds the visited set, so
  /// the ask is once per ORIGIN.
  Future<bool> _askOutbound(
    OutboundKind kind,
    String url,
    String explanation,
  ) async {
    if (!exfilGateShouldAsk(_approvals.mode)) return true;
    final allow = await _promptApproval(
      ApprovalRequest(
        toolName: kind.name,
        tier: ApprovalTier.exec,
        arguments: {'url': url},
        reason: explanation,
      ),
    ).then((d) => d != ApprovalDecision.deny);
    if (allow) {
      final origin = originOf(url);
      if (origin != null) _visitedOrigins?.add(origin);
    }
    return allow;
  }

  /// The bridge's exec-tier ask (issue #137): same prompt surface as
  /// ordinary approvals, same mode contract as the exfil gate —
  /// yolo/unattended answer silently (zero prompts is yolo's contract),
  /// ask/write prompt. The static tier of browser_api is read, so the
  /// approval matrix never double-prompts; this ask carries the
  /// exec-tier namespaces only.
  Future<bool> _askBridgeRisk(String path, ApprovalTier tier) async {
    if (!exfilGateShouldAsk(_approvals.mode)) return true;
    final allow = await _promptApproval(
      ApprovalRequest(
        toolName: 'browser_api',
        tier: tier,
        arguments: {'path': path},
        reason: 'chrome.$path is an exec-tier namespace '
            '(code execution or user-facing surface)',
      ),
    );
    return allow != ApprovalDecision.deny;
  }

  /// One-time yolo notice: the first bridge call in yolo mode drops a
  /// status line so the transcript shows the agent reaching chrome.*
  /// ungated (the panel also carries the persistent indicator).
  void _onFirstBridgeCall(String path) {
    if (_approvals.mode != ApprovalMode.yolo) return;
    _sink({
      'type': 'status',
      'note': 'bridge: first chrome.* call "$path" — yolo mode, no prompt',
    });
  }

  // -- Browser tools (over __faOps) ---------------------------------------------

  /// browser op name → JSON-schema for its args (mirrors sw/ops.js).
  static const _browserOps = <String, Map<String, dynamic>>{
    'navigate': {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
        'tabId': {'type': 'number'},
      },
      'required': ['url'],
    },
    'tabs': {'type': 'object', 'properties': {}},
    'switch_tab': {
      'type': 'object',
      'properties': {
        'tabId': {'type': 'number'},
      },
      'required': ['tabId'],
    },
    'click': _selectorSchema,
    'type': {
      'type': 'object',
      'properties': {
        'selector': {'type': 'string'},
        'text': {'type': 'string'},
        'submit': {'type': 'boolean'},
      },
      'required': ['selector', 'text'],
    },
    'press_key': {
      'type': 'object',
      'properties': {
        'key': {'type': 'string'},
        'selector': {'type': 'string'},
      },
      'required': ['key'],
    },
    'select': {
      'type': 'object',
      'properties': {
        'selector': {'type': 'string'},
        'value': {'type': 'string'},
      },
      'required': ['selector', 'value'],
    },
    'read_dom': {
      'type': 'object',
      'properties': {
        'selector': {'type': 'string'},
        'maxNodes': {'type': 'number'},
      },
    },
    'wait_for': {
      'type': 'object',
      'properties': {
        'selector': {'type': 'string'},
        'text': {'type': 'string'},
        'timeoutMs': {'type': 'number'},
      },
    },
    'eval': {
      'type': 'object',
      'properties': {
        'code': {'type': 'string'},
      },
      'required': ['code'],
    },
    'screenshot': {
      'type': 'object',
      'properties': {
        'tabId': {'type': 'number'},
      },
    },
    'task_end': {'type': 'object', 'properties': {}},
  };

  static const _selectorSchema = {
    'type': 'object',
    'properties': {
      'selector': {'type': 'string'},
    },
    'required': ['selector'],
  };

  AgentTool _browserTool(String op, Map<String, dynamic> schema) {
    return AgentTool(
      name: 'browser_$op',
      description:
          'Browser op "$op" (Chrome extension). Runs against the active tab '
          'unless a tabId is given.',
      parameters: schema,
      tier: ApprovalTier.exec,
      execute: (arguments, cancelToken, onUpdate) async {
        final res = await _ops(op, arguments);
        if (res['ok'] != true) {
          throw Exception(res['error'] ?? 'op "$op" failed');
        }
        // Screenshots arrive as vision image blocks; everything else as
        // compact text (see host_event_map.dart).
        return v1OpToolResult(op, res);
      },
    );
  }

  // -- Helpers -------------------------------------------------------------------

  void _emitStatus() {
    _sink({'type': 'status', ...getState()});
  }
}

/// Session ids come from the harness's UUIDv7: the old local LCG here
/// collapsed under dart2js (int is a double; the multiply overflowed 2^53
/// and zeroed the low bits), so two sessions minted close together could
/// share an id and one's archive file overwrote the other — sessions
/// "disappeared" from the picker. uuidv7 is time-ordered and secure-random.
String _uuid() => uuidv7();

/// Compaction progress sink that reports nothing (headless SW).
final class _SilentHooks implements AutoCompactorHooks {
  @override
  void onPass(AutoCompactorPass pass) {}
  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}
  @override
  void onDone(int passes, int tokens) {}
  @override
  void onBothRolesFailed(Object lastError) {}
  @override
  void onDelta(String delta) {}
  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}
}

/// The ext_request backend over the SW's chrome binding + fetch client.
final class _ExtOpsBackend implements ExtOpsBackend {
  _ExtOpsBackend(this._host);

  final AgentHost _host;

  @override
  Future<List<ExtCookie>> cookiesGetAll({String? url, String? domain}) async {
    final chrome = _host._chromeApi;
    if (chrome == null) throw 'no chrome binding (v1-only build)';
    final cookies = await chrome.cookies.getAll(url: url, domain: domain);
    return [
      for (final c in cookies)
        ExtCookie(name: c.name, value: c.value, domain: c.domain),
    ];
  }

  @override
  Future<ExtHttpResponse> fetchString(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) => _host._extFetch(url, method: method, headers: headers, body: body);

  @override
  Future<void> tabsCreate(String url) async {
    final chrome = _host._chromeApi;
    if (chrome == null) throw 'no chrome binding (v1-only build)';
    await chrome.tabs.create(url: url);
  }
}
