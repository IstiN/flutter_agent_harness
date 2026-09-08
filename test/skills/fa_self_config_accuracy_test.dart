/// AC3 accuracy guard for the `fa-self-config` skill (issue #29): every
/// config key and key path the skill documents must exist in the real
/// parsers — no phantom keys, no stale names.
///
/// Method: the test parses every ```yaml fence in the SKILL.md, walks each
/// parsed tree, and checks every key against a pinned key map. The pinned
/// map itself is kept honest against the CODE: each entry names the parser
/// source that must contain the key, and the skill's top-level keys must be
/// a subset of the keys the config parsers actually read (derived from the
/// sources by regex).
///
/// Walk-path grammar: `.`-separated segments; `[]` is a list element; `*`
/// in a PIN matches exactly one walked segment (`roles.*.[].provider`
/// matches `roles.default.[].provider` for a chain map entry). A pin whose
/// LAST segment is `*` is an open map (arbitrary keys, e.g. tool ids).
///
/// VM-only (reads the skill and parser sources from disk).
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

final _repoRoot = Directory.current.path;

String _read(String relative) =>
    File('$_repoRoot/$relative').readAsStringSync();

/// The parser sources that read the TOP-LEVEL config keys.
const _topLevelParserSources = [
  'lib/src/cli/cli_config.dart',
  // `roles:` / `modelOverrides:` / `retry:` are read from the WHOLE config
  // map by ModelRolesConfig.fromYaml (wired from CliConfig.fromYaml).
  'lib/src/model_roles/roles_config.dart',
];

/// All ```yaml fenced blocks in the skill, parsed (config examples are
/// fenced as yaml only).
List<Object?> _skillYamlDocs(String skill) {
  final docs = <Object?>[];
  final fence = RegExp(r'```yaml\n(.*?)```', dotAll: true);
  for (final match in fence.allMatches(skill)) {
    docs.add(loadYaml(match.group(1)!));
  }
  return docs;
}

