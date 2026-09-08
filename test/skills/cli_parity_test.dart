/// AC2 rot-guard for the `fa-self-config` skill (issue #29): every
/// settings-affecting CLI command in the REAL command registry must have a
/// documented config-file equivalent in the skill, and the skill must not
/// document phantom commands.
///
/// The registry is walked from the actual sources: the async info-command
/// table and the switch dispatch in `agent_cli_commands.dart` (parsed from
/// source, so a new arm cannot hide) plus the `builtinSlashCommands` map the
/// menu and `/help` render. A new CLI command of either kind fails this test
/// until it is classified here — and a settings-affecting one additionally
/// fails until the skill documents it. Renaming a command without updating
/// the skill fails with a message pointing at the skill marker.
///
/// VM-only (reads source files from disk).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cli/slash_menu.dart';
import 'package:test/test.dart';

final _repoRoot = Directory.current.path;
final _skillPath = '$_repoRoot/.fah/skills/fa-self-config/SKILL.md';
final _dispatchSource = File(
  '$_repoRoot/lib/src/cli/agent_cli_commands.dart',
).readAsStringSync();
final _configArgsSource = File(
  '$_repoRoot/lib/src/cli/cli_args.dart',
).readAsStringSync();

/// Slash commands that appear in the dispatch source (the real routing
/// tables: the `_infoCommandHandlers` map literal and the `case '/…'`
/// switches).
final _dispatchCommands = RegExp(
  "'(/[a-z][a-z0-9-]*)'",
).allMatches(_dispatchSource).map((m) => m.group(1)!).toSet();

/// The full command registry: dispatch routes plus the menu/help map.
final _registry = <String>{
  ..._dispatchCommands,
  ...builtinSlashCommands.keys.where((c) => c.startsWith('/')),
};

/// Commands that CHANGE PERSISTED SETTINGS: each must be documented in the
/// skill (its `<!-- parity: … -->` marker lists it) with its config-file
/// equivalent.
const _settingsCommands = <String, String>{
  '/provider': 'provider/model/baseUrl keys, customProviders:',
  '/providers': 'alias of /provider',
  '/model': 'the model: key (and models.custom switching)',
  '/models': 'the models: section (slots + custom)',
  '/model-edit': 'token limits (persisted via roles: entries)',
  '/memory': 'the memory: section surface (stats/maintain)',
  '/tools': 'the tools: scope stack',
  '/cube': 'the cube: section',
  '/mcp': 'the mcp: section (reload)',
  '/redact': 'the redact: section',
  '/skills': 'the skills: access section',
  '/approval': 'the approvalMode key',
  '/allow': 'the allowedTools key',
  '/mode': 'the mode key',
  '/code': 'mode switch — persists the mode key',
  '/architect': 'mode switch — persists the mode key',
  '/review': 'mode switch — persists the mode key',
  '/settings': 'hub over every section above',
};

/// Commands that do NOT change persisted config. A new command missing from
/// BOTH maps fails the classification test; adding one here requires a
/// one-line reason.
const _nonSettingsCommands = <String, String>{
  '/exit': 'quits the REPL',
  '/help': 'prints help',
  '/terminal-setup': 'prints per-terminal Shift+Enter guidance',
  '/stats': 'read-only token/cost totals',
  '/tasks': 'lists/cancels background jobs',
  '/reset': 'starts a new session (no persisted setting)',
  '/compact': 'manual compaction (no persisted setting)',
  '/trajectory': 'read-only ledger views',
  '/sessions': 'read-only session listing',
  '/session': 'session switching',
  '/resume': 'session switching',
  '/rename-session': 'session rename',
  '/session-new': 'session creation',
  '/agents': 'agent tree views',
  '/browser': 'bridge command passthrough',
  '/a2a': 'read-only server status',
  '/ext': 'extension store/bootstrap state, not config.yaml',
  '/key': 'OS secure store only — key values never live in config.yaml',
};

