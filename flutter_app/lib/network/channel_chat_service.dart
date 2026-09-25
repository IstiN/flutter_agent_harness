// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'network_session.dart';

/// Adapts a fa_network channel to the shared Grok-style chat UI
/// (issue #955): own messages become right-aligned `user` bubbles, other
/// members become left `assistant` bubbles headed by their display name,
/// undecryptable envelopes render a placeholder (never a crash).
///
/// Pair it with `FaChatFeatures.minimal()`: no sandbox, no attachments,
/// no approvals — a channel is plain text-in/text-out.
final class ChannelChatService implements FaChatService {
  ChannelChatService({
    required NetworkSession session,
    required String channelId,
  }) : _session = session,
       _channelId = channelId {
    _session.addListener(_onSessionChanged);
  }

  final NetworkSession _session;
  final String _channelId;
  final ApprovalManager _approval = ApprovalManager();

  final _listeners = <void Function()>[];

  ChannelState get _state =>
      _session.channelStates.putIfAbsent(_channelId, ChannelState.new);

  void _onSessionChanged() => _notify();

  void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Releases the session subscription (the chat screen disposes us).
  void dispose() => _session.removeListener(_onSessionChanged);

  // ------------------------------------------------------------ Listenable

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  // ------------------------------------------------------------- transcript

  @override
  List<FaChatMessage> get messages => [
    for (final message in _state.messages)
      if (message.isOwn)
        FaChatMessage(role: 'user', content: message.text ?? '')
      else
        FaChatMessage(
          role: 'assistant',
          content: message.text == null
              ? '_(unable to decrypt this message)_'
              : '**${_senderName(message.senderId)}**\n\n${message.text}',
        ),
  ];

  String _senderName(String senderId) {
    final member = _session.roster[senderId];
    final name = member?.displayName;
    return (name == null || name.isEmpty) ? senderId : name;
  }

  @override
  String transcriptMarkdown() => _state.messages
      .map(
        (m) => m.isOwn
            ? '**You**: ${m.text ?? ''}'
            : '**${_senderName(m.senderId)}**: ${m.text ?? '(undecryptable)'}',
      )
      .join('\n\n');

  // ---------------------------------------------------------------- sending

  @override
  Future<void> sendText(String text) => _session.sendText(_channelId, text);

  @override
  Future<void> sendAttachments({
    required List<FaStagedAttachment> attachments,
    String text = '',
  }) => throw UnsupportedError('channels have no attachments (issue #955)');

  @override
  Future<String> stageAttachment({
    required String name,
    required Uint8List bytes,
  }) => throw UnsupportedError('channels have no attachments (issue #955)');

  @override
  Future<void> discardStagedAttachment(String path) async {}

  // ------------------------------------------------------------- agent-y no-ops

  @override
  ExecutionEnv? get sandboxEnv => null;

  @override
  bool get isStreaming => false;

  @override
  String? get error => _session.error;

  @override
  List<String> get pendingSteerTexts => const [];

  @override
  void abort() {}

  @override
  Stream<TrajectorySnapshot> get trajectory => const Stream.empty();

  @override
  Future<List<TrajectoryHiddenRecordPreview>> Function(
    TrajectoryCompactedRecord record,
  )?
  get resolveHiddenRecords => null;

  @override
  ApprovalManager get approval => _approval;

  @override
  void setApprovalMode(ApprovalMode mode) => _approval.mode = mode;

  // ------------------------------------------------------------- UI hooks (unused)

  @override
  ApprovalPrompt? approvalPromptHandler;

  @override
  AskCallback? askHandler;

  @override
  RequestSecretCallback? secretRequestHandler;

  @override
  PasswordPromptCallback? passwordPromptHandler;

  @override
  void Function(String messageId)? scrollToMessageHandler;

  // ----------------------------------------------------------------- history

  @override
  int? get historyAboveCount => _state.historyAboveCount;

  @override
  Future<void> loadOlderHistory() => _session.loadOlder(_channelId);

  @override
  String? get historyLoadError => _state.loadError;

  @override
  bool get historyLoading => _state.loading;

  @override
  int? get historyTotalCount => null;

  @override
  bool get historyHasNewer => false;

  @override
  int? get historyBelowCount => 0;

  @override
  Future<void> loadNewerHistory() async {}

  @override
  Future<bool> jumpToMessage(String messageId) async => false;
}
