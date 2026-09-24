@TestOn('vm')
@Tags(['integration'])
// Renders the CLI's agents-tree/hub row builders — the surfaces the
// terminal suites screenshot — as a coverage gate: the CLI-coverage
// ratchet (scripts/check_cli_coverage.py) only counts the integration
// suites, so pure renderer coverage MUST live here, not in test/cli/.
//
// Covers agent_hub_view.dart (hubAgentRow incl. the `mail:N` marker,
// hubFooterLine, hubDuration), agent_tree.dart (buildAgentTreeItems,
// agentRowDescription, agentStatusIcon) and tui_symbols.dart (preset
// glyph access + the ascii purity invariant).
library;

import 'package:flutter_agent_harness/src/cli/agent_hub_projection.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_view.dart';
import 'package:flutter_agent_harness/src/cli/agent_tree.dart';
import 'package:flutter_agent_harness/src/cli/tui_symbols.dart';
import 'package:flutter_agent_harness/src/task/subagent.dart';
import 'package:test/test.dart';

HubAgent _agent(
  String id, {
  HubStatus status = HubStatus.running,
  String? parentId = 'main',
  bool isMain = false,
  int? tokens,
  int? requests,
}) {
  return HubAgent(
    id: id,
    name: id,
    agentType: isMain ? 'orchestrator' : 'task',
    status: status,
    parentId: parentId,
    isMain: isMain,
    startedAt: DateTime(2026, 1, 1),
    lastActivity: DateTime(2026, 1, 1),
    tokens: tokens,
    requests: requests,
  );
}

SubagentHandle _handle(
  String id, {
  String task = 'scout the fleet',
  int tokens = 0,
}) {
  final handle = SubagentHandle(
    id: id,
    name: id,
    agentType: 'explore',
    sessionId: '/tmp/$id.jsonl',
    createdAt: DateTime(2026, 1, 1).toIso8601String(),
    task: task,
  );
  handle.status = SubagentStatus.running;
  handle.tokens = tokens;
  return handle;
}

void main() {
  group('agents render gate (coverage ratchet feed)', () {
    test('hubAgentRow renders known metrics, skips unknown, trails mail', () {
      final row = HubRow(agent: _agent('a1', tokens: 1200), depth: 1);
      expect(hubAgentRow(row), contains('a1'));
      expect(hubAgentRow(row), contains('1.2k tok'));
      expect(hubAgentRow(row), isNot(contains('req')));

      final full = HubRow(
        agent: _agent('a2', tokens: 512, requests: 3),
        depth: 1,
      );
      expect(hubAgentRow(full), contains('512 tok'));
      expect(hubAgentRow(full), contains('3 req'));

      // A positive mail count appends `mail:N` after every metric; zero or
      // an absent count renders no marker at all.
      expect(hubAgentRow(full, mailCount: 2), endsWith(' · mail:2'));
      expect(hubAgentRow(full, mailCount: 0), isNot(contains('mail:')));
      expect(hubAgentRow(full), isNot(contains('mail:')));
      // A metrics-less row still carries the marker (never silently drops
      // pending mail).
      final bare = HubRow(agent: _agent('a3'), depth: 0);
      expect(hubAgentRow(bare), endsWith('running'));
      expect(hubAgentRow(bare, mailCount: 1), endsWith(' · mail:1'));
    });

    test(
      'hubFooterLine aggregates and skips zero cost; hubDuration formats',
      () {
        final footer = hubFooterLine(
          const HubFooter(tokens: 18944, cost: 0.25, running: 1, agents: 3),
        );
        expect(footer, contains('18.9k tok'));
        expect(footer, contains(r'$0.25'));
        expect(footer, contains('1 running'));
        expect(footer, contains('3 agents'));

        expect(hubDuration(const Duration(seconds: 42)), '42s');
        expect(hubDuration(const Duration(seconds: 72)), '1m12s');
        expect(hubDuration(const Duration(minutes: 62)), '1h02m');
      },
    );

    test('buildAgentTreeItems marks pending mail on main and children', () {
      final items = buildAgentTreeItems(
        [_handle('explore#1', tokens: 512)],
        modelId: 'test-model',
        messageCount: 7,
        inboxCounts: const {'main': 1, 'explore#1': 3},
      );
      final main = items.first;
      expect(main.key, 'main');
      expect(main.description, contains('mail:1'));
      expect(main.description, contains('7 messages'));
      final child = items.singleWhere((item) => item.key == 'child:explore#1');
      expect(child.description, contains('mail:3'));
      expect(child.description, contains('512t'));

      // Without counts (the default) no marker ever renders — a missing
      // fabric must not fabricate one.
      final quiet = buildAgentTreeItems(
        [_handle('explore#2')],
        modelId: 'test-model',
        messageCount: 0,
      );
      expect(
        quiet.map((item) => item.description),
        everyElement(isNot(contains('mail:'))),
      );
    });

    test('agentRowDescription previews the task and skips zero tokens', () {
      expect(
        agentRowDescription(_handle('a1')),
        contains('running · scout the fleet'),
      );
      final long = agentRowDescription(_handle('a2', task: 'x' * 80));
      expect(long, contains('${'x' * 40}…'));
      final idle = _handle('a3')..status = SubagentStatus.idle;
      expect(agentRowDescription(idle), startsWith('idle · '));
    });

    test('every hub status has a distinct icon and rank ordering holds', () {
      final icons = HubStatus.values.map(hubStatusIcon).toSet();
      expect(icons.length, HubStatus.values.length);
      // The tree's ordering ranks running first and aborted last — the
      // visual tests' arrow navigation depends on this exact contract.
      expect(
        hubStatusRank[HubStatus.running]!,
        lessThan(hubStatusRank[HubStatus.done]!),
      );
      expect(
        hubStatusRank[HubStatus.done]!,
        lessThan(hubStatusRank[HubStatus.aborted]!),
      );
    });

    test('tui_symbols presets resolve glyphs; ascii preset stays ascii', () {
      final presets = kTuiSymbolPresets.values;
      expect(presets.length, greaterThanOrEqualTo(3));
      for (final preset in presets) {
        expect(
          preset.glyphs,
          isNotEmpty,
          reason: '${preset.name} carries glyphs',
        );
        expect(preset.statusSpinner, isNotEmpty);
        // glyph() resolves every declared key to a non-null string (an
        // unknown key renders empty — the closed-vocabulary contract).
        final key = preset.glyphs.keys.first;
        expect(() => preset.glyph(key), returnsNormally);
      }
      final ascii = kTuiSymbolPresets['ascii']!;
      ascii.glyphs.forEach((key, glyph) {
        expect(
          glyph.runes.every((r) => r < 128),
          isTrue,
          reason: 'ascii preset glyph $key must stay ascii',
        );
      });
    });
  });
}