/// The commands the skill's parity marker documents.
Set<String> _documentedCommands(String skillBody) {
  final marker = RegExp(r'<!--\s*parity:((?:\s/\S+)+)\s*-->');
  final documented = <String>{};
  for (final match in marker.allMatches(skillBody)) {
    documented.addAll(match.group(1)!.trim().split(RegExp(r'\s+')));
  }
  return documented;
}

void main() {
  late String skillBody;

  setUpAll(() {
    skillBody = File(_skillPath).readAsStringSync();
  });

  test('every registry command is classified (settings vs not)', () {
    final unclassified =
        _registry
            .where((c) => !_settingsCommands.containsKey(c))
            .where((c) => !_nonSettingsCommands.containsKey(c))
            .toList()
          ..sort();
    expect(
      unclassified,
      isEmpty,
      reason:
          'new CLI command(s) $unclassified: if they change persisted '
          'settings, add them to _settingsCommands AND document them in '
          'fa-self-config/SKILL.md; otherwise add them to '
          '_nonSettingsCommands with a one-line reason',
    );
  });

  test('classified commands exist in the real registry (no stale entries)', () {
    for (final map in [_settingsCommands, _nonSettingsCommands]) {
      for (final command in map.keys) {
        expect(
          _registry,
          contains(command),
          reason:
              '"$command" is classified but no longer exists in the '
              'CLI registry — remove it from the parity test and check '
              'fa-self-config/SKILL.md for stale references',
        );
      }
    }
  });

  test('every settings command is documented in the skill', () {
    final documented = _documentedCommands(skillBody);
    final missing =
        _settingsCommands.keys.where((c) => !documented.contains(c)).toList()
          ..sort();
    expect(
      missing,
      isEmpty,
      reason:
          'fa-self-config/SKILL.md is missing config-file equivalents '
          'for $missing — add a topic section and list the command(s) in '
          'its <!-- parity: … --> marker',
    );
  });

  test('the skill documents no phantom commands', () {
    final documented = _documentedCommands(skillBody);
    final phantom = documented.where((c) => !_registry.contains(c)).toList()
      ..sort();
    expect(
      phantom,
      isEmpty,
      reason:
          'fa-self-config/SKILL.md documents $phantom which the CLI '
          'registry does not have — a command was renamed or removed; '
          'update the skill section (docs/dap.md-style references to '
          'non-slash surfaces stay outside the markers)',
    );
  });

  test('the skill marker covers only classified settings commands', () {
    final documented = _documentedCommands(skillBody);
    final stray =
        documented.where((c) => !_settingsCommands.containsKey(c)).toList()
          ..sort();
    expect(
      stray,
      isEmpty,
      reason:
          'parity markers exist to pin the settings surface — $stray '
          'are not classified settings commands',
    );
  });

  /// The `fa config` verbs, parsed from the real `configVerbs` const — a new
  /// verb fails this test until the skill documents it, and a documented verb
  /// that vanishes from the CLI fails it the other way (issue #29 S3).
  test(
    'every fa config verb is documented in the skill (no phantom verbs)',
    () {
      final setLiteral =
          RegExp(
            r'const configVerbs = \{([^}]*)\}',
          ).firstMatch(_configArgsSource)?.group(1) ??
          (throw StateError('configVerbs not found in cli_args.dart'));
      final verbs = RegExp(
        "'([a-z-]+)'",
      ).allMatches(setLiteral).map((m) => m.group(1)!).toSet();
      final documented = RegExp(
        'fa config ([a-z][a-z-]*)',
      ).allMatches(skillBody).map((m) => m.group(1)!).toSet();
      expect(
        verbs.difference(documented),
        isEmpty,
        reason:
            'fa config gained verb(s) ${verbs.difference(documented)} — '
            'document them in fa-self-config/SKILL.md (the config-tool section '
            'lists each `fa config <verb>` wrapper)',
      );
      expect(
        documented.difference(verbs),
        isEmpty,
        reason:
            'fa-self-config/SKILL.md documents `fa config '
            '${documented.difference(verbs)}` which cli_args.dart configVerbs '
            'does not have — a verb was renamed or removed; update the skill',
      );
    },
  );
}
