// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'device_display.dart';
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
    required this.session,
    required this.channelId,
    this.dmSessionId,
    this.dmUndecryptablePlaceholder,
    this.dmEncryptedHistoryDivider,
  }) {
    session.addListener(_onSessionChanged);
  }

  /// The session this service renders; exposed for the page's listeners.
  final NetworkSession session;

  /// The channel inside [session].
  final String channelId;

  /// Selected DM session thread. Null is the device-general bucket; ignored
  /// for ordinary channels. Filtering is synchronous over the shared store,
  /// so switching sessions never shows the previous thread while history
  /// for the same transport channel is already loaded.
  final String? dmSessionId;

  /// Localized, non-technical DM fallback. Read lazily because the service
  /// is created in initState, before inherited localizations are available.
  final String Function()? dmUndecryptablePlaceholder;

  /// Localized divider label for a run of foreign-encrypted DM history.
  /// Null preserves the legacy per-row placeholders for embedders/tests.
  final String Function()? dmEncryptedHistoryDivider;

  /// Host payload identifying the DM history divider's custom tile.
  static const encryptedHistoryDividerData = 'dmEncryptedHistoryDivider';

  String get _undecryptablePlaceholder => isDmChannel(channelId)
      ? (dmUndecryptablePlaceholder?.call() ??
            'Encrypted on another device') // l10n:ignore
      : '(unable to decrypt this message)'; // l10n:ignore

  final ApprovalManager _approval = ApprovalManager();

  final _listeners = <void Function()>[];

  ChannelState get _state =>
      session.channelStates.putIfAbsent(channelId, ChannelState.new);

  void _onSessionChanged() => _notify();

  void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Releases the session subscription (the chat screen disposes us).
  void dispose() => session.removeListener(_onSessionChanged);

  // ------------------------------------------------------------ Listenable

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  // ------------------------------------------------------------- transcript

  List<ChannelMessage> get _visibleMessages {
    final stored = _state.messages;
    if (!isDmChannel(channelId)) return stored;
    return [
      for (final message in stored)
        if (message.sessionId == dmSessionId && !_isDeliveryReceipt(message))
          message,
    ];
  }

  bool _isDeliveryReceipt(ChannelMessage message) =>
      !message.isOwn &&
      (message.text == deviceDmQueuedReceipt ||
          message.text == deviceDmAcceptedReceipt);

  /// Receipts stay in the transport store for history/live dedup, but only
  /// project onto their original outbound bubble. Acceptance is monotonic:
  /// a delayed queued retry cannot regress an already accepted message.
  FaChatDeliveryStatus? _deliveryFor(ChannelMessage message) {
    if (!message.isOwn || !isDmChannel(channelId)) return null;
    FaChatDeliveryStatus? status;
    for (final candidate in _state.messages) {
      if (!_isDeliveryReceipt(candidate) ||
          candidate.sessionId != message.sessionId ||
          candidate.replyTo != message.envelopeId) {
        continue;
      }
      if (candidate.text == deviceDmAcceptedReceipt) {
        status = FaChatDeliveryStatus.accepted;
      } else if (status != FaChatDeliveryStatus.accepted) {
        status = FaChatDeliveryStatus.queued;
      }
    }
    return status;
  }

  @override
  List<FaChatMessage> get messages {
    final stored = _visibleMessages;
    final projected = <FaChatMessage>[];
    var index = 0;
    while (index < stored.length) {
      final message = stored[index];
      final divider = dmEncryptedHistoryDivider;
      if (message.text == null && divider != null && isDmChannel(channelId)) {
        var end = index + 1;
        while (end < stored.length && stored[end].text == null) {
          end++;
        }
        if (end - index > 1) {
          projected.add(
            FaChatMessage(
              role: 'widget',
              content: divider(),
              data: encryptedHistoryDividerData,
            ),
          );
          index = end;
          continue;
        }
      }
      projected.add(_chatMessage(message));
      index++;
    }
    return projected;
  }

  FaChatMessage _chatMessage(ChannelMessage message) {
    if (message.isOwn) {
      return FaChatMessage(
        role: 'user',
        content: message.text ?? '_($_undecryptablePlaceholder)_',
        deliveryStatus: _deliveryFor(message),
      );
    }
    return FaChatMessage(
      role: 'assistant',
      content: message.text == null
          ? '_($_undecryptablePlaceholder)_'
          : '**${_senderName(message)}**\n\n${message.text}',
    );
  }

  String _senderName(ChannelMessage message) {
    // The envelope-carried name wins (hub-originated DAP agents are not in
    // the fa_network roster — fa_network#2); members resolve via roster.
    // Raw session UUIDs are routing ids, not human sender names. Reuse the
    // Devices display chain so restored replies and receipt/system rows get
    // exactly the same friendly CLI · first8…last4 fallback.
    String friendly(String value) {
      final sessionId = message.sessionId;
      if (deviceSessionIdIsUuid(value)) {
        return deviceSessionDisplayTitle(
          id: value,
          title: value,
          cliFallback: true,
        );
      }
      if (sessionId != null && value.contains(sessionId)) {
        return deviceSessionDisplayTitle(
          id: sessionId,
          title: value,
          cliFallback: true,
        );
      }
      return value;
    }

    final claimed = message.senderName;
    if (claimed != null && claimed.isNotEmpty) return friendly(claimed);
    final member = session.roster[message.senderId];
    final name = member?.displayName;
    return friendly((name == null || name.isEmpty) ? message.senderId : name);
  }

  String _transcriptPlaceholder(bool isOwn) => !isDmChannel(channelId) && !isOwn
      ? '(undecryptable)' // l10n:ignore — legacy non-DM export
      : _undecryptablePlaceholder;

  @override
  String transcriptMarkdown() => _visibleMessages
      .map(
        (m) => m.isOwn
            ? '**You**: ${m.text ?? _transcriptPlaceholder(m.isOwn)}'
            : '**${_senderName(m)}**: ${m.text ?? _transcriptPlaceholder(m.isOwn)}',
      )
      .join('\n\n');

  // ---------------------------------------------------------------- sending

  @override
  Future<void> sendText(String text) {
    final mentions = _mentionIds(text);
    return session.sendText(
      channelId,
      text,
      mentions: mentions.isEmpty ? null : mentions,
    );
  }

  /// Resolves only complete, literal `@displayName` tokens against the
  /// current roster. Unknown names stay ordinary text; an email-like
  /// `user@example` is not a mention. The envelope carries ids, while [text]
  /// itself is never rewritten (the DAP channel contract).
  List<String> _mentionIds(String text) {
    final ids = <String>{};
    for (final member in session.roster.values) {
      if (member.id.isEmpty || member.displayName.isEmpty) continue;
      final needle = '@${member.displayName}';
      var searchFrom = 0;
      while (searchFrom < text.length) {
        final index = text.indexOf(needle, searchFrom);
        if (index < 0) break;
        final end = index + needle.length;
        if (_mentionStart(text, index) && _mentionEnd(text, end)) {
          ids.add(member.id);
          break;
        }
        searchFrom = index + 1;
      }
    }
    return ids.toList();
  }

  static bool _mentionStart(String text, int index) {
    if (index == 0) return true;
    final previous = text.substring(index - 1, index);
    return previous.trim().isEmpty ||
        '([{<'.contains(previous) ||
        previous == '"' ||
        previous == "'";
  }

  static bool _mentionEnd(String text, int end) {
    if (end == text.length) return true;
    final next = text.substring(end, end + 1);
    return next.trim().isEmpty || '.,!?;:)]}>/\\'.contains(next) || next == '"';
  }

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
  String? get error => session.error;

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
  Future<void> loadOlderHistory() => session.loadOlder(channelId);

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
