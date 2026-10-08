/// The `obligation_mark_done` tool (issue #1380 A1 lifecycle): the
/// agent's explicit close path over the obligations ledger — mark an
/// entry `done` when the work it names is discharged, `superseded` when
/// the owner overrode the rule/ask. The old entry STAYS (status-flipped,
/// position kept) so "you said X then Y" stays auditable; nothing is ever
/// deleted.
///
/// Called with no `id`, the tool lists the open obligations with their
/// ids — the discovery mode the agent uses before closing. The close
/// itself runs through the host's [ObligationClose] callback (the CLI's
/// writer + snapshot persistence); a null callback (headless host
/// without the ledger) yields the graceful cannot-execute result.
library;

import '../agent/agent_tool.dart';
import '../agent/agent_loop.dart';
import '../approval/approval.dart';

/// Closes (or supersedes) one obligation by id and returns the
/// human-readable outcome line. An EMPTY [id] is the discovery mode: the
/// host returns the open-obligation listing (ids, statuses, clipped
/// quotes) instead of closing anything.
typedef ObligationClose = Future<String> Function(String id, String status);

/// Creates the `obligation_mark_done` tool bound to [close].
AgentTool obligationMarkDoneTool({ObligationClose? close}) {
  return AgentTool(
    name: 'obligation_mark_done',
    label: 'obligation_mark_done',
    tier: ApprovalTier.read,
    description:
        'Close an obligation from the session obligations ledger (the '
        '<system-notice> block): mark it done when the work it names is '
        'discharged, superseded when the owner overrode the rule or ask. '
        'Call with no id to list the open obligations and their ids. The '
        'entry is never deleted — closing only flips its status, keeping '
        'the audit trail.',
    parameters: const {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description':
              'The obligation entry id to close (from the ledger block or '
              'a no-id listing call)',
        },
        'status': {
          'type': 'string',
          'enum': ['done', 'superseded'],
          'description':
              'Target status: done (work discharged, default) or '
              'superseded (the owner overrode it)',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final closer = close;
      if (closer == null) {
        return ToolExecutionResult.text(
          'This host does not maintain an obligations ledger.',
        );
      }
      final id = arguments['id'];
      final status = arguments['status'];
      // Empty id = discovery mode: the host lists the open obligations
      // with their ids and the agent picks.
      final result = await closer(
        id is String ? id : '',
        status is String && status.isNotEmpty ? status : 'done',
      );
      return ToolExecutionResult.text(result);
    },
  );
}
