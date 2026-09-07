// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_browser_agent/fa_browser_agent.dart';
import 'package:fa_ui/fa_ui.dart' as fa_ui;
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'agent_service.dart';
import 'relay/ext_runtime.dart';

/// The [AgentService] chat surface served by the extension's service-worker
/// agent over a [WorkerRelayTransport] (issue #34 item 1).
///
/// The panel UI keeps its `AgentService` type — everything below the
/// interface seam is relayed instead of local: `sendText` becomes a
/// protocol `prompt` (a `steer` mid-run), the SW's host events
/// (`delta`/`message_done`/`tool_result`/`status`/`error`) rebuild the
/// transcript, and `approval_request` renders through the same approval
/// sheet the local path uses. The UI holds no keys and makes zero provider
/// fetches — the SW owns providers, tools (browser + fs), and the session.
///
/// The local agent loop under the hood is an idle shell: it never runs
/// (see [AgentService.relayBase]); every chat surface member is overridden.
///
/// v1 limits (issue #34): attachments are not staged over the relay, the
/// trajectory ledger stays empty (the panel should hide the tab via
/// `FaChatFeatures`), and approval *mode* is a local preference — the SW
/// gate keeps its own mode until `settings_put` carries it.
final class RelayAgentService extends AgentService {
  RelayAgentService._(this._transport) : super.relayBase() {
    _transport.events.listen(_onTransportEvent);
    unawaited(_transport.connect());
  }

  /// Creates the relay for an extension-hosted panel, or null when this
  /// is not an extension page (plain web — the caller falls back to
  /// [AgentService.create]).
  static Future<RelayAgentService?> create() async {
    final channel = createPortChannel();
    if (channel == null) return null;
    final service = RelayAgentService._(
      detectTransport(portFactory: () => channel, forceOverride: true),
    );
    // Wait (bounded) for the attach + settings snapshot: boot code seeds
    // the provider registry from [swProvider] right after this returns.
    await service.ready;
    return service;
  }

  /// Test seam: drive the relay over a fake channel-backed transport.
  @visibleForTesting
  RelayAgentService.forTest(FaTransport transport) : this._(transport);

  final FaTransport _transport;

  final _messages = <fa_ui.FaChatMessage>[];
  fa_ui.FaChatMessage? _currentAssistant;
  fa_ui.FaChatMessage? _currentThinking;
  bool _running = false;
  String? _error;
  String _modelId = '';
  String _baseUrl = '';
  String _sessionId = '';
  final int _promptSeq = 0;

  ApprovalPrompt? _approvalHandler;
  AskCallback? _askHandler;
  RequestSecretCallback? _secretRequestHandler;

  // -- FaChatService ---------------------------------------------------------

  @override
  List<fa_ui.FaChatMessage> get messages => List.unmodifiable(_messages);

  @override
  bool get isStreaming => _running;

  @override
  String? get error => _error;

  @override
  List<String> get pendingSteerTexts => const [];

  @override
  Future<void> sendText(String text) async {
    _error = null;
    // The SW host events carry only the assistant side of the turn, so the
    // user bubble is drawn locally at send time (attach replay does not
    // include it — a known v1 gap after a page reload).
    _append(fa_ui.FaChatMessage(role: 'user', content: text));
    if (_running) {
      _transport.steer(text);
    } else {
      _transport.sendPrompt(
        'p-${DateTime.now().microsecondsSinceEpoch}-$_promptSeq',
        text,
      );
    }
  }

  @override
  Future<void> sendAttachments({
    required List<fa_ui.FaStagedAttachment> attachments,
    String text = '',
  }) async {
    throw UnsupportedError(
      'attachment staging over the extension relay lands with the #34 '
      'phase 2 (SW-side uploads surface)',
    );
  }

  @override
  Future<String> stageAttachment({
    required String name,
    required Uint8List bytes,
  }) {
    throw UnsupportedError(
      'attachment staging over the extension relay lands with the #34 '
      'phase 2 (SW-side uploads surface)',
    );
  }

  @override
  Future<void> discardStagedAttachment(String path) async {}

  @override
  void abort() => _transport.cancel();

