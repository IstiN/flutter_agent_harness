// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/notify_service.dart';

/// Name of the agent tool that schedules a local system notification.
const notifyToolName = 'notify';

/// The shared availability gate: `null` when notifications may be posted,
/// otherwise the user-facing explanation (unsupported platform, or access
/// denied with where to enable it). Requests OS access on the first call.
Future<String?> _unavailable(NotifyApi notify) async {
  if (!await notify.isAvailable) {
    return 'Local notifications are not supported on this platform.';
  }
  // The OS shows its access prompt at most once; later calls return the
  // stored decision without prompting again.
  if (!await notify.requestAccess()) {
    return 'Notification access was denied. The user can enable it in '
        'System Settings → Notifications → Fa (macOS) or Settings → '
        'Notifications → Fa (iOS), then ask again.';
  }
  return null;
}

/// Creates the `notify` tool bound to [notify].
///
/// Tier write: posting a notification is a user-visible side effect, so the
/// approval gate applies. The description steers the agent to use the tool
/// sparingly — a notification per turn would spam the user. Texts are
/// LLM-facing and stay literal English (not UI copy).
AgentTool notifyTool(NotifyApi notify) {
  return AgentTool(
    name: notifyToolName,
    label: 'notify',
    tier: ApprovalTier.write,
    description:
        'Schedule a local system notification the user sees even when the '
        'app is not in the foreground. Use SPARINGLY: only for long-running '
        'or background-relevant updates the user asked to be surfaced (e.g. '
        '"notify me when the build finishes" or a reminder) — never for '
        'ordinary per-turn replies. Fires immediately unless delaySeconds '
        'is set. Returns the scheduled notification id.',
    parameters: const {
      'type': 'object',
      'properties': {
        'title': {
          'type': 'string',
          'description': 'Notification title (required)',
        },
        'body': {'type': 'string', 'description': 'Optional body text'},
        'delaySeconds': {
          'type': 'number',
          'description':
              'Seconds to wait before firing, >= 0 (default: 0 — fire '
              'immediately). No repeats.',
        },
      },
      'required': ['title'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(notify);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final title = (arguments['title'] ?? '').toString().trim();
      if (title.isEmpty) {
        return ToolExecutionResult.text('Error: title is required.');
      }
      final delay = (arguments['delaySeconds'] as num?)?.toDouble() ?? 0;
      if (delay < 0) {
        return ToolExecutionResult.text(
          'Error: delaySeconds must be >= 0 (got $delay).',
        );
      }
      final id = await notify.schedule(
        title: title,
        body: _text(arguments, 'body'),
        delaySeconds: delay,
      );
      final when = delay > 0 ? ' in ${_delayLabel(delay)}' : ' immediately';
      return ToolExecutionResult.text(
        'Scheduled notification "$title" firing$when (id: $id).',
      );
    },
  );
}

String? _text(Map<String, dynamic> arguments, String key) {
  final value = arguments[key]?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

String _delayLabel(double seconds) {
  if (seconds < 60) return '${seconds.round()}s';
  final minutes = seconds / 60;
  if (minutes < 60) {
    return '${minutes % 1 == 0 ? minutes.round() : minutes.toStringAsFixed(1)}m';
  }
  final hours = minutes / 60;
  return '${hours % 1 == 0 ? hours.round() : hours.toStringAsFixed(1)}h';
}
