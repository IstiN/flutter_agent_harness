// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'fa_chat_service.dart';

/// Which phase of an agent run the chat status row (issue #865) shows.
enum FaRunPhaseKind {
  /// No run in flight — the row is hidden.
  hidden,

  /// Provider wait: the request is out but no token came back yet.
  thinking,

  /// Assistant text (or thinking) deltas are streaming in.
  writing,

  /// One or more tool calls are executing.
  tool,
}

/// The live run phase — a pure function of the chat event sequence
/// (AC5): hosts already append every agent event to [FaChatService.messages]
/// (user/assistant/thinking/tool rows and the `[tool] args` system row a
/// tool start emits), so the row needs no extra pipeline and no screen-level
/// state machine.
final class FaRunPhase {
  const FaRunPhase(this.kind, {this.toolName, this.toolCount = 0});

  const FaRunPhase.hidden() : this(FaRunPhaseKind.hidden);

  /// The first tool of the in-flight batch ([FaRunPhaseKind.tool] only).
  const FaRunPhase.tool({required String first, required int count})
    : this(FaRunPhaseKind.tool, toolName: first, toolCount: count);

  final FaRunPhaseKind kind;

  /// The tool to name in the row — the FIRST call of the in-flight batch,
  /// so a parallel batch reads stable instead of flickering per completion.
  final String? toolName;

  /// How many tool calls are in flight (1 for a sequential call).
  final int toolCount;

  @override
  bool operator ==(Object other) =>
      other is FaRunPhase &&
      other.kind == kind &&
      other.toolName == toolName &&
      other.toolCount == toolCount;

  @override
  int get hashCode => Object.hash(kind, toolName, toolCount);

  @override
  String toString() =>
      'FaRunPhase(${kind.name}, tool: $toolName, count: $toolCount)';
}

/// Tool-start rows announce themselves as `` `[name] args` `` system lines
/// (the AgentService convention; prose system lines never start with `[`).
final RegExp _toolStartPrefix = RegExp(r'^\[([^\]]+)\]');

/// Derives the run phase from the event sequence the chat already renders:
/// scan the transcript backwards, matching tool-start system rows against
/// tool-result rows — unmatched starts are the in-flight batch; the first
/// user/assistant/thinking row reached with none in flight names the phase.
///
/// Streaming turns with no phase marker yet (the request just went out) are
/// the provider wait — [FaRunPhaseKind.thinking]. Steering mid-run keeps the
/// row up: as long as [streaming] holds, something is always shown.
FaRunPhase faRunPhase({
  required bool streaming,
  required List<FaChatMessage> messages,
}) {
  if (!streaming) return const FaRunPhase.hidden();
  final cursor = _PhaseCursor();
  for (final message in messages.reversed) {
    final phase = cursor.step(message);
    if (phase != null) return phase;
  }
  return cursor.settledTail() ?? const FaRunPhase(FaRunPhaseKind.thinking);
}

/// Backward-scan state for [faRunPhase]: tool-result rows not yet matched
/// by a start row ([finished]) and unmatched tool starts, oldest first
/// (last added = the first of the in-flight batch).
final class _PhaseCursor {
  var finished = 0;
  final pending = <String>[];

  /// Consumes one transcript row backwards; a non-null phase ends the scan
  /// (a settled boundary row names the phase).
  FaRunPhase? step(FaChatMessage message) {
    final role = message.role;
    if (role == 'tool') {
      finished++;
      return null;
    }
    if (role == 'system') {
      _matchToolStart(message);
      return null;
    }
    return _isBoundary(role) ? _settled(message) : null;
  }

  /// The phase at a settled boundary row: the in-flight batch if any, else
  /// writing for assistant text (thinking rows included) or the provider
  /// wait.
  FaRunPhase _settled(FaChatMessage message) {
    if (pending.isNotEmpty) {
      return FaRunPhase.tool(first: pending.last, count: pending.length);
    }
    return message.role == 'assistant'
        ? const FaRunPhase(FaRunPhaseKind.writing)
        : const FaRunPhase(FaRunPhaseKind.thinking);
  }

  /// The phase when the transcript ends with starts still unmatched — the
  /// scan ran off the top mid-batch. Null keeps the provider wait.
  FaRunPhase? settledTail() {
    if (pending.isEmpty) return null;
    return FaRunPhase.tool(first: pending.last, count: pending.length);
  }

  /// Matches a system row against the tool cursor: a start row names the
  /// in-flight batch unless it settles an already-finished result; prose
  /// system rows (never `[`-prefixed) are ignored.
  void _matchToolStart(FaChatMessage message) {
    final match = _toolStartPrefix.firstMatch(message.content);
    final name = match?.group(1);
    if (name == null) return; // prose system row — not a tool start
    if (finished > 0) {
      finished--;
    } else {
      pending.add(name);
    }
  }
}

/// Whether [role] names a settled transcript row (data the agent produced
/// or the user typed) — reaching one backwards ends the scan.
bool _isBoundary(String role) =>
    role == 'assistant' ||
    role == 'thinking' ||
    role == 'user' ||
    role == 'widget';
