/// Pure load-mode tests (issue #680 L1): preset definitions, label
/// round-trips, resolution precedence (flag > env > config), the
/// ArgumentError on a typo'd env/config label, and the demotion rule at
/// the availability layer (an enabled non-essential id becomes
/// discoverable; essentials are pinned; an explicit scope `on` is a
/// standing mount; an explicit `off` still disables).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('preset definitions (issue #680)', () {
    test('pi keeps the 4-tool file+shell base', () {
      expect(essentialToolIdsByLoadMode[AgentLoadMode.pi], {
        'read',
        'write',
        'edit',
        'bash',
      });
    });

    test('omp keeps the card draft base (glob → ls in fa taxonomy)', () {
      expect(essentialToolIdsByLoadMode[AgentLoadMode.omp], {
        'read',
        'write',
        'edit',
        'bash',
        'ls',
        'task',
        'ask',
      });
    });

    test('every essential id is a known tool id', () {
      for (final ids in essentialToolIdsByLoadMode.values) {
        for (final id in ids) {
          expect(knownToolIds, contains(id), reason: 'preset id $id');
        }
      }
    });

    test('labels round-trip through agentLoadModeFromLabel', () {
      for (final mode in AgentLoadMode.values) {
        expect(agentLoadModeFromLabel(mode.label), mode);
      }
      expect(agentLoadModeLabels, [
        for (final mode in AgentLoadMode.values) mode.label,
      ]);
      expect(agentLoadModeFromLabel(null), isNull);
      expect(agentLoadModeFromLabel(''), isNull);
      expect(agentLoadModeFromLabel('nope'), isNull);
    });
  });

  group('resolveAgentLoadMode precedence (flag > env > config)', () {
    test('nothing set → default mode', () {
      expect(resolveAgentLoadMode(), AgentLoadMode.defaultMode);
      expect(
        resolveAgentLoadMode(envMode: '', configMode: ''),
        AgentLoadMode.defaultMode,
      );
    });

    test('flag wins over env and config', () {
      expect(
        resolveAgentLoadMode(
          flagOmp: true,
          envMode: 'default',
          configMode: 'default',
        ),
        AgentLoadMode.omp,
      );
    });

    test('env wins over config', () {
      expect(
        resolveAgentLoadMode(envMode: 'pi', configMode: 'omp'),
        AgentLoadMode.pi,
      );
      expect(resolveAgentLoadMode(envMode: 'omp'), AgentLoadMode.omp);
      expect(
        resolveAgentLoadMode(configMode: 'omp'),
        AgentLoadMode.omp,
      );
    });

    test('empty env label falls through to config (no intent)', () {
      expect(
        resolveAgentLoadMode(envMode: '', configMode: 'omp'),
        AgentLoadMode.omp,
      );
    });

    test('unknown env label throws naming FA_AGENT_MODE', () {
      expect(
        () => resolveAgentLoadMode(envMode: 'ompp'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('FA_AGENT_MODE'),
          ),
        ),
      );
    });

    test('unknown config label throws naming agent.mode', () {
      expect(
        () => resolveAgentLoadMode(configMode: 'pii'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('agent.mode'),
          ),
        ),
      );
    });
  });

  group('availability demotion (issue #680)', () {
    ToolAvailabilityResolution resolve(
      Set<String> essential, {
      Map<String, bool> tools = const {},
    }) {
      return resolveToolAvailability(
        capabilities: {
          for (final id in knownToolIds) id: const ToolCapability.available(),
        },
        scopes: [(ToolScope.session, ToolsConfig(tools: tools))],
        essentialToolIds: essential,
      );
    }

    test('enabled non-essential ids become discoverable', () {
      final resolution = resolve(essentialToolIdsByLoadMode[AgentLoadMode.omp]!);
      expect(resolution.discoverableIds, containsAll(['lsp', 'web_search']));
      expect(
        resolution.discoverableIds,
        everyElement(
          isNot(anyOf(essentialToolIdsByLoadMode[AgentLoadMode.omp]!)),
        ),
      );
    });

    test('essentials are pinned: no scope mention can demote them', () {
      final essential = essentialToolIdsByLoadMode[AgentLoadMode.omp]!;
      // A scope that turns everything off cannot demote an essential to
      // discoverable — but the explicit off still disables it (below).
      final resolution = resolve(essential, tools: {'read': false});
      expect(resolution.discoverableIds, isNot(contains('read')));
      expect(resolution.byId['read']?.enabled, isFalse);
    });

    test('explicit scope on is a standing mount, not discoverable', () {
      final resolution = resolve(
        essentialToolIdsByLoadMode[AgentLoadMode.omp]!,
        tools: {'lsp': true},
      );
      expect(resolution.byId['lsp']?.enabled, isTrue);
      expect(resolution.discoverableIds, isNot(contains('lsp')));
    });

    test('no preset (null essential set) demotes nothing — REG', () {
      final resolution = resolveToolAvailability(
        capabilities: {
          for (final id in knownToolIds) id: const ToolCapability.available(),
        },
        scopes: const [(ToolScope.session, ToolsConfig())],
      );
      expect(resolution.discoverableIds, isEmpty);
    });
  });
}
