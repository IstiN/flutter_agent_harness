// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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
  });

  /// `user` | `assistant` | `tool` | `system`.
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
abstract interface class FaChatService implements Listenable {
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

  /// The approval manager (mode selector in the composer menu).
  ApprovalManager get approval;

  /// Applies a new approval mode.
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
}
