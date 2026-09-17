@TestOn('vm')
library;

import 'dart:io' as io;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_panel.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_projection.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_tui.dart';
import 'package:flutter_agent_harness/src/cli/agent_hub_view.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
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

    test(
      'carryingFrom keeps a detached transcript scroll across a re-push',
      () {
        var prev = FaHubState.transcript(
          agentId: 'main',
          lines: [for (var i = 0; i < 50; i++) '$i'],
          running: true,
        );
        prev = prev.scrollTranscript(-5, viewport: 20); // detach, top 30
        final next = FaHubState.transcript(
          agentId: 'main',
          lines: [for (var i = 0; i < 60; i++) '$i'],
          running: true,
        ).carryingFrom(prev);
        expect(
          next.follow,
          isFalse,
          reason: 'detached browsing must survive the 500ms live re-push',
        );
        expect(next.topOffset, 30);
      },
    );

    test('carryingFrom keeps following a running transcript', () {
      final prev = FaHubState.transcript(
        agentId: 'main',
        lines: const ['a'],
        running: true,
      );
      final next = FaHubState.transcript(
        agentId: 'main',
        lines: const ['a', 'b'],
        running: true,
      ).carryingFrom(prev);
      expect(next.follow, isTrue);
    });

    test('carryingFrom keeps the collapsed set across a tree re-push', () {
      final prev = tree().moveSelection(1).toggleCollapseSelected(); // a1
      final next = FaHubState.tree(
        footer: '',
        rows: [
          const HubLine('main', key: 'main'),
          const HubLine('  a1', key: 'a1'),
          const HubLine('    deep', key: 'deep'),
          const HubLine('  b2', key: 'b2'),
        ],
      ).carryingFrom(prev);
      expect(next.collapsedKeys, contains('a1'));
      expect(
        [for (final line in next.visibleRows) line.key],
        ['main', 'a1', 'b2'],
        reason: 'a collapsed branch must not re-expand on a fleet event',
      );
    });

    test('carryingFrom starts fresh on a mode change or first open', () {
      final transcript = FaHubState.transcript(
        agentId: 'main',
        lines: const [],
        running: false,
      );
      // A fresh tree opens with the first row selected.
      expect(tree().carryingFrom(null).selectedKey, 'main');
      expect(tree().carryingFrom(transcript).selectedKey, 'main');
    });
  });

  group('renderHubFrame', () {
    FaHubState treeState({int children = 3}) => FaHubState.tree(
      footer: '2 agents · 0 running',
      rows: [
        const HubLine('main', key: 'main'),
        for (var i = 0; i < children; i++) HubLine('  c$i', key: 'c$i'),
      ],
    );

    test('tree frame renders title, rows, footer and hint within width', () {
      final frame = renderHubFrame(treeState(), width: 64, height: 12);
      final lines = frame.split('\n')..removeLast();
      expect(lines.first, contains('agents hub'));
      expect(frame, contains('main'));
      expect(frame, contains('2 agents · 0 running'));
      expect(frame, contains(FaHubState.defaultTreeHint));
      for (final line in lines) {
        expect(tuiTextWidth(line), lessThanOrEqualTo(64));
      }
    });

    test('the selected row paints inverse video', () {
      final frame = renderHubFrame(treeState(), width: 40, height: 12);
      expect(frame, contains('\x1b[7m main'));
    });

    test('an empty fleet renders the stub row', () {
      final frame = renderHubFrame(
        FaHubState.tree(footer: '', rows: const []),
        width: 40,
        height: 12,
      );
      expect(frame, contains('(no agents)'));
    });

    test('a tall fleet windows around the selection with markers', () {
      final frame = renderHubFrame(
        treeState(children: 20).moveSelection(10),
        width: 40,
        height: 10,
      );
      expect(frame, contains('above'));
      expect(frame, contains('below'));
    });

    test('a following transcript pins to the live edge with the marker', () {
      final frame = renderHubFrame(
        FaHubState.transcript(
          agentId: 'main',
          lines: [for (var i = 0; i < 50; i++) 'line $i'],
          running: true,
        ),
        width: 40,
        height: 12,
      );
      expect(frame, contains('transcript — main (live)'));
      expect(frame, contains('line 49'));
      expect(frame, contains('following live'));
      expect(frame, isNot(contains('below')));
    });

    test('a detached transcript shows its window with both markers', () {
      var state = FaHubState.transcript(
        agentId: 'main',
        lines: [for (var i = 0; i < 50; i++) 'line $i'],
        running: true,
      );
      state = state.scrollTranscript(-5, viewport: 9); // detach at 41
      state = state.scrollTranscript(-20, viewport: 9); // top 21
      final frame = renderHubFrame(state, width: 40, height: 12);
      expect(frame, contains('… 21 above'));
      expect(frame, contains('… 20 below'));
      expect(frame, isNot(contains('following live')));
    });

    test('an empty transcript renders the stub row', () {
      final frame = renderHubFrame(
        FaHubState.transcript(agentId: 'main', lines: const [], running: false),
        width: 40,
        height: 12,
      );
      expect(frame, contains('(empty transcript)'));
    });

    test('oversized lines clip to the frame width', () {
      final frame = renderHubFrame(
        FaHubState.transcript(
          agentId: 'main',
          lines: ['x' * 200],
          running: false,
        ),
        width: 30,
        height: 10,
      );
      for (final line in frame.split('\n')) {
        if (line.isEmpty) continue;
        expect(tuiTextWidth(line), lessThanOrEqualTo(30));
      }
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

    test('a multi-line body renders as a bounded preview', () {
      final panel = DeferredPanel(
        id: 'btw-3',
        kind: DeferredPanelKind.mail,
        from: 'a1',
        body: [for (var i = 1; i <= 30; i++) 'row $i'].join('\n'),
        createdAt: DateTime(2026, 1, 1),
        replyAddress: 'a1',
      );
      final lines = deferredPanelLines(panel, width: 40);
      // header + 6 body rows + truncation tail + action footer
      expect(lines, hasLength(9));
      expect(lines[1], contains('row 1'));
      expect(lines[6], contains('row 6'));
      expect(lines[7], contains('… 24 more'));
      expect(lines.join('\n'), isNot(contains('row 7')));
    });
    test('steering panels carry the delivery lifecycle states', () {
      final panel = DeferredPanel(
        id: 'btw-9',
        kind: DeferredPanelKind.steering,
        from: 'you',
        body: 'hold on',
        createdAt: DateTime(2026, 1, 1),
        state: DeferredPanelState.pending,
      );
      final lines = deferredPanelLines(panel, width: 40);
      expect(lines.first, contains('steering from you · pending'));
      expect(deferredPanelStateIcon(DeferredPanelState.pending), '⏳');
      expect(deferredPanelStateIcon(DeferredPanelState.delivered), '✅');
      expect(deferredPanelStateIcon(DeferredPanelState.dead), '⚠');
      expect(
        deferredPanelTransitionLine(
          panel..state = DeferredPanelState.delivered,
        ),
        '[btw] steering from you → delivered',
      );
      expect(
        deferredPanelTransitionLine(panel..state = DeferredPanelState.dead),
        '[btw] steering from you → queued (agent stalled)',
      );
    });

    test('run settle completes ride-along panels but never steering', () {
      final log = DeferredPanelLog();
      final mail = log.add(kind: DeferredPanelKind.mail, from: 'a1', body: 'm');
      final steering = log.add(
        kind: DeferredPanelKind.steering,
        from: 'you',
        body: 's',
        state: DeferredPanelState.pending,
      );
      final moved = log.transitionRunning(DeferredPanelState.complete);
      expect(moved, [mail.id], reason: 'steering follows delivery, not runs');
      expect(log[steering.id]!.state, DeferredPanelState.pending);
    });
  });

  group('task blocks', () {
    test('headline header + label + dim detail, id out of the header', () {
      final lines = taskBlockLines(
        const TaskBlock(
          kind: 'bash',
          id: 'sh-1',
          state: TaskBlockState.done,
          label: 'echo hi',
          elapsed: 65,
          detail: 'sh-1 · tmp · exit 0 · log: /tmp/log',
        ),
        width: 60,
      );
      expect(lines.first, contains('bash task completed in background'));
      expect(lines.first, contains('1m05s'));
      expect(lines.first, isNot(contains('sh-1')));
      expect(lines.join('\n'), contains('echo hi'));
      expect(lines.join('\n'), contains('sh-1 · tmp · exit 0 · log: /tmp/log'));
    });

    test('failed headline carries the exit code', () {
      final lines = taskBlockLines(
        const TaskBlock(
          kind: 'bash',
          id: 'sh-2',
          state: TaskBlockState.failed,
          exitCode: 3,
          label: 'false',
        ),
        width: 60,
      );
      expect(lines.first, contains('bash task failed (exit 3)'));
    });

    test('content clips to the requested width — every line fits', () {
      for (final width in const [80, 120, 200]) {
        final lines = taskBlockLines(
          TaskBlock(
            kind: 'bash',
            id: 'sh-3',
            state: TaskBlockState.done,
            label: 'echo ${'x' * 300}',
            elapsed: 2,
            detail: 'sh-3 · exit 0',
          ),
          width: width,
        );
        for (final line in lines) {
          expect(line.length, lessThanOrEqualTo(width), reason: 'w=$width');
        }
      }
    });

    test('summary card renders terminal counts with the hint line', () {
      final lines = shellJobSummaryCardLines(
        total: 17,
        running: 0,
        done: 16,
        lost: 1,
        width: 80,
      );
      expect(lines.first, contains('Background jobs (17)'));
      expect(lines.first, contains('0 running'));
      expect(lines.first, contains('16 done'));
      expect(lines.first, contains('1 lost'));
      expect(lines.join('\n'), contains('bash_job status'));
    });

    test('live summary line keeps every segment present', () {
      final line = shellJobLiveSummaryLine(
        total: 17,
        running: 2,
        done: 15,
        lost: 0,
      );
      expect(line, contains('⟳ Background jobs (17)'));
      expect(line, contains('2 running'));
      expect(line, contains('15 done'));
      expect(line, contains('0 lost'));
    });
  });

  group('AC4 issue #599 capped-card goldens', () {
    final update = io.Platform.environment.containsKey('FA_UPDATE_599_GOLDENS');
    for (final theme in const ['default', 'ohmypi-light']) {
      test('golden: capped heredoc card ($theme)', () {
        FaThemeController.instance.reset();
        FaThemeController.instance.switchTo(theme);
        final heredoc = [
          "cat > /tmp/i572.md << 'EOF'",
          for (var i = 1; i <= 58; i++) 'heredoc body line $i',
          'EOF',
        ].join('\n');
        final card = [
          for (final line in taskBlockLines(
            TaskBlock(
              kind: 'bash',
              id: 'sh-14',
              state: TaskBlockState.done,
              label: heredoc,
              elapsed: 2,
              detail: 'sh-14 · i572 · exit 0 · log: .fah/bash_jobs/sh-14.log',
            ),
            width: 80,
          ))
            tuiDim(line),
        ].join('\n');
        final file = io.File('test/cli/goldens/job_card_capped_$theme.ans');
        if (update) {
          file.writeAsStringSync('$card\n');
          return;
        }
        expect(card, file.readAsStringSync().trim());
      });
    }
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