  @override
  String transcriptMarkdown() {
    final buffer = StringBuffer();
    for (final message in _messages) {
      switch (message.role) {
        case 'user':
          buffer
            ..writeln('## User')
            ..writeln(message.content);
        case 'tool':
          buffer.writeln(
            '- **${message.toolName ?? 'tool'}**: ${message.content}',
          );
        default:
          buffer
            ..writeln('## Assistant')
            ..writeln(message.content);
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  @override
  ApprovalPrompt? get approvalPromptHandler => _approvalHandler;
  @override
  set approvalPromptHandler(ApprovalPrompt? handler) =>
      _approvalHandler = handler;

  @override
  AskCallback? get askHandler => _askHandler;
  @override
  set askHandler(AskCallback? handler) => _askHandler = handler;

  @override
  RequestSecretCallback? get secretRequestHandler => _secretRequestHandler;
  @override
  set secretRequestHandler(RequestSecretCallback? handler) =>
      _secretRequestHandler = handler;

  @override
  void setApprovalMode(ApprovalMode mode) {
    // The selector's segments rebuild off this notifier — without it the
    // button reads as dead (the tap "does nothing"). The SW gate learns
    // the mode through settings_put (faApproval → reconfigure).
    approval.mode = mode;
    notifyListeners();
    _transport.dispatch(SettingsPutMsg(settings: {'faApproval': mode.label}));
  }

  @override
  Stream<TrajectorySnapshot> get trajectory => const Stream.empty();

  // -- FaChatConnection ------------------------------------------------------
  // Reflects the SW connection once its snapshot landed; falls back to the
  // idle local defaults before that (the boot screens render early).

  @override
  String get providerKind =>
      _baseUrl.isNotEmpty ? 'openai-completions' : super.providerKind;

  @override
  String get activeBaseUrl =>
      _baseUrl.isNotEmpty ? _baseUrl : super.activeBaseUrl;

  @override
  String? get activeProviderId => null;

  @override
  String get modelId => _modelId.isNotEmpty ? _modelId : super.modelId;

  /// The SW-side session id (from hello_ack/attached); '' before attached.
  String get relaySessionId => _sessionId;

  Completer<void>? _readyCompleter = Completer<void>();

  /// Completes once the SW handshake landed (attached + first settings
  /// snapshot) so callers seeding UI state read real values. Bounded by
  /// [readyTimeout]; never throws.
  Future<void> get ready {
    final c = _readyCompleter;
    if (c == null) return Future.value();
    return c.future.timeout(
      readyTimeout,
      onTimeout: () {
        debugPrint('[fah][relay] ready TIMEOUT after $readyTimeout');
      },
    );
  }

  static const readyTimeout = Duration(seconds: 5);

  /// The SW's stored provider snapshot (settings_result `faProvider`), or
  /// null before the first snapshot arrives. Seeds the panel's provider
  /// registry so the models screens reflect the SW configuration.
  Map<String, String>? get swProvider =>
      _swProvider == null ? null : Map<String, String>.of(_swProvider!);
  Map<String, String>? _swProvider;

  /// The SW agent's tool state (tools_state), keyed by tool name.
  final _swTools = <String, bool>{};

  // -- transport plumbing ----------------------------------------------------

  void _onTransportEvent(UiTransportEvent event) {
    switch (event) {
      case ProtocolMessageReceived(:final message):
        _onProtocolMessage(message);
      case StateChanged(:final state):
        if (state is TransportReconnecting) {
          _error = 'reconnecting…';
          notifyListeners();
        } else {
          final streaming = state is TransportStreaming;
          if (streaming != _running) {
            _running = streaming;
            notifyListeners();
          }
        }
      case Dropped():
        _running = false;
        _error = 'extension service worker disconnected';
        notifyListeners();
      case Reconnected():
        _error = null;
        notifyListeners();
    }
  }

  void _onProtocolMessage(UiProtocolMessage message) {
    switch (message) {
      case HelloAckMsg(:final sessionId):
        _sessionId = sessionId ?? _sessionId;
      case AttachedMsg(:final sessionId, :final replay):
        _sessionId = sessionId;
        _rebuild(replay);
        debugPrint(
          '[fah][relay] attached: session=$sessionId replay=${replay.length}',
        );
        // Pick up the SW's persisted provider/model (chrome.storage) so the
        // composer reflects reality; reconfigure() writes back the same way.
        _transport.dispatch(const SettingsQueryMsg());
        debugPrint('[fah][relay] settings_query sent');
      case MessageDoneMsg(:final message):
        if ((message['role'] as String? ?? 'assistant') == 'user') {
          // Live user copy: the composer already echoed the raw text
          // (the SW's version carries the per-turn [context] prefix —
          // rendering both reads as a duplicated bubble). Replay covers
          // history via _onHostEvent's silent branch instead.
          break;
        }
        _finishAssistant(message);
      case ApprovalRequestMsg(:final id, :final call, :final reason):
        unawaited(_decideApproval(id, call, reason));
      case StreamMsg(:final event):
        _onHostEvent(event);
      case SettingsResultMsg(:final settings):
        _applySwSettings(settings);
        final c = _readyCompleter;
        if (c != null && !_sessionId.isEmpty) {
          _readyCompleter = null;
          c.complete();
        }
      case ToolsStateMsg(:final tools):
        _swTools
          ..clear()
          ..addEntries([for (final t in tools) MapEntry(t.name, t.enabled)]);
        notifyListeners();
      case ToolsPutMsg():
        break; // UI -> SW only
      case ErrorMsg(:final message):
        _error = message;
        notifyListeners();
      default:
        break; // hello_ack/attach are the transport's business
    }
  }

  /// Replays the SW ring after (re)attach: full rebuild, oldest first.
  void _rebuild(List<Map<String, dynamic>> replay) {
    _messages.clear();
    _currentAssistant = null;
    _currentThinking = null;
    for (final entry in replay) {
      final event = entry['event'];
      if (event is Map<String, dynamic>) _onHostEvent(event, silent: true);
    }
    notifyListeners();
  }

  void _onHostEvent(Map<String, dynamic> event, {bool silent = false}) {
    switch (event['type']) {
      case 'delta':
        _currentAssistant ??= _append(
          fa_ui.FaChatMessage(role: 'assistant', content: ''),
        );
        _currentAssistant!.content += event['text'] as String? ?? '';
      case 'thinking_delta':
        // Reasoning stream from the model: its own collapsible bubble
        // (same shape the local AgentService renders), never merged into
        // the assistant text. A new turn starts a fresh bubble —
        // _finishAssistant clears the current one.
        _currentThinking ??= _append(
          fa_ui.FaChatMessage(role: 'thinking', content: ''),
        );
        _currentThinking!.content += event['text'] as String? ?? '';
      case 'message_done':
        if ((event['role'] as String? ?? 'assistant') == 'user') {
          // The composer echoes the raw text locally, so the live user
          // message_done is redundant (and carries the per-turn [context]
          // prefix — rendering it reads as a duplicated bubble). On
          // replay there is no local echo, so the copy is needed there.
          if (silent) {
            _append(
              fa_ui.FaChatMessage(
                role: 'user',
                content: event['text'] as String? ?? '',
              ),
            );
          }
        } else {
          _finishAssistant(event);
        }
      case 'tool_result':
        _append(
          fa_ui.FaChatMessage(
            role: 'tool',
            content: event['text'] as String? ?? '',
            toolName: event['toolName'] as String?,
            isError: event['isError'] as bool? ?? false,
          ),
        );
      case 'status':
        _running = event['running'] as bool? ?? _running;
        final provider = event['provider'];
        if (provider is Map) {
          _modelId = provider['model'] as String? ?? _modelId;
          _baseUrl = provider['baseUrl'] as String? ?? _baseUrl;
        }
      case 'error':
        _error = event['error'] as String? ?? 'unknown relay error';
    }
    if (!silent) notifyListeners();
  }

  /// Replaces the streaming partial (if any) with the finalized message.
  /// The SW's merged settings snapshot (settings_result): the provider
  /// trio feeds the models screens and the composer.
  void _applySwSettings(Map<String, dynamic> settings) {
    final provider = settings['faProvider'];
    debugPrint(
      '[fah][relay] settings snapshot: hasProvider=${provider != null} '
      'keys=${settings.keys.toList()}',
    );
    if (provider is Map) {
      _modelId = '${provider['model'] ?? ''}'.trim();
      _baseUrl = '${provider['baseUrl'] ?? ''}'.trim();
      debugPrint(
        '[fah][relay] snapshot applied: model=$_modelId baseUrl=$_baseUrl',
      );
      _swProvider = {
        'baseUrl': _baseUrl,
        'model': _modelId,
        'apiKey': '${provider['apiKey'] ?? ''}',
      };
      notifyListeners();
    }
  }

  /// The Tools section renders the SW agent's registry, not a local one:
  /// every SW tool is capability-present; the enabled flag is the SW's.
  @override
  Map<String, ResolvedToolAvailability> get toolAvailability => {
    for (final entry in _swTools.entries)
      entry.key: ResolvedToolAvailability(
        enabled: entry.value,
        scope: ToolScope.builtin,
        capabilityPresent: true,
      ),
  };

  /// Tool toggles travel as `tools_put`; the local map updates
  /// optimistically and the SW's tools_state confirms (or corrects).
  @override
  Future<void> setToolEnabled(String id, bool enabled) async {
    if (!_swTools.containsKey(id) || _swTools[id] == enabled) return;
    _swTools[id] = enabled;
    notifyListeners();
    _transport.dispatch(
      ToolsPutMsg(
        tools: [UiToolState(name: id, enabled: enabled)],
      ),
    );
  }

  /// Settings save from the panel UI goes over the wire as `settings_put`:
  /// the SW persists it to chrome.storage and reconfigures its agent. The
  /// local (idle) agent is deliberately never touched — the panel holds no
  /// provider state of its own in extension mode.
  @override
  Future<void> reconfigure(AgentConfig config) async {
    debugPrint(
      '[fah][relay] reconfigure -> settings_put: '
      'baseUrl=${config.baseUrl} model=${config.modelId} '
      'key.len=${config.apiKey.length}',
    );
    _modelId = config.modelId;
    _baseUrl = config.baseUrl;
    final k = config.apiKey;
    _transport.dispatch(
      SettingsPutMsg(
        settings: {
          'faProvider': {
            'baseUrl': config.baseUrl,
            'apiKey': k,
            'model': config.modelId,
          },
        },
      ),
    );
    notifyListeners();
  }

  void _finishAssistant(Map<String, dynamic> message) {
    final role = message['role'] as String? ?? 'assistant';
    final text = message['text'] as String? ?? '';
    debugPrint('[fah][relay] message_done role=$role len=${text.length}');
    // The streaming partial is replaced by the finalized message.
    final partial = _currentAssistant;
    if (partial != null) _messages.remove(partial);
    _currentAssistant = null;
    // The finished thinking bubble stays on screen; the next turn's
    // reasoning opens a fresh one.
    _currentThinking = null;
    if (role == 'assistant' && text.isEmpty) {
      // A tool-call-only assistant turn legitimately has no text — the
      // tool_result rows that follow tell the story; a placeholder here
      // reads like a failure mid-flow (the approval dialog opens while
      // the empty bubble is already on screen).
      final toolCalls = message['toolCalls'];
      final hasToolCalls = toolCalls is List && toolCalls.isNotEmpty;
      if (!hasToolCalls) {
        _append(
          fa_ui.FaChatMessage(
            content: fa_ui.emptyResponsePlaceholder,
            role: 'assistant',
          ),
        );
      }
    } else if (role == 'tool') {
      _append(
        fa_ui.FaChatMessage(
          role: 'tool',
          content: text,
          toolName: message['toolName'] as String?,
        ),
      );
    } else {
      _append(fa_ui.FaChatMessage(role: role, content: text));
    }
    notifyListeners();
  }

  fa_ui.FaChatMessage _append(fa_ui.FaChatMessage message) {
    _messages.add(message);
    return message;
  }

  Future<void> _decideApproval(
    String id,
    Map<String, dynamic> call,
    String reason,
  ) async {
    final handler = _approvalHandler;
    if (handler == null) {
      // No UI mounted: stay silent. The decision belongs to a surface that
      // can actually ask the human — another panel client (or the e2e
      // driver) may answer; the SW's 120s timeout is the conservative
      // backstop and denies with a note if nobody does. An instant deny
      // here once raced ahead of the real UI and recorded a denial the
      // user never chose.
      debugPrint(
        '[fah][relay] approval id=$id has no handler — leaving it unanswered',
      );
      return;
    }
    final summary = call['toolName'] as String? ?? 'tool';
    debugPrint('[fah][relay] approval dialog open id=$id tool=$summary');
    late final ApprovalDecision decision;
    try {
      decision = await handler(
        ApprovalRequest(
          toolName: summary,
          tier: ApprovalTier.exec,
          arguments: call,
          reason: reason,
        ),
      );
    } on Object catch (error) {
      // The surface owes an answer, but the caller is unawaited — a
      // rethrow would vanish into an unhandled async error. Log and deny.
      debugPrint(
        '[fah][relay] approval handler threw: $error — denying id=$id',
      );
      _transport.dispatch(ApprovalResponseMsg(id: id, decision: 'deny'));
      return;
    }
    debugPrint('[fah][relay] approval answered id=$id decision=$decision');
    _transport.dispatch(
      ApprovalResponseMsg(
        id: id,
        decision: decision == ApprovalDecision.deny ? 'deny' : 'allow',
      ),
    );
  }
}
