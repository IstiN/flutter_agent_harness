// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// THE parity guard (issue #1078 AC6 / UT-2): one yaml document feeds BOTH
/// host config paths — the CLI's [CliConfig.fromYaml] and the app's
/// [parseAppConfigSections] — and the resolved sections must be
/// semantically equal. Drift on either side fails this test, and a red
/// guard blocks merge even when every other test is green.
///
/// Pure: `dart test`, no IO, no Flutter.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// One config exercising every newly-read section at once.
const _yaml = '''
provider: openai-completions
modelId: gpt-x
baseUrl: https://api.example.com
roles:
  default:
    - primary/gpt-x
    - fallback/gpt-mini
  smol:
    - smolhost/smol-1
  slow:
    - slowhost/slow-1
retry:
  retriesPerEntry: 4
tools:
  web_search: false
  bash: true
  no_such_tool: true
ttsr:
  settings:
    enabled: true
    maxInjectionsPerTurn: 5
  rules:
    - name: no-secrets
      pattern: '(?i)api[_-]?key\\s*='
      body: Never echo API keys.
redact:
  enabled: true
  blockMode: true
  allowlist:
    - '[0-9a-f]{40}'
providerTimeouts:
  connectTimeoutMs: 42000
  streamIdleTimeoutMs: 25000
agent:
  mode: omp
''';

YamlMap _parse(String text) => loadYaml(text) as YamlMap;

/// Field-level equality for the config value types (none of them carry
/// value equality — the guard compares shapes explicitly).
void _expectRolesEqual(ModelRolesConfig? cli, ModelRolesConfig? app) {
  expect(app is ModelRolesConfig, cli is ModelRolesConfig);
  if (cli == null || app == null) return;
  expect(app.roles.keys.toSet(), cli.roles.keys.toSet());
  for (final role in cli.roles.keys) {
    final cliChain = cli.roles[role]!;
    final appChain = app.roles[role]!;
    expect(appChain.length, cliChain.length, reason: 'role $role chain size');
    for (var i = 0; i < cliChain.length; i++) {
      expect(appChain[i].provider, cliChain[i].provider, reason: 'role $role');
      expect(appChain[i].modelId, cliChain[i].modelId, reason: 'role $role');
      expect(appChain[i].apiKeyName, cliChain[i].apiKeyName);
      expect(appChain[i].baseUrl, cliChain[i].baseUrl);
    }
  }
  expect(app.retry.retriesPerEntry, cli.retry.retriesPerEntry);
}

