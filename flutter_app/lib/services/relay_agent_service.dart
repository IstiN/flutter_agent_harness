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
    return RelayAgentService._(
      detectTransport(portFactory: () => channel, forceOverride: true),
    );
  }

  /// Test seam: drive the relay over a fake channel-backed transport.
  @visibleForTesting
  RelayAgentService.forTest(FaTransport transport) : this._(transport);

  final FaTransport _transport;

  final _messages = <fa_ui.FaChatMessage>[];
  fa_ui.FaChatMessage? _currentAssistant;
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
    // Local preference; the SW gate keeps its own mode until the protocol
    // carries settings_put for approvals (issue #34 phase 2).
    approval.mode = mode;
  }

  @override
  Stream<TrajectorySnapshot> get trajectory => const Stream.empty();

  // -- FaChatConnection ------------------------------------------------------

  @override
  String get providerKind => 'relay';

  @override
  String get activeBaseUrl => _baseUrl;

  @override
  String? get activeProviderId => null;

  @override
  String get modelId => _modelId;

  /// The SW-side session id (from hello_ack/attached); '' before attached.
  String get relaySessionId => _sessionId;

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
      case MessageDoneMsg(:final message):
        _finishAssistant(message);
      case ApprovalRequestMsg(:final id, :final call, :final reason):
        unawaited(_decideApproval(id, call, reason));
      case StreamMsg(:final event):
        _onHostEvent(event);
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
      case 'message_done':
        _finishAssistant(event);
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
  void _finishAssistant(Map<String, dynamic> message) {
    final role = message['role'] as String? ?? 'assistant';
    final text = message['text'] as String? ?? '';
    // The streaming partial is replaced by the finalized message.
    final partial = _currentAssistant;
    if (partial != null) _messages.remove(partial);
    _currentAssistant = null;
    if (role == 'assistant' && text.isEmpty) {
      _append(
        fa_ui.FaChatMessage(
          content: fa_ui.emptyResponsePlaceholder,
          role: 'assistant',
        ),
      );
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
      // No UI mounted: deny conservatively — same default as the CLI's
      // null-prompt policy (never silently execute).
      _transport.dispatch(ApprovalResponseMsg(id: id, decision: 'deny'));
      return;
    }
    final summary = call['toolName'] as String? ?? 'tool';
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
    } on Object {
      _transport.dispatch(ApprovalResponseMsg(id: id, decision: 'deny'));
      rethrow;
    }
    _transport.dispatch(
      ApprovalResponseMsg(
        id: id,
        decision: decision == ApprovalDecision.deny ? 'deny' : 'allow',
      ),
    );
  }
}