/// Nested key paths the skill may document → the parser source that reads
/// them.
const _nestedKeySources = <String, String>{
  'memory.projectPath': 'lib/src/memory_config.dart',
  'memory.userPath': 'lib/src/memory_config.dart',
  'cube.enabled': 'lib/src/cube/config/cube_settings.dart',
  'cube.config': 'lib/src/cube/config/cube_settings.dart',
  'providerTimeouts.connectTimeoutMs': 'lib/src/cli/cli_config.dart',
  'providerTimeouts.streamIdleTimeoutMs': 'lib/src/cli/cli_config.dart',
  'skills.access': 'lib/src/cli/cli_config.dart',
  'skills.disableShellExecution': 'lib/src/cli/cli_config.dart',
  'redact.enabled': 'lib/src/cli/cli_config.dart',
  'redact.blockMode': 'lib/src/cli/cli_config.dart',
  'redact.layers': 'lib/src/cli/cli_config.dart',
  'redact.allowlist': 'lib/src/cli/cli_config.dart',
  'redact.toolAllow': 'lib/src/cli/cli_config.dart',
  'redact.toolDeny': 'lib/src/cli/cli_config.dart',
  'redact.layers.*': 'lib/src/redact/redaction_types.dart',
  'retry.retriesPerEntry': 'lib/src/model_roles/roles_config.dart',
  'retry.baseDelayMs': 'lib/src/model_roles/roles_config.dart',
  'retry.maxBackoffMs': 'lib/src/model_roles/roles_config.dart',
  'retry.maxWaitMs': 'lib/src/model_roles/roles_config.dart',
  'retry.keyBackoffMs': 'lib/src/model_roles/roles_config.dart',
  'mcp.toolCallTimeoutMs': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers.*': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers.*.command': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers.*.args': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers.*.env': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers.*.env.*': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers.*.url': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers.*.transport': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers.*.headers': 'lib/src/mcp/mcp_config.dart',
  'mcp.servers.*.headers.*': 'lib/src/mcp/mcp_config.dart',
  'models.slots': 'lib/src/model_roles/models_config.dart',
  'models.custom': 'lib/src/model_roles/models_config.dart',
  'models.slots.*': 'lib/src/model_roles/media_model_slots.dart',
  'models.slots.*.providerKind': 'lib/src/model_roles/media_model_slots.dart',
  'models.slots.*.baseUrl': 'lib/src/model_roles/media_model_slots.dart',
  'models.slots.*.modelId': 'lib/src/model_roles/media_model_slots.dart',
  'models.slots.*.apiKeyName': 'lib/src/model_roles/media_model_slots.dart',
  'models.custom.*': 'lib/src/model_roles/models_config.dart',
  'models.custom.*.provider': 'lib/src/model_roles/models_config.dart',
  'models.custom.*.baseUrl': 'lib/src/model_roles/models_config.dart',
  'models.custom.*.model': 'lib/src/model_roles/models_config.dart',
  'models.custom.*.contextWindow': 'lib/src/model_roles/models_config.dart',
  'models.custom.*.maxTokens': 'lib/src/model_roles/models_config.dart',
  'models.custom.*.input': 'lib/src/model_roles/models_config.dart',
  'roles.*': 'lib/src/model_roles/roles_config.dart',
  'roles.*.[].provider': 'lib/src/model_roles/roles_config.dart',
  'roles.*.[].model': 'lib/src/model_roles/roles_config.dart',
  'roles.*.[].apiKeyName': 'lib/src/model_roles/roles_config.dart',
  'roles.*.[].baseUrl': 'lib/src/model_roles/roles_config.dart',
  'roles.*.[].contextWindow': 'lib/src/model_roles/roles_config.dart',
  'roles.*.[].maxTokens': 'lib/src/model_roles/roles_config.dart',
  'modelOverrides.[].path': 'lib/src/model_roles/roles_config.dart',
  'modelOverrides.[].roles': 'lib/src/model_roles/roles_config.dart',
  'modelOverrides.[].roles.*': 'lib/src/model_roles/roles_config.dart',
  'modelOverrides.[].roles.*.[].provider':
      'lib/src/model_roles/roles_config.dart',
  'modelOverrides.[].roles.*.[].model': 'lib/src/model_roles/roles_config.dart',
  'modelOverrides.[].roles.*.[].apiKeyName':
      'lib/src/model_roles/roles_config.dart',
  'modelOverrides.[].roles.*.[].baseUrl':
      'lib/src/model_roles/roles_config.dart',
  'modelOverrides.[].roles.*.[].contextWindow':
      'lib/src/model_roles/roles_config.dart',
  'modelOverrides.[].roles.*.[].maxTokens':
      'lib/src/model_roles/roles_config.dart',
  'customProviders.[].name': 'lib/src/cli/custom_providers.dart',
  'customProviders.[].apiType': 'lib/src/cli/custom_providers.dart',
  'customProviders.[].baseUrl': 'lib/src/cli/custom_providers.dart',
  'customProviders.[].modelId': 'lib/src/cli/custom_providers.dart',
  'customProviders.[].keyName': 'lib/src/cli/custom_providers.dart',
  'customProviders.[].authMethod': 'lib/src/cli/custom_providers.dart',
  'tools.*': 'lib/src/tools/availability.dart',
  'tools.*.*': 'lib/src/tools/availability.dart',
};

/// Resolves a walked key path against the pins (`*` = exactly one segment).
/// Returns `(parser source, pin key)` or null when the path is unpinned.
(String, List<String>)? _pinFor(List<String> segments) {
  for (final entry in _nestedKeySources.entries) {
    final pin = entry.key.split('.');
    if (pin.length != segments.length) continue;
    var matched = true;
    for (var i = 0; i < pin.length; i++) {
      if (pin[i] != '*' && pin[i] != segments[i]) {
        matched = false;
        break;
      }
    }
    if (matched) return (entry.value, pin);
  }
  return null;
}

/// Walks a parsed yaml tree, collecting every key path (list elements add
/// an `[]` segment).
void _walk(Object? node, List<String> segments, List<String> paths) {
  if (node is YamlMap) {
    for (final entry in node.entries) {
      final child = [...segments, '${entry.key}'];
      if (segments.isNotEmpty) paths.add(child.join('.'));
      _walk(entry.value, child, paths);
    }
  } else if (node is YamlList) {
    for (final element in node) {
      _walk(element, [...segments, '[]'], paths);
    }
  }
}

