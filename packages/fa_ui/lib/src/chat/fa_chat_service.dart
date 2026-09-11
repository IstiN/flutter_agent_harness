// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'approval_ui.dart';

/// One message in the chat transcript the [FaChatScreen] renders.
///
/// Moved out of the app's agent service so hosts can adapt any backend
/// (the Fa AgentService, the YoClip studio backend, tests) to the shared
/// chat UI.
final class FaChatMessage {
  /// Creates a chat message.
  FaChatMessage({
    required this.role,
    required this.content,
    this.imageBytes,
    this.toolName,
    this.isError = false,
    this.data,
  });

  /// `user` | `assistant` | `tool` | `system` | `widget`.
  final String role;

  /// Plain-text (markdown for assistant messages) content. Mutable so
  /// streaming backends can append deltas to the message already in the
  /// transcript (see `_currentAssistantMessage` in Fa's AgentService).
  String content;

  /// Optional inline image (user attachments).
  final Uint8List? imageBytes;

  /// Tool name for `tool` messages (rendered collapsed by default).
  final String? toolName;

  /// Whether this message reports a failure (tool result or provider error).
  final bool isError;

  /// Opaque host payload (dynamic-message widget id); fa_ui never
  /// interprets it.
  final Object? data;
}

/// A file staged in the composer before sending: written into the agent
/// sandbox and referenced by path.
typedef FaStagedAttachment = ({String path, Uint8List bytes, String mimeType});

/// The stand-in text for an assistant message the model left empty (no text
/// blocks at all) — shown instead of a blank bubble.
const emptyResponsePlaceholder = '(empty response — try again)';

/// The backend surface the shared chat UI needs.
///
/// Implement it over your agent backend (Fa's `AgentService` already
/// satisfies every member; other hosts write a thin adapter). The chat
/// listens via [Listenable] and re-reads [messages] on every notify.
abstract interface class FaChatService implements FaApprovalModeController {
  /// The transcript, oldest first; re-read on every change notification.
  List<FaChatMessage> get messages;

  /// The sandbox filesystem markdown images / media in the transcript
  /// resolve against (see `SandboxImageResolver`). Null for hosts without a
  /// sandbox — the chat then renders image/media placeholders.
  ExecutionEnv? get sandboxEnv;

  /// Whether the agent is mid-run (drives the stop button / typing state).
  bool get isStreaming;

  /// The last provider/runtime error, surfaced as a system line; null when
  /// the last run succeeded.
  String? get error;

  /// Steer-queue previews shown above the composer while streaming.
  List<String> get pendingSteerTexts;

  /// Sends a plain user message.
  Future<void> sendText(String text);

  /// Sends staged attachments with an optional caption.
  Future<void> sendAttachments({
    required List<FaStagedAttachment> attachments,
    String text,
  });

  /// Stages raw bytes under [name] in the agent sandbox; returns the path.
  Future<String> stageAttachment({
    required String name,
    required Uint8List bytes,
  });

  /// Removes a staged attachment the user discarded before sending.
  Future<void> discardStagedAttachment(String path);

  /// Aborts the active run (drives the stop button).
  void abort();

  /// Full transcript as markdown (the copy-session toolbar action).
  String transcriptMarkdown();

  /// UI hooks the host wires to the sheets in this package. All harness
  /// types — see `approval_ui.dart`, `ask_ui.dart`,
  /// `secret_request_sheet.dart`.
  ApprovalPrompt? get approvalPromptHandler;
  set approvalPromptHandler(ApprovalPrompt? handler);
  AskCallback? get askHandler;
  set askHandler(AskCallback? handler);
  RequestSecretCallback? get secretRequestHandler;
  set secretRequestHandler(RequestSecretCallback? handler);

  /// Jump-to-message executor: scrolls the transcript so the message with
  /// [messageId] is in view. The chat screen installs the handler; null
  /// outside a scrolling chat surface (tests, embedded previews).
  void Function(String messageId)? get scrollToMessageHandler;
  set scrollToMessageHandler(void Function(String messageId)? handler);

  /// The approval manager (mode selector in the composer menu).
  @override
  ApprovalManager get approval;

  /// Applies a new approval mode.
  @override
  void setApprovalMode(ApprovalMode mode);

  /// The live trajectory ledger: a [TrajectorySnapshot] per change, in
  /// append order — one snapshot per finalized session record and per
  /// streaming agent event. Hosts implement it by feeding a core
  /// [TrajectorySnapshotBuilder] (session records through `append`, agent
  /// events through `applyEvent`) — see [TrajectoryServiceFeed] for a
  /// ready-made producer. Hosts without a ledger turn
  /// `FaChatFeatures.trajectory` off instead (a never-emitting stream
  /// would only leave the panel loading).
  Stream<TrajectorySnapshot> get trajectory;

  /// Transcript records sitting ABOVE the loaded window: `null` while the
  /// count is still being computed, `0` once the whole transcript is
  /// loaded, `N` — the number a "Load earlier" banner shows before
  /// tapping [loadOlderHistory] pages the next chunk in. Hosts without
  /// history paging return `0` (the banner never renders).
  int? get historyAboveCount;

  /// Pages the next chunk of older transcript history into view. No-op
  /// while a page load is running or everything is already loaded.
  Future<void> loadOlderHistory();

  /// The last [loadOlderHistory] failure for the history banner's retry
  /// state: null when nothing failed or a retry succeeded. Hosts without
  /// history paging always return null.
  String? get historyLoadError;

  /// Whether a history page load ([loadOlderHistory] or
  /// [loadNewerHistory]) is in flight: the banners render a spinner and
  /// ignore taps while true (issue #135 E6).
  bool get historyLoading;

  /// The exact total transcript-record count once the background count
  /// landed - the N of the terminal "Beginning of session (1 of N)"
  /// banner; `null` until then.
  int? get historyTotalCount;

  /// Whether newer transcript records sit below the loaded window (the
  /// "Load newer" banner's visibility signal - true even while the exact
  /// count is still unknown, e.g. right after a jump). Hosts without
  /// history paging return `false`.
  bool get historyHasNewer;

  /// Transcript records BELOW the loaded window (deep paging evicted the
  /// newest side): `null` while unknown, `0` at the live tail, `N` -
  /// what a "Load newer" banner shows before tapping [loadNewerHistory]
  /// pages the next chunk back in. Visibility comes from
  /// [historyHasNewer], not from this count.
  int? get historyBelowCount;

  /// Pages the next chunk of newer transcript history back into view -
  /// the page-down path back to the live tail after deep paging.
  Future<void> loadNewerHistory();

  /// Jump-to-message (issue #135 AC6): brings the transcript row
  /// [messageId] into the loaded window, paging older history in when
  /// the target sits above the loaded range. Returns whether the target
  /// is now loaded; the caller (the chat screen) then scrolls to it.
  Future<bool> jumpToMessage(String messageId);
}
