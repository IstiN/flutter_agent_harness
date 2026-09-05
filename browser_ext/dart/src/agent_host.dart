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
import 'package:flutter_agent_harness/src/session/session_tree.dart';
import 'package:flutter_agent_harness/src/tools/builtin_tools.dart';
import 'package:flutter_agent_harness/src/types.dart';

import 'chrome_storage_env.dart';
import 'dap/dap_frames.dart';
import 'dap/dap_integration.dart';
import 'providers.dart';

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
});

const _sessionPath = '/session.jsonl';
const _approvalTimeout = Duration(seconds: 30);

const _systemPrompt =
    'You are fa, an agent running inside a Chrome extension service worker. '
    'You can act on the web through the browser_* tools (navigate, read_dom, '
    'click, type, screenshot, …) and keep small notes under / through the '
    'read/write/edit/ls file tools. There is no shell. Be terse.';

/// Owns the agent, its tools, approvals, session, and the event bridge.
final class AgentHost {
  AgentHost._(this._env, this._ops, this._sink);

  final ChromeStorageEnv _env;
  final OpCaller _ops;
  final HostEventSink _sink;

  late ApprovalManager _approvals;
  late ToolRegistry _registry;
  late Agent _agent;
  Session? _session;
  ProviderConfig? _provider;
  String _mailbox = '';
  bool _running = false;
  bool _booted = false;

  /// Hub presence (null when no faDap config).
  DapIntegration? _dap;
  DapConfig? _dapConfig;

  /// AC18: one deduper across bridge + DAP mail, so a peer message that
  /// arrives on both links is delivered once (bridge copy wins — it lands
  /// first).
  final _mailDedupe = MailDeduper();

  /// Bridge mail waiting for the next turn boundary (drained as steering).
  final _mail = <({String from, String text})>[];

  /// Pending approval prompts: id → decision completer.
  final _pendingApprovals = <String, Completer<bool>>{};
  var _approvalSeq = 0;

  /// Messages already persisted this SW lifetime (identity set — partial
  /// assistant snapshots share objects with the final message).
  final _persisted = <Message>{};

  /// Constructs the host: restores the storage env, opens (or creates) the
  /// JSONL session, and builds the agent over the restored transcript.
  static Future<AgentHost> boot({
    required HostEventSink sink,
    required OpCaller ops,
    required HostConfig config,
  }) async {
    final env = await ChromeStorageEnv.restore();
    final host = AgentHost._(env, ops, sink);
    await host._init(config);
    return host;
  }

  Future<void> _init(HostConfig config) async {
    _mailbox = config.mailbox;
    _registry = ToolRegistry([
      ...builtinTools(_env).where((tool) => tool.name != 'bash'),
      for (final MapEntry(:key, :value) in _browserOps.entries)
        _browserTool(key, value),
    ]);
    _approvals = ApprovalManager(
      mode:
          approvalModeFromLabel(config.approvalMode) ?? ApprovalMode.alwaysAsk,
      prompt: _promptApproval,
    );
    if (config.dap != null) _attachDap(config.dap!);

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
    _emitStatus();
  }

  /// Re-reads provider/approval config (panel "Save"): swaps the stream
  /// function, model, and approval mode in place. Ignored mid-run.
  void reconfigure(HostConfig config) {
    if (!_booted) return;
    if (_running) {
      _sink({'type': 'error', 'error': 'busy: finish the current turn first'});
      return;
    }
    _mailbox = config.mailbox;
    _approvals.mode =
        approvalModeFromLabel(config.approvalMode) ?? ApprovalMode.alwaysAsk;
    _provider = config.provider;
    _applyDapConfig(config.dap);
    _agent.streamFunction = _streamFn();
    _agent.state.model = _currentModel();
    _emitStatus();
  }

  /// Starts/stops/retargets the hub presence without touching the agent.
  void _applyDapConfig(DapConfig? dap) {
    final current = _dapConfig;
    if (current != null && dap != null && current.sameTargetAs(dap)) return;
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
    unawaited(integration.start());
  }

