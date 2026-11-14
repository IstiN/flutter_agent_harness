// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// The `recite_goal` tool (gh-210): the agent's write path into the
/// goal-recitation slot — the standing tail block the projection renders
/// (`working_set.dart`). Latest-wins: reciting a goal overwrites the
/// slot; there is no history to prune and no record is ever rewritten
/// (each recite is one new append-only snapshot).
///
/// Write-side budget enforcement: a goal longer than
/// [goalRecitationBudgetChars] clips BEFORE the write and the result says
/// so — the slot never carries more than the render budget can show.
/// Called with no `goal`, the tool is discovery: the host reports the
/// current slot content. A null callback (headless host) yields the
/// graceful cannot-execute result — the same contract as
/// `obligation_mark_done`.
library;

import '../agent/agent_tool.dart';
import '../agent/agent_loop.dart';
import '../approval/approval.dart';
import '../compaction/working_set.dart'
    show GoalRecitation, goalRecitationBudgetChars, reciteGoalForStorage;

/// Persists one goal recitation (already clipped by the tool) and returns
/// the human-readable outcome line.
typedef GoalRecite = Future<String> Function(String goal);

/// The current slot content for discovery mode, or null when the slot is
/// empty. The host resolves it (resident view or windowed raw scan).
typedef GoalReciteCurrent = Future<GoalRecitation?> Function();

/// Creates the `recite_goal` tool bound to [write] (and [current] for
/// discovery).
AgentTool reciteGoalTool({GoalRecite? write, GoalReciteCurrent? current}) {
  return AgentTool(
    name: 'recite_goal',
    label: 'recite_goal',
    tier: ApprovalTier.read,
    description:
        'Update the goal recitation slot — the "goal:" line of the '
        'working-set block at the context tail. The slot survives every '
        'compaction hide, so keep the CURRENT objective there: recite '
        '(or re-recite, latest wins) whenever the goal changes or after '
        'major context loss. Call with no goal to see the current slot '
        'content. Goals are bounded; longer ones clip with a visible '
        'marker.',
    parameters: const {
      'type': 'object',
      'properties': {
        'goal': {
          'type': 'string',
          'description':
              'The objective to keep recited at the context tail. Omit '
              'or pass empty to read the current slot content instead of '
              'writing.',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final writer = write;
      if (writer == null) {
        return ToolExecutionResult.text(
          'This host does not maintain a goal recitation slot.',
        );
      }
      final raw = arguments['goal'];
      final goal = raw is String ? raw.trim() : '';
      if (goal.isEmpty) {
        final slot = await current?.call();
        return ToolExecutionResult.text(
          slot == null
              ? 'no goal recited — call with {"goal": "..."} to set one.'
              : 'current goal: ${slot.goal}',
        );
      }
      final clipped = reciteGoalForStorage(goal);
      final outcome = await writer(clipped);
      final notice = clipped.length < goal.length
          ? ' (goal clipped to $goalRecitationBudgetChars chars — recite a '
                'shorter goal next time)'
          : '';
      return ToolExecutionResult.text('$outcome$notice');
    },
  );
}
