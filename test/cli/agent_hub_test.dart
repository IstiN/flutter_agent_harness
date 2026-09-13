@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_panel.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_projection.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_tui.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_view.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

HubAgent _agent(
  String id, {
  HubStatus status = HubStatus.running,
  String? parentId = 'main',
  bool isMain = false,
  int? tokens,
  DateTime? lastActivity,
}) {
  return HubAgent(
    id: id,
    name: id,
    agentType: isMain ? 'orchestrator' : 'task',
    status: status,
    startedAt: DateTime(2026, 1, 1),
    lastActivity: lastActivity ?? DateTime(2026, 1, 1),
    parentId: parentId,
    isMain: isMain,
    tokens: tokens,
  );
}

void main() {
  group('AgentHubProjection', () {
    test('main leads and children sort status-ordered under the parent', () {
      final projection = AgentHubProjection();
      projection.upsert(
        _agent('main', status: HubStatus.waiting, parentId: null, isMain: true),
      );
      projection.upsert(_agent('b2', status: HubStatus.running));
      projection.upsert(_agent('a1', status: HubStatus.done));
      final rows = projection.rows();
      expect([for (final r in rows) r.agent.id], ['main', 'b2', 'a1']);
      expect(rows[1].depth, 1);
    });

    test(
      'a child whose parent is unknown surfaces top-level (orphan rule)',
      () {
        final projection = AgentHubProjection();
        projection.upsert(_agent('ghost-child'));
        final row = projection.rows().single;
        expect(row.agent.id, 'ghost-child');
        expect(row.depth, 0);
      },
    );

    test(
      'active duration accumulates across running spans (observer clock)',
      () {
        var now = DateTime(2026, 1, 1);
        final projection = AgentHubProjection(now: () => now);
        projection.upsert(_agent('a1'));
        now = now.add(const Duration(seconds: 10));
        projection.upsert(_agent('a1', status: HubStatus.done));
        now = now.add(const Duration(seconds: 90));
        projection.upsert(_agent('a1')); // running again
        now = now.add(const Duration(seconds: 5));
        projection.upsert(_agent('a1', status: HubStatus.done));
        // 10s + 5s of observed running, the 90s idle gap excluded.
        expect(projection.activeDuration('a1'), const Duration(seconds: 15));
      },
    );

    test(
      'evictStale drops long-idle terminal agents and keeps running ones',
      () {
        final projection = AgentHubProjection();
        final old = DateTime(2026, 1, 1).add(const Duration(hours: 2));
        projection.upsert(
          _agent('a1', status: HubStatus.done, lastActivity: old),
        );
        projection.upsert(_agent('b2', lastActivity: old));
        final evicted = projection.evictStale(
          maxIdle: const Duration(hours: 1),
        );
        expect(evicted, ['a1']);
        expect(projection['b2'], isNotNull);
      },
    );

    test('upsert keeps the best-known metrics when a snapshot omits them', () {
      final projection = AgentHubProjection();
      projection.upsert(_agent('a1', tokens: 500));
      projection.upsert(_agent('a1'));
      expect(projection['a1']!.tokens, 500);
    });

    test('footer aggregates the whole fleet regardless of visibility', () {
      final projection = AgentHubProjection();
      projection.upsert(
        _agent(
          'main',
          status: HubStatus.waiting,
          parentId: null,
          isMain: true,
          tokens: 100,
        ),
      );
      projection.upsert(_agent('a1', tokens: 50));
      projection.upsert(_agent('b2', status: HubStatus.running, tokens: 25));
      projection.toggleCollapsed('main');
      expect(projection.rows().length, 1); // only main visible
      final footer = projection.footer();
      expect(footer.tokens, 175);
      expect(footer.agents, 3);
      expect(footer.running, 2); // a1 + b2, even with the branch collapsed
    });
  });

  group('hub view', () {
    test('rows render metrics only when known; footer omits zero cost', () {
      final row = hubAgentRow(
        HubRow(agent: _agent('a1', tokens: 1200), depth: 1),
      );
      expect(row, contains('a1'));
      expect(row, contains('1.2k tok'));
      expect(row, isNot(contains('req')));
      final footer = hubFooterLine(
        const HubFooter(tokens: 10, cost: 0, running: 0, agents: 2),
      );
      expect(footer, isNot(contains(r'$')));
    });
  });

  group('FaHubState', () {
    FaHubState tree() => FaHubState.tree(
      footer: '',
      rows: [
        const HubLine('main', key: 'main'),
        const HubLine('  a1', key: 'a1'),
        const HubLine('    deep', key: 'deep'),
        const HubLine('  b2', key: 'b2'),
      ],
    );

    test('selection moves over visible rows and clamps at the edges', () {
      var state = tree();
      state = state.moveSelection(1);
      expect(state.selectedKey, 'a1');
      state = state.moveSelection(-99);
      expect(state.selectedKey, 'main');
      state = state.moveSelection(99);
      expect(state.selectedKey, 'b2');
    });

    test('collapse hides only descendants; footer stays host-owned', () {
      var state = tree();
      state = state.moveSelection(1); // a1
      state = state.toggleCollapseSelected();
      expect(
        [for (final line in state.visibleRows) line.key],
        ['main', 'a1', 'b2'],
      );
    });

    test('transcript scroll detaches at the live edge and re-arms there', () {
      var state = FaHubState.transcript(
        agentId: 'a1',
        lines: [for (var i = 0; i < 50; i++) '$i'],
        running: true,
      );
      state = state.scrollTranscript(-5, viewport: 20);
      expect(state.follow, isFalse);
      expect(state.topOffset, 30);
      state = state.scrollTranscript(5, viewport: 20);
      expect(state.follow, isTrue); // scrolled back onto the live edge
    });

    test('handleKey routes enter/esc to host actions', () {
      var (state, action) = tree().handleKey('enter');
      expect(state.mode, FaHubMode.tree);
      expect(action, FaHubAction.enter);
      (_, action) = tree().handleKey('esc');
      expect(action, FaHubAction.close);
    });

    test('carryingFrom keeps the selection across a re-push', () {
      final prev = tree().moveSelection(1); // a1
      final next = FaHubState.tree(
        footer: '',
        rows: [
          const HubLine('main', key: 'main'),
          const HubLine('  a1', key: 'a1'),
        ],
      ).carryingFrom(prev);
      expect(next.selectedKey, 'a1');
    });
  });

  group('deferred panels', () {
    test('the log assigns ids and evicts beyond capacity', () {
      var now = DateTime(2026, 1, 1);
      final log = DeferredPanelLog(capacity: 2, now: () => now);
      log.add(kind: DeferredPanelKind.mail, from: 'a1', body: 'one');
      now = now.add(const Duration(seconds: 1));
      log.add(kind: DeferredPanelKind.mail, from: 'a1', body: 'two');
      now = now.add(const Duration(seconds: 1));
      final third = log.add(
        kind: DeferredPanelKind.scheduled,
        from: 'scheduler',
        body: 'three',
      );
      expect(log.panels.map((p) => p.body), ['two', 'three']);
      expect(log[third.id], isNotNull);
    });

    test('transitionRunning moves only the running panels', () {
      final log = DeferredPanelLog();
      final a = log.add(kind: DeferredPanelKind.mail, from: 'a1', body: 'x');
      final b = log.add(kind: DeferredPanelKind.mail, from: 'b2', body: 'y');
      log.transition(a.id, DeferredPanelState.error);
      final moved = log.transitionRunning(DeferredPanelState.complete);
      expect(moved, [b.id]);
      expect(log[b.id]!.state, DeferredPanelState.complete);
    });

    test('panel lines fit the width and carry the reply hint', () {
      final panel = DeferredPanel(
        id: 'btw-1',
        kind: DeferredPanelKind.mail,
        from: 'a1',
        body: 'hello',
        createdAt: DateTime(2026, 1, 1),
        replyAddress: 'a1',
      );
      final lines = deferredPanelLines(panel, width: 40);
      for (final line in lines) {
        expect(tuiTextWidth(line), lessThanOrEqualTo(40));
      }
      expect(lines.first, contains('mail from a1'));
      expect(deferredPanelTransitionLine(panel), contains('→ running'));
      expect(replyPrefillFor(panel), '/reply a1 ');
      expect(
        replyPrefillFor(
          DeferredPanel(
            id: 'btw-2',
            kind: DeferredPanelKind.steering,
            from: 'you',
            body: 'x',
            createdAt: DateTime(2026, 1, 1),
          ),
        ),
        isNull,
      );
    });
  });

  group('task blocks', () {
    test('render header with state and elapsed plus the label', () {
      final lines = taskBlockLines(
        const TaskBlock(
          kind: 'bash',
          id: 'sh-1',
          state: TaskBlockState.done,
          label: 'echo hi',
          elapsed: 65,
          detail: '/tmp/log',
        ),
        width: 60,
      );
      expect(lines.first, contains('bash sh-1'));
      expect(lines.first, contains('done'));
      expect(lines.join('\n'), contains('1m05s'));
      expect(lines.join('\n'), contains('echo hi'));
      expect(lines.join('\n'), contains('/tmp/log'));
    });
  });

  group('/mail and /reply commands', () {
    late MemoryExecutionEnv env;
    late FakeCliIO io;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      io = FakeCliIO();
    });

    tearDown(() => io.close());

    AgentCli cliFor() => AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
      ),
      io: io,
      streamFunction: FakeStreamFunction([]).call,
    );

    Future<void> sendAndWait(String line) async {
      io.sendLine(line);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    test('/mail with no panels prints the empty state', () async {
      final cli = cliFor();
      final run = cli.run();
      await sendAndWait('/mail');
      await sendAndWait('/exit');
      await run;
      expect(io.out.toString(), contains('no deferred messages'));
    });

    test('/mail <unknown> points at the bare listing', () async {
      final cli = cliFor();
      final run = cli.run();
      await sendAndWait('/mail btw-9');
      await sendAndWait('/exit');
      await run;
      expect(io.out.toString(), contains('no panel "btw-9"'));
    });

    test('/reply without a target prints usage', () async {
      final cli = cliFor();
      final run = cli.run();
      await sendAndWait('/reply');
      await sendAndWait('/exit');
      await run;
      expect(io.out.toString(), contains('usage: /reply'));
    });

    test('/reply queues the text to the resolved mailbox', () async {
      final cli = cliFor();
      final run = cli.run();
      await sendAndWait('/reply a1 hello there');
      await sendAndWait('/exit');
      await run;
      expect(io.out.toString(), contains('reply queued to a1'));
    });
  });
}
