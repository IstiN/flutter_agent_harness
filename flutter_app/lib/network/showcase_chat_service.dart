// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'showcase_viewer.dart';

/// Read-only `FaChatService` over a [ShowcaseViewer] channel (issue #955):
/// anonymous visitors read a public network's public channels without a
/// join. Sending is impossible by construction (the composer is hidden by
/// the page; [sendText] throws as a tripwire).
final class ShowcaseChatService implements FaChatService {
  ShowcaseChatService({required this.viewer, required this.channelId}) {
    viewer.addListener(_onChanged);
  }

  final ShowcaseViewer viewer;
  final String channelId;

  final ApprovalManager _approval = ApprovalManager();
  final _listeners = <void Function()>[];

  void _onChanged() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void dispose() => viewer.removeListener(_onChanged);

  List<ShowcaseMessage> get _messages => viewer.messages[channelId] ?? const [];

  // ------------------------------------------------------------ Listenable

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  // ------------------------------------------------------------- transcript

  @override
  List<FaChatMessage> get messages => [
    for (final message in _messages)
      FaChatMessage(
        role: 'assistant',
        content: message.text == null
            ? '_(unreadable message)_'
            : '**${message.senderId}**\n\n${message.text}',
      ),
  ];

  @override
  String transcriptMarkdown() => _messages
      .map((m) => '**${m.senderId}**: ${m.text ?? '(unreadable)'}')
      .join('\n\n');

  // ------------------------------------------------------------- read-only

  @override
  Future<void> sendText(String text) =>
      throw UnsupportedError('showcase browsing is read-only (issue #955)');

  @override
  Future<void> sendAttachments({
    required List<FaStagedAttachment> attachments,
    String text = '',
  }) => throw UnsupportedError('showcase browsing is read-only (issue #955)');

  @override
  Future<String> stageAttachment({
    required String name,
    required Uint8List bytes,
  }) => throw UnsupportedError('showcase browsing is read-only (issue #955)');

  @override
  Future<void> discardStagedAttachment(String path) async {}

  // ------------------------------------------------------------- agent-y no-ops

  @override
  ExecutionEnv? get sandboxEnv => null;

  @override
  bool get isStreaming => false;

  @override
  String? get error => viewer.error;

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
  int? get historyAboveCount => viewer.hasMore(channelId) ? 1 : 0;

  @override
  Future<void> loadOlderHistory() => viewer.loadMessages(channelId);

  @override
  String? get historyLoadError => null;

  @override
  bool get historyLoading => viewer.loading;

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
