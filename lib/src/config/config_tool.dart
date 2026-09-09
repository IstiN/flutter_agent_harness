/// The agent-facing `config` tool (issue #29 S3): one tool with the ops
/// `check | path | get | set` over the pure [ConfigService] — the same core
/// the `fa config` CLI verbs wrap. The agent drives self-configuration
/// identically on every host (VM, desktop app, browser storage, container)
/// with no shell and no `fa` process; see the `fa-self-config` skill.
library;

import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../exceptions.dart';
import 'config_service.dart';

/// The worst-case op (`set`) mutates a config file, so the tool declares
/// [ApprovalTier.write]. A failed op (unknown key, invalid value, refused
/// write) surfaces as an `error: …` text result — never an exception — so
/// the model always gets an actionable answer.
AgentTool configTool(ConfigService service) {
  Future<String> run(String op, Map<String, dynamic> arguments) async {
    switch (op) {
      case 'check':
        return renderConfigCheckReport(await service.check());
      case 'path':
        return [
          for (final info in await service.paths())
            '${info.label}: ${info.path}${info.exists ? '' : ' (absent)'}',
        ].join('\n');
      case 'get':
      case 'set':
        final key = arguments['key'] as String?;
        if (key == null || key.isEmpty) {
          throw ConfigException('"key" is required for op "$op"');
        }
        if (op == 'get') {
          final result = await service.get(key);
          return result.found
              ? '${result.key} = ${result.display} '
                    '(${result.scope}: ${result.file})'
              : 'not set: $key';
        }
        final value = arguments['value'] as String?;
        if (value == null || value.isEmpty) {
          throw ConfigException('"value" is required for op "set"');
        }
        final scopeArg = arguments['scope'] as String?;
        final scope = switch (scopeArg) {
          'global' => ConfigScope.global,
          'project' => ConfigScope.project,
          _ => null,
        };
        final result = await service.set(key, value, scope: scope);
        return '${result.key} = ${result.newDisplay} '
            '(${result.scope}: ${result.file})\n'
            '${result.application}';
    }
    throw ConfigException('unknown op: "$op" (expected check|path|get|set)');
  }

  return AgentTool(
    name: 'config',
    label: 'config',
    tier: ApprovalTier.write,
    // A batch of config calls reads and rewrites the same files — run the
    // batch one call at a time or the read-modify-write cycles interleave
    // (the e2e suite caught exactly that; issue #29 S4).
    executionMode: ToolExecutionMode.sequential,
    description:
        'Inspect and edit the fa configuration — the user file '
        '~/.fah/config.yaml and the project .fah/config.yaml — without a '
        'shell (the same core the `fa config` CLI verbs wrap, available on '
        'every host). ops: check = validate both files with the real '
        'parsers (errors/warnings/notes + a final ok/failed line); '
        'path = list the config file locations and whether each exists; '
        'get = the effective value of a dotted key (project scope wins '
        'where it participates); set = a surgical single-key write that '
        'validates the edited file BEFORE writing, so an invalid value '
        'persists nothing. Config keys are documented in the fa-self-config '
        'skill — never invent one; unknown keys are rejected. A set result '
        'names the file, scope, old -> new value, and whether the change '
        'applies live or at next boot.',
    parameters: const {
      'type': 'object',
      'properties': {
        'op': {
          'type': 'string',
          'enum': ['check', 'path', 'get', 'set'],
          'description': 'The config operation to run',
        },
        'key': {
          'type': 'string',
          'description':
              'Dotted config key for get/set '
              '(memory.projectPath, tools.web_search, provider, ...)',
        },
        'value': {
          'type': 'string',
          'description':
              'The new value for set, rendered as a yaml scalar: '
              'true/false verbatim, numbers verbatim, lists/maps as compact '
              'JSON, strings plain or quoted',
        },
        'scope': {
          'type': 'string',
          'enum': ['global', 'project'],
          'description':
              'Write scope for set. Default resolves by key: '
              'memory/cube/tools -> the project file (created minimal when '
              'absent), everything else -> the user file',
        },
      },
      'required': ['op'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      try {
        return ToolExecutionResult.text(
          await run(arguments['op'] as String, arguments),
        );
      } on ConfigException catch (error) {
        return ToolExecutionResult.text('error: ${error.message}');
      }
    },
  );
}
