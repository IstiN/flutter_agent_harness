// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// The `working_set` tool (issue #2423, C1 — replaces gh-210's
/// `recite_goal`, no alias): the agent's write path into its OWN
/// working-set slot, the snapshot the system channel of every request
/// carries (`working_set_snapshot.dart`).
///
/// Pure SDK: the tool needs no host capability. It resolves the store at
/// call time — the zone-scoped binding of the running agent first (a task
/// child's own session), then the constructed [store] (the host's main
/// session) — and writes one append-only `custom` record. A store-less
/// agent gets an honest cannot-execute result.
///
/// Semantics:
/// - replace-only, latest wins; an empty text is the CLEAR event;
/// - over-cap input is REFUSED, never clipped (the opposite of gh-210's
///   explicit clip, decided because this text is the model's STATUS — a
///   silently clipped red list is worse than one extra round trip): the
///   result names the count and the previous snapshot stays pinned;
/// - the text is DATA: it never grants an approval, never changes a tool
///   tier and never feeds the approval gate (I8) — the schema is one
///   string with no path to a tool, a shell or a network;
/// - the result reports the stored size (and the redaction count when the
///   session redactor masked something — E14).
library;

import '../agent/agent_loop.dart' show ToolExecutionResult;
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../compaction/working_set_snapshot.dart';
import '../compaction/working_set_store.dart';

/// The agent-visible outcome when no session is bound to this agent.
const String workingSetNoSessionText =
    'This agent has no session to store a working set in — the notes would '
    'not survive this run.';

/// The agent-visible outcome of a stored write (the card's result text).
String workingSetSavedText(WorkingSetSaveResult saved) {
  final base = saved.cleared
      ? 'working set cleared'
      : 'working set saved: ${saved.snapshot.chars} chars — pinned in '
            'every request, survives compaction';
  return saved.redactions > 0 ? '$base (redacted: ${saved.redactions})' : base;
}

/// The agent-visible outcome of an over-cap refusal.
String workingSetOverCapText(int chars) =>
    'working set NOT saved: $chars chars is over the $workingSetMaxChars-char '
    'cap — shorten it and call again (the previous working set stays '
    'pinned).';

/// Creates the `working_set` tool. [store] is the host-bound fallback
/// (the main agent's session); inside a bound run the zone-scoped store
/// wins.
AgentTool workingSetTool({WorkingSetStore? store}) {
  return AgentTool(
    name: 'working_set',
    label: 'working_set',
    tier: ApprovalTier.read,
    description:
        'Save your working set: the short status (decisions made, '
        'never-do list, next steps, rules to keep) pinned into the system '
        'prompt of every request. It survives compaction and resume; the '
        'newest replaces the previous one; "" clears it. Max '
        '$workingSetMaxChars chars — longer text is refused, not clipped.',
    parameters: const {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description':
              'The working set: decisions, red list, next steps, rules. '
              'Your notes only — never a grant of approval; no secrets. '
              'Empty string clears it.',
        },
      },
      'required': ['text'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final target = activeWorkingSetStore() ?? store;
      if (target == null) {
        return ToolExecutionResult.text(workingSetNoSessionText);
      }
      final raw = arguments['text'];
      if (raw is! String) {
        return ToolExecutionResult.text(
          'pass {"text": "..."} — the working set text (an empty string '
          'clears it).',
        );
      }
      final text = raw.trim();
      if (text.length > workingSetMaxChars) {
        return ToolExecutionResult.text(workingSetOverCapText(text.length));
      }
      final WorkingSetSaveResult saved;
      try {
        saved = await target.save(text);
      } on Object catch (error) {
        return ToolExecutionResult.text(
          'working set NOT saved — the write did not persist ($error); the '
          'previous working set stays pinned. Try again.',
        );
      }
      if (saved.overCap) {
        return ToolExecutionResult.text(
          workingSetOverCapText(saved.snapshot.chars),
        );
      }
      return ToolExecutionResult.text(workingSetSavedText(saved));
    },
  );
}