void main() {
  late String skill;

  setUpAll(() {
    skill = _read('.fah/skills/fa-self-config/SKILL.md');
  });

  test('every documented top-level key is read by the config parsers', () {
    final parserKeys = <String>{};
    for (final source in _topLevelParserSources) {
      parserKeys.addAll(
        RegExp(
          "['\\[]([A-Za-z]+)'\\]",
        ).allMatches(_read(source)).map((m) => m.group(1)!),
      );
    }
    expect(
      parserKeys,
      containsAll(['provider', 'model', 'tools', 'memory']),
      reason:
          'the key-derivation regex must keep matching the parser '
          'sources — if this fails, the config parsers changed shape',
    );
    final phantom = <String>{};
    for (final doc in _skillYamlDocs(skill)) {
      if (doc is YamlMap) {
        for (final key in doc.keys) {
          if (!parserKeys.contains('$key')) phantom.add('$key');
        }
      }
    }
    expect(
      phantom,
      isEmpty,
      reason:
          'fa-self-config/SKILL.md documents top-level config keys '
          '$phantom that the config parsers never read — unknown keys are '
          'silently ignored, so documenting them would be a lie',
    );
  });

  test('every documented nested key is pinned and really parsed', () {
    final unpinned = <String>[];
    final stalePins = <String>[];
    for (final doc in _skillYamlDocs(skill)) {
      final paths = <String>[];
      _walk(doc, const [], paths);
      for (final path in paths) {
        final segments = path.split('.');
        final pin = _pinFor(segments);
        if (pin == null) {
          unpinned.add(path);
          continue;
        }
        final (source, pinSegments) = pin;
        // Open maps (pin ends in `*`) take arbitrary keys — nothing to
        // check the source against.
        if (pinSegments.last == '*') continue;
        final key = segments.lastWhere((s) => s != '[]' && s != '*');
        if (!RegExp('[^A-Za-z0-9_]$key[^A-Za-z0-9_]').hasMatch(_read(source))) {
          stalePins.add('$path (pinned @ $source)');
        }
      }
    }
    expect(
      unpinned,
      isEmpty,
      reason:
          'fa-self-config/SKILL.md documents nested keys $unpinned '
          'outside the pinned key map — extend _nestedKeySources and '
          'verify the parser reads them',
    );
    expect(
      stalePins,
      isEmpty,
      reason:
          'pinned keys no longer found in their parser sources: '
          '$stalePins — the parser renamed or removed them; update the '
          'skill and the pin map together',
    );
  });

  test('documented redaction layers, roles and slots are the real ids', () {
    final enumSource = _read('lib/src/redact/redaction_types.dart');
    for (final layer in [
      'registered',
      'path',
      'credential',
      'vendor',
      'prefix',
      'pem',
      'asn1',
      'connection',
      'context',
      'pii',
      'entropy',
    ]) {
      expect(
        enumSource.contains('  $layer,'),
        isTrue,
        reason: 'redaction layer "$layer" is not a RedactionLayer value',
      );
    }
    final rolesSource = _read('lib/src/model_roles/roles_config.dart');
    for (final role in [
      'default',
      'smol',
      'slow',
      'plan',
      'subagent',
      'memory',
    ]) {
      expect(
        rolesSource.contains("'$role'"),
        isTrue,
        reason: 'role "$role" is not a modelRoleIds entry',
      );
    }
    final slotsSource = _read('lib/src/model_roles/media_model_slots.dart');
    for (final slot in [
      'imageGeneration',
      'audioTts',
      'musicGeneration',
      'videoGeneration',
      'vision',
      'transcription',
    ]) {
      expect(
        slotsSource.contains("'$slot'"),
        isTrue,
        reason: 'slot "$slot" is not a mediaModelSlotIds entry',
      );
    }
  });

  test('documented config file paths appear in the loading code', () {
    expect(skill, contains('~/.fah/config.yaml'));
    expect(skill, contains('.fah/config.yaml'));
    final cliConfig = _read('lib/src/cli/cli_config.dart');
    expect(
      cliConfig,
      contains('.fah/config.yaml'),
      reason:
          'the project config path the skill documents must match '
          'the loader',
    );
  });

  test('the documented config-tool ops are the ops the tool implements', () {
    final toolSource = _read('lib/src/config/config_tool.dart');
    final enumBlock =
        RegExp(r"'enum': \[([^\]]+)\]").firstMatch(toolSource)?.group(1) ??
        (throw StateError('op enum not found in config_tool.dart'));
    final implemented = RegExp(
      "'([a-z]+)'",
    ).allMatches(enumBlock).map((m) => m.group(1)!).toSet();
    // The skill's op table: `| `check` | — | …` rows under "## The config
    // tool".
    final section =
        RegExp(
          r'## The config tool\n(.*?)\n## ',
          dotAll: true,
        ).firstMatch(skill)?.group(1) ??
        (throw StateError('config tool section missing from SKILL.md'));
    final documented = RegExp(
      r'^\| `([a-z]+)` \|',
      multiLine: true,
    ).allMatches(section).map((m) => m.group(1)!).toSet();
    expect(
      documented,
      implemented,
      reason:
          'the fa-self-config op table and config_tool.dart disagree — '
          'extra: ${documented.difference(implemented)}, '
          'missing: ${implemented.difference(documented)}',
    );
  });
}
