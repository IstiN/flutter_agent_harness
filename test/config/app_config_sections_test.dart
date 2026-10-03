// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The app loader's pure section semantics (issue #1078): UT-1 (4-scope
/// tools resolution + load-mode precedence) and UT-3 (malformed/garbage
/// yaml per section → defaults + a warning naming file + section, AC7).
/// E1 (app-UI store wins, yaml fills gaps) is exercised at the merge map
/// level here too — the same precedence the service wires live.
///
/// Pure: `dart test`, no IO, no Flutter.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

YamlMap _doc(String text) => loadYaml(text) as YamlMap;

const _allPresent = ToolCapability.available();
Map<String, ToolCapability> _caps() =>
    {for (final id in knownToolIds) id: _allPresent};

void main() {
  group('UT-1 tools scope stack', () {
    test('global < project < runtime: deepest wins per key', () {
      final app = parseAppConfigSections(
        userDoc: _doc('tools:\n  web_search: false\n  read: false\n'),
        projectDoc: _doc('tools:\n  web_search: true\n  write: false\n'),
      );
      final resolution = resolveToolAvailability(
        capabilities: _caps(),
        // The app stacks user (global) + project + the store (runtime).
        scopes: [
          (ToolScope.global, app.userTools),
          (ToolScope.project, app.projectTools),
          (ToolScope.runtime, const ToolsConfig()),
        ],
      );
      expect(resolution.byId['web_search']!.enabled, isTrue);
      expect(resolution.byId['web_search']!.scope, ToolScope.project);
      expect(resolution.byId['read']!.enabled, isFalse);
      expect(resolution.byId['read']!.scope, ToolScope.global);
      expect(resolution.byId['write']!.enabled, isFalse);
      // The capability floor cannot be force-enabled (fix contract 3).
      final floored = resolveToolAvailability(
        capabilities: {
          ..._caps(),
          'web_search': const ToolCapability.absent('not wired'),
        },
        scopes: [
          (ToolScope.global, parseAppConfigSections(
            userDoc: _doc('tools:\n  web_search: true\n'),
          ).userTools),
        ],
      );
      expect(floored.byId['web_search']!.enabled, isFalse);
    });

    test('E1: the runtime (app-UI store) scope beats yaml intents', () {
      final app = parseAppConfigSections(
        userDoc: _doc('tools:\n  web_search: false\n'),
      );
      final resolution = resolveToolAvailability(
        capabilities: _caps(),
        scopes: [
          (ToolScope.global, app.userTools),
          // The user re-enabled the tool in the app UI (ToolsAvailabilityStore).
          (ToolScope.runtime, const ToolsConfig(tools: {'web_search': true})),
        ],
      );
      expect(resolution.byId['web_search']!.enabled, isTrue);
      expect(resolution.byId['web_search']!.scope, ToolScope.runtime);
    });

    test('omp load mode demotes the lean schema + registers discovery', () {
      final app = parseAppConfigSections(
        userDoc: _doc('agent:\n  mode: omp\n'),
      );
      expect(app.loadMode, AgentLoadMode.omp);
      final resolution = resolveToolAvailability(
        capabilities: _caps(),
        essentialToolIds: essentialToolIdsByLoadMode[app.loadMode],
        scopes: [(ToolScope.runtime, const ToolsConfig())],
      );
      for (final id in essentialToolIdsByLoadMode[AgentLoadMode.omp]!) {
        expect(resolution.byId[id]!.enabled, isTrue, reason: id);
      }
      expect(resolution.discoverableIds, contains('sqlite'));
      expect(discoveryEnabledByLoadMode[app.loadMode], isTrue);
    });

    test('E4: pi load mode is the exact 4-tool benchmark base', () {
      final app = parseAppConfigSections(userDoc: _doc('agent:\n  mode: pi\n'));
      final resolution = resolveToolAvailability(
        capabilities: _caps(),
        essentialToolIds: essentialToolIdsByLoadMode[app.loadMode],
        scopes: [(ToolScope.runtime, const ToolsConfig())],
      );
      expect(app.loadMode, AgentLoadMode.pi);
      // pi (#679): the 4 essentials stay enabled; every other enabled id is
      // demoted to discoverable, and pi has discovery OFF — so the gate
      // mounts exactly the benchmark base and nothing else.
      final enabled = resolution.byId.entries
          .where((e) => e.value.enabled)
          .map((e) => e.key)
          .toSet();
      final piEssential = essentialToolIdsByLoadMode[AgentLoadMode.pi]!;
      expect(enabled.containsAll(piEssential), isTrue);
      // Everything enabled beyond the base is demoted (and discovery is
      // off in pi, so the gate mounts exactly the benchmark base).
      expect(
        enabled.difference(piEssential).every(resolution.discoverableIds.contains),
        isTrue,
      );
      expect(discoveryEnabledByLoadMode[AgentLoadMode.pi], isFalse);
    });

    test('load-mode precedence: FA_AGENT_MODE beats agent.mode', () {
      final app = parseAppConfigSections(
        userDoc: _doc('agent:\n  mode: pi\n'),
        envMode: 'omp',
      );
      expect(app.loadMode, AgentLoadMode.omp);
    });
  });

  group('UT-3 malformed sections (AC7)', () {
    test('garbage roles → default + warning naming file+section', () {
      final app = parseAppConfigSections(
        userDoc: _doc('roles:\n  default: not-a-chain\n'),
      );
      expect(app.roles, isNull);
      expect(app.warnings, hasLength(1));
      expect(app.warnings.single, contains('~/.fah/config.yaml'));
      expect(app.warnings.single, contains('roles'));
    });

    test('garbage tools survives alongside a valid sibling section', () {
      final app = parseAppConfigSections(
        userDoc: _doc(
          'tools: oops\nproviderTimeouts:\n  streamIdleTimeoutMs: 1000\n',
        ),
      );
      expect(app.userTools, isEmpty);
      expect(app.providerTimeouts!.streamIdle, const Duration(seconds: 1));
      expect(app.warnings.single, contains('tools'));
    });

    test('garbage user ttsr degrades to project rules with warnings', () {
      final app = parseAppConfigSections(
        userDoc: _doc('ttsr: 42\n'),
        projectRulesDoc: _doc('rules: [{name: r, pattern: "x", body: b}]'),
      );
      // The user section is dead (warning, AC7); the project rules file
      // still lands — the CLI merge shape (project rules + settings).
      expect(app.ttsr!.settings.enabled, TtsrSettings.defaultSettings.enabled);
      expect(app.ttsr!.rules.single.name, 'r');
      expect(
        app.warnings.any(
          (w) => w.contains('ttsr') && w.contains('~/.fah/config.yaml'),
        ),
        isTrue,
      );
    });

    test('malformed project rules warn and name the file', () {
      final app = parseAppConfigSections(
        // A rule without a name throws in rulesFromYaml → warning (AC7).
        projectRulesDoc: _doc('rules: [{pattern: "x", body: b}]'),
      );
      expect(app.ttsr, isNull);
      expect(app.warnings.single, contains('.fah/rules.yaml'));
      expect(app.warnings.single, contains('ttsr'));
    });

    test('bad agent.mode → default + warning; other sections still land', () {
      final app = parseAppConfigSections(
        userDoc: _doc('agent:\n  mode: bogus\nredact:\n  blockMode: true\n'),
      );
      expect(app.loadMode, AgentLoadMode.defaultMode);
      expect(app.redact!.blockMode, isTrue);
      expect(app.warnings.single, contains('agent.mode'));
    });

    test('bad FA_AGENT_MODE warns and names the environment', () {
      final app = parseAppConfigSections(envMode: 'wat');
      expect(app.loadMode, AgentLoadMode.defaultMode);
      expect(app.warnings.single, contains('FA_AGENT_MODE'));
      expect(app.warnings.single, contains('environment'));
    });

    test('an empty FA_AGENT_MODE is an absent intent, not a warning', () {
      final app = parseAppConfigSections(envMode: '');
      expect(app.loadMode, AgentLoadMode.defaultMode);
      expect(app.warnings, isEmpty);
    });

    test('malformed redact falls back to defaults with a warning', () {
      final app = parseAppConfigSections(userDoc: _doc('redact: [1, 2]\n'));
      expect(app.redact!.enabled, RedactionConfig.fromYaml(null).enabled);
      expect(app.warnings.single, contains('redact'));
      expect(app.warnings.single, contains('~/.fah/config.yaml'));
    });

    test('a redact allowlist entry that is not a valid regex warns', () {
      final app = parseAppConfigSections(
        userDoc: _doc('redact:\n  allowlist: ["([bad"]\n'),
      );
      expect(app.redact, isNull);
      expect(app.warnings.single, contains('redact'));
      expect(app.warnings.single, contains('~/.fah/config.yaml'));
    });

    test('malformed providerTimeouts → default + warning', () {
      final app = parseAppConfigSections(
        userDoc: _doc('providerTimeouts:\n  streamIdleTimeoutMs: nope\n'),
      );
      expect(app.providerTimeouts, isNull);
      expect(app.warnings.single, contains('providerTimeouts'));
    });

    test('a dead mcp: section warns (inventory #2 interim)', () {
      final app = parseAppConfigSections(
        userDoc: _doc('mcp:\n  servers: {}\n'),
      );
      expect(app.mcpConfigured, isTrue);
      expect(app.warnings.single, contains('mcp'));
    });

    test('a retry:-only doc is a silent no-op — CLI parity (round-1)', () {
      final app = parseAppConfigSections(
        userDoc: _doc('retry:\n  retriesPerEntry: 5\n'),
      );
      expect(app.roles, isNull);
      expect(app.warnings, isEmpty);
    });

    test('a non-string agent.mode warns and keeps the default (round-1)',
        () {
      final app = parseAppConfigSections(userDoc: _doc('agent:\n  mode: 42\n'));
      expect(app.loadMode, AgentLoadMode.defaultMode);
      expect(app.warnings.single, contains('agent.mode'));
      expect(app.warnings.single, contains('~/.fah/config.yaml'));
    });

    test('a non-map agent: node warns (round-1)', () {
      final app = parseAppConfigSections(userDoc: _doc('agent: nope\n'));
      expect(app.loadMode, AgentLoadMode.defaultMode);
      expect(app.warnings.single, contains('agent'));
    });

    test('a non-map top-level doc warns and names the file (round-1)', () {
      final app = parseAppConfigSections(
        userDoc: loadYaml('- just\n- a list\n'),
      );
      expect(app.roles, isNull);
      expect(app.warnings.single, contains('expected a map'));
      expect(app.warnings.single, contains('~/.fah/config.yaml'));
    });
  });
}
