/// `schedule_message` — send a delayed note to an agent mailbox (self by
/// default), so an agent can schedule its own follow-up task. Backed by
/// [ScheduledMessageQueue]; pending records persist across restarts.
library;

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import 'scheduled_messages.dart';

/// Parses `90s` / `25m` / `2h` / `1d` (and combinations like `1h30m`).
Duration? parseDelay(String spec) {
  final re = RegExp(r'^(\d+(?:\.\d+)?)(ms|s|m|h|d)');
  var total = Duration.zero;
  var rest = spec.trim();
  while (rest.isNotEmpty) {
    final m = re.firstMatch(rest);
    if (m == null) return null;
    final value = double.parse(m.group(1)!);
    total += switch (m.group(2)!) {
      // All in milliseconds so fractional units work ('0.5m' = 30 s) and
      // 'ms' is not accidentally a thousand-fold (bug: 90ms = 90 seconds).
      'ms' => Duration(milliseconds: value.round()),
      's' => Duration(milliseconds: (value * 1000).round()),
      'm' => Duration(milliseconds: (value * 60000).round()),
      'h' => Duration(milliseconds: (value * 3600000).round()),
      _ => Duration(milliseconds: (value * 86400000).round()),
    };
    rest = rest.substring(m.end);
  }
  return total == Duration.zero ? null : total;
}

AgentTool scheduleMessageTool(ScheduledMessageQueue queue) {
  return AgentTool(
    name: 'schedule_message',
    description:
        'Send a delayed message to an agent mailbox (your own by default) '
        '— schedule a follow-up task to check on something later. The '
        'message wakes the recipient when it fires; it survives restarts.',
    parameters: {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description': 'The message to deliver when the timer fires.',
        },
        'delay': {
          'type': 'string',
          'description':
              'How long to wait: 90s / 25m / 2h / 1d (combinable, e.g. '
              '1h30m).',
        },
        'to': {
          'type': 'string',
          'description': 'Recipient mailbox id; defaults to your own mailbox.',
        },
      },
      'required': ['text', 'delay'],
    },
    tier: ApprovalTier.write,
    execute: (args, cancelToken, onUpdate) async {
      final text = args['text'] as String? ?? '';
      final delay = parseDelay(args['delay'] as String? ?? '');
      if (text.trim().isEmpty) {
        return ToolExecutionResult.text('error: text is required');
      }
      if (delay == null) {
        return ToolExecutionResult.text(
          'error: delay must look like 90s / 25m / 2h / 1d',
        );
      }
      final id = await queue.schedule(
        text: text.trim(),
        delay: delay,
        to: args['to'] as String?,
      );
      final due = DateTime.now().add(delay).toIso8601String();
      return ToolExecutionResult.text(
        'scheduled $id for $due — it will arrive as [scheduled] mail',
      );
    },
  );
}