  void _detachDap() {
    final integration = _dap;
    if (integration == null) return;
    _dap = null;
    _dapConfig = null;
    _registry.unregister('dap_dm');
    _registry.unregister('dap_peers');
    unawaited(integration.stop());
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

  Future<JsonlSessionStorage> _openSession() async {
    if ((await _env.exists(_sessionPath)).valueOrNull == true) {
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
  void sendUser(String text, {String from = 'user'}) {
    final attributed = from == 'user' ? text : '[from $from] $text';
    if (_running) {
      _agent.steer(UserMessage.text(attributed));
      return;
    }
    unawaited(_runTurn(attributed));
  }

  /// Peer mail intake (bridge + DAP): deduped (AC18), queued for steering
  /// mid-run, starts a turn when idle.
  void pushMail(String from, String text) {
    if (!_mailDedupe.first(from, text)) return; // AC18: bridge/DAP duplicate
    if (_running) {
      _mail.add((from: from, text: text));
      return;
    }
    unawaited(_runTurn('[from $from] $text'));
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
  void decide(String id, bool allow) {
    _pendingApprovals.remove(id)?.complete(allow);
  }

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
      if (event is MessageEndEvent) transcript.add(_messageToJs(event.message));
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
      await _agent.prompt(text);
    } on Object catch (error) {
      _sink({'type': 'error', 'error': '$error'});
    } finally {
      _running = false;
      _emitStatus();
    }
  }

  Future<void> _onAgentEvent(AgentEvent event, CancelToken token) async {
    switch (event) {
      case MessageUpdateEvent(:final assistantMessageEvent):
        if (assistantMessageEvent is TextDeltaEvent) {
          _sink({'type': 'delta', 'text': assistantMessageEvent.delta});
        }
      case MessageEndEvent(:final message):
        await _persistMessage(message);
        _sink({'type': 'message_done', ..._messageToJs(message)});
      case ToolExecutionEndEvent(
        toolName: final toolName,
        result: final result,
        isError: final isError,
      ):
        _sink({
          'type': 'tool_result',
          'toolName': toolName,
          'isError': isError,
          'text': result.content
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n'),
        });
      case AgentSettledEvent():
        await _env.flush();
        await _compactIfDue();
      default:
        break;
    }
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
    final id = 'ap-${++_approvalSeq}';
    final completer = Completer<bool>();
    _pendingApprovals[id] = completer;
    final summary = '${request.toolName} ${jsonEncode(request.arguments)}';
    _sink({
      'type': 'approval_request',
      'id': id,
      'summary': summary.length > 300
          ? '${summary.substring(0, 300)}…'
          : summary,
      'reason': request.reason,
    });
    final timer = Timer(_approvalTimeout, () {
      if (!completer.isCompleted) {
        completer.complete(false); // timeout → deny, noted
        _sink({
          'type': 'approval_resolved',
          'id': id,
          'allow': false,
          'note': 'timed out after 30s — denied',
        });
      }
    });
    final allow = await completer.future;
    timer.cancel();
    _pendingApprovals.remove(id);
    return allow ? ApprovalDecision.approveOnce : ApprovalDecision.deny;
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
        return ToolExecutionResult.text(
          res['result'] == null ? 'ok' : jsonEncode(res['result']),
        );
      },
    );
  }

  // -- Helpers -------------------------------------------------------------------

  void _emitStatus() {
    _sink({'type': 'status', ...getState()});
  }

  Map<String, dynamic> _messageToJs(Message message) {
    final text = switch (message) {
      AssistantMessage(:final content) => [
        for (final block in content)
          if (block is TextContent) block.text,
      ].join('\n'),
      UserMessage(:final content) when content is String => content,
      ToolResultMessage(:final content) => [
        for (final block in content)
          if (block is TextContent) block.text,
      ].join('\n'),
      _ => '',
    };
    return {
      'role': message.role,
      'text': text,
      if (message is ToolResultMessage) 'toolName': message.toolName,
      if (message is ToolResultMessage) 'isError': message.isError,
      if (message is AssistantMessage && message.errorMessage != null)
        'error': message.errorMessage,
    };
  }
}

String _uuid() {
  var seed = DateTime.now().microsecondsSinceEpoch;
  var seq = 0;
  // ponytail: UUID-shaped id; uniqueness only needs to hold within one SW life.
  String next() => ((seed = seed * 1103515245 + 12345 + ++seq) & 0x7fffffff)
      .toRadixString(16)
      .padLeft(8, '0');
  final a = next(), b = next(), c = next(), d = next(), e = next(), f = next();
  return '$a-$b-4${c.substring(0, 3)}-a${d.substring(0, 3)}-$e${f.substring(0, 4)}';
}

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