void main() {
  final doc = _parse(_yaml);
  final cli = CliConfig.fromYaml(doc);
  final app = parseAppConfigSections(userDoc: doc);

  test('roles: chains resolve identically', () {
    _expectRolesEqual(cli.modelRoles, app.roles);
  });

  test('tools: scope inputs and resolution match the CLI', () {
    // Same scope inputs…
    expect(app.userTools.tools, cli.tools!.tools);
    // …and the same resolved decision over an identical stack.
    final capabilities = {for (final id in knownToolIds) id: ToolCapability.available()};
    final stack = [
      (ToolScope.global, cli.tools!),
      (ToolScope.runtime, const ToolsConfig()),
    ];
    final cliResolution = resolveToolAvailability(
      capabilities: capabilities,
      scopes: stack,
    );
    final appResolution = resolveToolAvailability(
      capabilities: capabilities,
      scopes: [
        (ToolScope.global, app.userTools),
        (ToolScope.runtime, const ToolsConfig()),
      ],
    );
    expect(appResolution.byId.keys, cliResolution.byId.keys);
    for (final id in cliResolution.byId.keys) {
      expect(
        appResolution.byId[id]!.enabled,
        cliResolution.byId[id]!.enabled,
        reason: 'tool $id',
      );
      expect(
        appResolution.byId[id]!.scope,
        cliResolution.byId[id]!.scope,
        reason: 'tool $id',
      );
    }
    expect(appResolution.unknownIds, {'no_such_tool'});
  });

  test('ttsr: settings + rules match', () {
    expect(cli.ttsr is TtsrConfig, app.ttsr is TtsrConfig);
    final cliTtsr = cli.ttsr!;
    final appTtsr = app.ttsr!;
    expect(appTtsr.settings.enabled, cliTtsr.settings.enabled);
    expect(
      appTtsr.settings.maxInjectionsPerTurn,
      cliTtsr.settings.maxInjectionsPerTurn,
    );
    expect(appTtsr.rules.length, cliTtsr.rules.length);
    for (var i = 0; i < cliTtsr.rules.length; i++) {
      expect(appTtsr.rules[i].name, cliTtsr.rules[i].name);
      expect(appTtsr.rules[i].body, cliTtsr.rules[i].body);
      expect(appTtsr.rules[i].patterns, cliTtsr.rules[i].patterns);
    }
  });

  test('redact: config matches', () {
    expect(cli.redact is RedactionConfig, app.redact is RedactionConfig);
    final cliRedact = cli.redact!;
    final appRedact = app.redact!;
    expect(appRedact.enabled, cliRedact.enabled);
    expect(appRedact.blockMode, cliRedact.blockMode);
    expect(
      appRedact.allowlistRegexes.map((r) => r.pattern),
      cliRedact.allowlistRegexes.map((r) => r.pattern),
    );
    expect(appRedact.minEntropy, cliRedact.minEntropy);
    expect(appRedact.minLength, cliRedact.minLength);
  });

  test('providerTimeouts: overrides match', () {
    expect(
      app.providerTimeouts is ProviderTimeoutsOverride,
      cli.providerTimeouts is ProviderTimeoutsOverride,
    );
    expect(app.providerTimeouts!.connect, cli.providerTimeouts!.connect);
    expect(app.providerTimeouts!.streamIdle, cli.providerTimeouts!.streamIdle);
    expect(app.providerTimeouts!.connect, const Duration(seconds: 42));
    expect(app.providerTimeouts!.streamIdle, const Duration(seconds: 25));
  });

  test('agent.mode matches the CLI load-mode label', () {
    expect(app.loadMode, AgentLoadMode.omp);
    expect(
      agentLoadModeFromLabel(cli.agentLoadMode),
      app.loadMode,
      reason: 'cli.agentLoadMode=${cli.agentLoadMode}',
    );
  });

  test('an absent section reads as absent on BOTH sides', () {
    final doc = _parse('provider: openai-completions\nmodelId: m\n');
    final cli = CliConfig.fromYaml(doc);
    final app = parseAppConfigSections(userDoc: doc);
    expect(cli.modelRoles, isNull);
    expect(app.roles, isNull);
    expect(cli.ttsr, isNull);
    expect(app.ttsr, isNull);
    expect(cli.redact, isNull);
    expect(app.redact, isNull);
    expect(cli.providerTimeouts, isNull);
    expect(app.providerTimeouts, isNull);
    expect(app.loadMode, AgentLoadMode.defaultMode);
    expect(app.warnings, isEmpty);
  });

  test('a retry:-only doc is a silent no-op on BOTH sides (round-1)', () {
    final doc = _parse('provider: openai-completions\nretry:\n  x: 1\n');
    final cli = CliConfig.fromYaml(doc);
    final app = parseAppConfigSections(userDoc: doc);
    expect(cli.modelRoles, isNull);
    expect(app.roles, isNull);
    expect(app.warnings, isEmpty);
  });

  test('a non-string agent.mode errors on the CLI and warns on the app',
      () {
    final doc = _parse('provider: p\nagent:\n  mode: 42\n');
    final app = parseAppConfigSections(userDoc: doc);
    expect(app.loadMode, AgentLoadMode.defaultMode);
    expect(app.warnings.single, contains('agent.mode'));
  });
}
