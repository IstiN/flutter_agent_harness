/// The `request_secret` tool: when the agent needs a credential (API key,
/// token, password) that is not among the available secret env vars, it asks
/// the USER through the host's secure prompt — never through chat text. The
/// host stores the value in its keys store, injects it into the shell
/// environment (`SecretsExecutionEnv.addSecrets`), and registers it with the
/// `SecretRedactor`, so `$NAME` works in later commands without the value
/// ever entering the transcript.
///
/// Same host-callback pattern as the `ask` tool (see `ask_tool.dart`): the
/// harness defines the tool, the host UI answers through an injectable
/// [RequestSecretCallback], and a `null` callback (headless host) throws,
/// which the agent loop converts into an ERROR tool result.
library;

import 'dart:async';

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import 'package:flutter_sandbox/flutter_sandbox.dart';
import '../prompts/prompts.g.dart';

/// Env var names are UPPER_SNAKE; the host UI validates the same pattern.
final RegExp _namePattern = RegExp(r'^[A-Z][A-Z0-9_]*$');

/// The credential the user granted through the host's secret prompt.
final class RequestSecretResult {
  /// Creates a result with the [name] the value was saved under (the host
  /// may have adjusted the requested name) and the entered [value].
  const RequestSecretResult({
    required this.name,
    required this.value,
    this.persisted = true,
  });

  /// The env var name the value is available as (`$name` in shell commands).
  final String name;

  /// The entered secret value. The tool result never echoes it.
  final String value;

  /// Whether the host durably saved the value (a keys store); `false` means
  /// it lives only in the running session's shell environment.
  final bool persisted;
}

/// Answers the agent's credential request on behalf of the user — the host
/// UI surface (Flutter bottom sheet). Returns the granted
/// [RequestSecretResult], or `null` when the user declines: the tool then
/// resolves with a "user declined" result so the model continues gracefully.
typedef RequestSecretCallback =
    Future<RequestSecretResult?> Function(String name, String reason);

/// Creates the `request_secret` tool bound to [callback].
///
/// When [callback] is `null` (headless/non-interactive host), executing the
/// tool throws — the agent loop converts it into an error tool result
/// telling the model this host cannot prompt for secrets (the safe
/// fallback).
///
/// Approval tier is [ApprovalTier.read]: the tool mutates nothing by itself —
/// the user confirms the value in the host's own prompt. Execution is forced
/// to [ToolExecutionMode.sequential] (like `ask`): concurrent requests would
/// clobber the host's single prompt surface.
AgentTool requestSecretTool({RequestSecretCallback? callback}) {
  return AgentTool(
    name: 'request_secret',
    label: 'request_secret',
    tier: ApprovalTier.read,
    executionMode: ToolExecutionMode.sequential,
    description: requestSecretToolDescriptionPrompt,
    parameters: const {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description':
              'Env var name to save the credential under (UPPER_SNAKE, e.g. '
              'GITHUB_TOKEN); prefilled in the user prompt',
        },
        'reason': {
          'type': 'string',
          'description':
              'Why the credential is needed; shown to the user in the prompt',
        },
      },
      'required': ['name', 'reason'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final name = _validateSecretName(arguments['name']);
      final reason = _validateSecretReason(arguments['reason']);
      final request = callback;
      if (request == null) {
        throw StateError(
          'This host cannot request secrets interactively (no secret prompt '
          'is installed). Ask the user to add the key in the settings Keys '
          'section instead.',
        );
      }
      final result = await _awaitResult(request, name, reason, cancelToken);
      if (result == null) {
        return ToolExecutionResult.text('The user declined to provide $name.');
      }
      final saved = result.name;
      if (!result.persisted) {
        return ToolExecutionResult.text(
          'Secret $saved is available as \$$saved for this session only '
          '(the host could not persist it).',
        );
      }
      return ToolExecutionResult.text(
        'Secret $saved saved and available as \$$saved.',
      );
    },
  );
}

/// Validates the `name` argument: an UPPER_SNAKE env var name (the host UI
/// validates the same pattern).
String _validateSecretName(Object? name) {
  if (name is! String || !_namePattern.hasMatch(name)) {
    throw StateError(
      'name must be an UPPER_SNAKE env var name matching '
      '^[A-Z][A-Z0-9_]*\$',
    );
  }
  return name;
}

/// Validates the `reason` argument: a non-empty string shown to the user.
String _validateSecretReason(Object? reason) {
  if (reason is! String || reason.trim().isEmpty) {
    throw StateError('reason must be a non-empty string');
  }
  return reason;
}

/// Awaits the host's answer, unblocking promptly with [CancelledException]
/// when the run is aborted while the host still waits for input.
Future<RequestSecretResult?> _awaitResult(
  RequestSecretCallback request,
  String name,
  String reason,
  CancelToken? cancelToken,
) {
  final result = request(name, reason);
  if (cancelToken == null) return result;
  final cancelled = cancelToken.onCancel.then<RequestSecretResult?>(
    (_) => throw CancelledException(cancelToken.cancelReason),
  );
  return Future.any([result, cancelled]);
}
