// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #429 AC1–AC3: the pure shell-job board — kimi phase mapping, human
/// headlines with the id demoted to a ≤240-char dim detail, and per-turn
/// collapse with live counts. All timing values are injected data, so these
/// tests need no clock.
library;

import 'package:flutter_agent_harness/src/cli/agent_hub_panel.dart';
import 'package:flutter_agent_harness/src/cli/shell_job_board.dart';
import 'package:flutter_agent_harness/src/session/session_record.dart';
import 'package:test/test.dart';

TaskBlock _card(
  String id, {
  String kind = 'bash',
  String command = 'sleep 2',
  TaskBlockState state = TaskBlockState.running,
  double? elapsed,
  String? detail,
}) => TaskBlock(
  id: id,
  kind: kind,
  state: state,
  label: command,
  elapsed: elapsed,
  detail: detail,
);

void main() {
  group('AC1 UT-phase-mapping', () {
    test('a live job maps to the started (running) state', () {
      expect(
        shellJobPhaseOf(isRunning: true, exitCode: null, stopReason: null),
        TaskBlockState.running,
      );
      expect(
        taskBlockHeadline(kind: 'bash', state: TaskBlockState.running),
        'bash task started in background',
        reason: 'the live badge reads as past tense — truthful even if frozen',
      );
    });

    test('clean exit maps to terminal done', () {
      final state = shellJobPhaseOf(isRunning: false, exitCode: 0);
      expect(state, TaskBlockState.done);
      expect(taskBlockStateIsTerminal(state), isTrue);
    });

    test('nonzero exit maps to terminal failed', () {
      final state = shellJobPhaseOf(isRunning: false, exitCode: 3);
      expect(state, TaskBlockState.failed);
      expect(taskBlockStateIsTerminal(state), isTrue);
    });

    test('watchdog death maps to terminal timed out', () {
      final state = shellJobPhaseOf(
        isRunning: false,
        exitCode: null,
        stopReason: 'timeout',
      );
      expect(state, TaskBlockState.timedOut);
      expect(taskBlockStateIsTerminal(state), isTrue);
    });

    test('kill maps to terminal stopped', () {
      for (final reason in const ['cancelled', 'stopped']) {
        final state = shellJobPhaseOf(
          isRunning: false,
          exitCode: null,
          stopReason: reason,
        );
        expect(state, TaskBlockState.stopped, reason: reason);
        expect(taskBlockStateIsTerminal(state), isTrue);
      }
    });

    test('no-settle vanish maps to terminal lost with its reason', () {
      final state = shellJobPhaseOf(isRunning: false, exitCode: null);
      expect(state, TaskBlockState.lost);
      expect(taskBlockStateIsTerminal(state), isTrue);
      expect(shellJobLostReason, 'process gone, no exit reported');
    });

    test('every unknown state lands terminal — never running', () {
      // A nonsense stop reason must not produce a live state.
      final state = shellJobPhaseOf(
        isRunning: false,
        exitCode: null,
        stopReason: 'warp-core-breached',
      );
      expect(state, TaskBlockState.lost);
      expect(taskBlockStateIsTerminal(state), isTrue);
    });
  });

  group('AC2 UT-headline', () {
    test('headlines are human sentences', () {
      expect(
        taskBlockHeadline(
          kind: 'bash',
          state: TaskBlockState.done,
          elapsed: 2.0,
        ),
        'bash task completed in background (2s)',
      );
      expect(
        taskBlockHeadline(
          kind: 'bash',
          state: TaskBlockState.failed,
          exitCode: 1,
        ),
        'bash task failed (exit 1)',
      );
      expect(
        taskBlockHeadline(kind: 'bash', state: TaskBlockState.timedOut),
        'bash task timed out',
      );
      expect(
        taskBlockHeadline(kind: 'bash', state: TaskBlockState.stopped),
        'bash task stopped',
      );
      expect(
        taskBlockHeadline(kind: 'bash', state: TaskBlockState.lost),
        'bash task lost',
      );
    });

    test('the card header carries the headline, the detail carries the id', () {
      final lines = taskBlockLines(
        _card(
          'sh-90-hmbhtv3z4d1lxsezo',
          command: 'cd /work/repo && tail -f app.log',
          state: TaskBlockState.done,
          elapsed: 2.0,
          detail: 'sh-90-hmbhtv3z4d1lxsezo · repo · exit 0',
        ),
        width: 100,
      );
      expect(lines.first, contains('bash task completed in background (2s)'));
      expect(lines.first, isNot(contains('sh-90')));
      expect(lines.join('\n'), contains('sh-90-hmbhtv3z4d1lxsezo'));
      expect(lines.join('\n'), contains('tail -f app.log'));
    });

    test('the dim detail is capped at 240 characters', () {
      final longCommand = 'x' * 500;
      final detail = shellJobCardDetail(
        id: 'sh-1-abc',
        cwd: '/work/$longCommand',
        logPath: '/work/.fah/bash_jobs/sh-1-abc.log',
        state: TaskBlockState.failed,
        exitCode: 1,
      );
      expect(detail.length, lessThanOrEqualTo(240));
      expect(detail, startsWith('sh-1-abc'));
    });
  });

  group('AC3 UT-collapse-counts', () {
    test('N>3 jobs collapse into one summary with live counts', () {
      final board = ShellJobBoard();
      for (var i = 0; i < 17; i++) {
        board.start(_card('sh-$i'));
      }
      expect(board.collapsed, isTrue);
      final live = board.liveLines();
      expect(live.first, contains('Background jobs (17)'));
      expect(live.first, contains('17 running'));
      expect(live.first, contains('0 done'));
      expect(live.first, contains('0 lost'));
    });

    test('counts update live on settle', () {
      final board = ShellJobBoard();
      for (var i = 0; i < 5; i++) {
        board.start(_card('sh-$i'));
      }
      board.settle('sh-0', state: TaskBlockState.done, elapsed: 2.0);
      board.settle(
        'sh-1',
        state: TaskBlockState.failed,
        detail: 'sh-1 · exit 1',
      );
      final live = board.liveLines();
      expect(live.first, contains('Background jobs (5)'));
      expect(live.first, contains('3 running'));
      expect(live.first, contains('1 done'));
      expect(live.first, contains('0 lost'));
    });

    test('lost>0 is always visible — never hidden in a green count', () {
      final board = ShellJobBoard();
      for (var i = 0; i < 4; i++) {
        board.start(_card('sh-$i'));
      }
      board.settle('sh-0', state: TaskBlockState.lost);
      expect(board.liveLines().first, contains('1 lost'));
      // Even a zero count keeps the segment so the field never disappears.
      final board2 = ShellJobBoard();
      for (var i = 0; i < 4; i++) {
        board2.start(_card('sh-$i'));
      }
      expect(board2.liveLines().first, contains('0 lost'));
    });

    test('three or fewer jobs stay individual (no summary)', () {
      final board = ShellJobBoard();
      for (var i = 0; i < 3; i++) {
        board.start(_card('sh-$i'));
      }
      expect(board.collapsed, isFalse);
      expect(
        board.liveLines().join('\n'),
        isNot(contains('Background jobs (')),
      );
    });
  });

  group('turn buckets (age-out + regrow)', () {
    test('a new turn starts a fresh bucket and old turns stop emitting', () {
      final board = ShellJobBoard();
      for (var i = 0; i < 5; i++) {
        board.start(_card('sh-old-$i'));
      }
      board.newTurn();
      expect(board.turn, 2);
      board.start(_card('sh-new'));
      // The live region shows the older bucket's collapsed summary (with
      // its still-live cards counted) and the new turn's row — never a
      // re-emit of settled old rows.
      final live = board.liveLines().join('\n');
      expect(live, contains('· older'));
      expect(live, contains('5 running'));
      expect(live, contains('sh-new'));
      expect(live, isNot(contains('sh-old-0')));
    });

    test(
      'a collapsed turn prints exactly ONE summary card when it settles',
      () {
        final board = ShellJobBoard();
        for (var i = 0; i < 5; i++) {
          board.start(_card('sh-$i'));
        }
        for (var i = 0; i < 5; i++) {
          board.settle('sh-$i', state: TaskBlockState.done, elapsed: 1.0);
        }
        final lines = board.takeTranscriptLines(width: 100).join('\n');
        expect(lines, contains('Background jobs (5)'));
        expect(lines, contains('5 done'));
        expect('Background jobs ('.allMatches(lines), hasLength(1));
        // Individual walls are gone: no per-job cards for a collapsed turn.
        expect(lines, isNot(contains('sh-0')));
        expect(
          board.takeTranscriptLines(width: 100),
          isEmpty,
          reason: 'the summary drains exactly once',
        );
      },
    );

    test('non-collapsed turns emit individual terminal cards', () {
      final board = ShellJobBoard();
      board.start(_card('sh-a', command: 'cp a b'));
      board.settle('sh-a', state: TaskBlockState.done, elapsed: 0.1);
      final lines = board.takeTranscriptLines(width: 100);
      expect(lines.join('\n'), contains('bash task completed in background'));
      expect(lines.join('\n'), contains('cp a b'));
      expect(lines.join('\n'), isNot(contains('Background jobs (')));
    });

    test(
      'a collapsed turn with a straggler waits for it before summarizing',
      () {
        final board = ShellJobBoard();
        for (var i = 0; i < 5; i++) {
          board.start(_card('sh-$i'));
        }
        for (var i = 0; i < 4; i++) {
          board.settle('sh-$i', state: TaskBlockState.done, elapsed: 1.0);
        }
        expect(board.takeTranscriptLines(width: 100), isEmpty);
        board.settle('sh-4', state: TaskBlockState.done, elapsed: 120.0);
        final lines = board.takeTranscriptLines(width: 100).join('\n');
        expect(lines, contains('Background jobs (5)'));
        expect(lines, contains('5 done'));
      },
    );

    test('lost cards stay prominent even in a collapsed turn', () {
      final board = ShellJobBoard();
      for (var i = 0; i < 5; i++) {
        board.start(_card('sh-$i'));
      }
      for (var i = 0; i < 5; i++) {
        board.settle('sh-$i', state: TaskBlockState.lost);
      }
      final lines = board.takeTranscriptLines(width: 100).join('\n');
      expect(lines, contains('Background jobs (5)'));
      expect(lines, contains('5 lost'));
      // A zombie is never hidden inside a green count: lost rows also emit
      // individually.
      expect(lines, contains('bash task lost'));
    });
  });

  group('records (reload never shows running)', () {
    test('records round-trip and a rehydrated board is terminal', () {
      final board = ShellJobBoard();
      board.start(_card('sh-1'));
      board.start(_card('sh-2', command: 'tail -f x'));
      board.settle('sh-1', state: TaskBlockState.done, elapsed: 3.0);
      final records = board.toRecords();
      expect(records, hasLength(2));

      final rehydrated = ShellJobBoard.rehydrated(records);
      for (final card in rehydrated.allCards) {
        expect(
          taskBlockStateIsTerminal(card.state),
          isTrue,
          reason: '${card.id} must never reload as running',
        );
      }
      // The unsettled record resolves to lost, not done.
      final lost = rehydrated.allCards.firstWhere((c) => c.id == 'sh-2');
      expect(lost.state, TaskBlockState.lost);
      // The settled record keeps its truthful terminal state.
      final done = rehydrated.allCards.firstWhere((c) => c.id == 'sh-1');
      expect(done.state, TaskBlockState.done);
    });

    test('rehydrated cards print terminal summaries, no running anywhere', () {
      final records = [
        _card('sh-1', state: TaskBlockState.done, elapsed: 1.0).toRecord(),
        _card('sh-2', state: TaskBlockState.running).toRecord(),
      ];
      final board = ShellJobBoard.rehydrated(records);
      final lines = board.takeTranscriptLines(width: 100).join('\n');
      expect(lines, isNot(contains('running')));
      expect(lines, contains('bash task lost'));
      expect(lines, contains('sh-2'));
    });
  });
  group('latestRecords (session-entry classification)', () {
    CustomRecord registry(Object? data) => CustomRecord(
      id: 'r',
      parentId: 'p',
      timestamp: DateTime.now(),
      customType: 'shell_job_registry',
      data: data,
    );

    test('later registry entries win wholesale', () {
      final entries = <Object>[
        registry([
          {
            'id': 'sh-1',
            'state': 'running',
            'kind': 'bash',
            'label': 'a',
            'turn': 1,
          },
        ]),
        registry([
          {
            'id': 'sh-2',
            'state': 'done',
            'kind': 'bash',
            'label': 'b',
            'turn': 1,
            'exitCode': 0,
          },
        ]),
      ];
      final latest = ShellJobBoard.latestRecords(entries);
      expect(latest, hasLength(1));
      expect(latest.single['id'], 'sh-2');
    });

    test('non-registry and malformed entries are skipped', () {
      final entries = <Object>[
        registry('not-a-list'),
        CustomRecord(
          id: 'x',
          parentId: 'p',
          timestamp: DateTime.now(),
          customType: 'other_thing',
          data: [
            {'id': 'nope'},
          ],
        ),
      ];
      expect(ShellJobBoard.latestRecords(entries), isEmpty);
    });

    test('non-map payload items are filtered out', () {
      final latest = ShellJobBoard.latestRecords([
        registry([
          'junk',
          {
            'id': 'sh-9',
            'state': 'done',
            'kind': 'bash',
            'label': 'c',
            'turn': 2,
            'exitCode': 0,
          },
        ]),
      ]);
      expect(latest, hasLength(1));
      expect(latest.single['id'], 'sh-9');
    });

    test('rehydration from classified records never resurrects running', () {
      final latest = ShellJobBoard.latestRecords([
        registry([
          {
            'id': 'sh-1',
            'state': 'running',
            'kind': 'bash',
            'label': 'a',
            'turn': 1,
          },
        ]),
      ]);
      final board = ShellJobBoard.rehydrated(latest);
      final lines = board.takeTranscriptLines(width: 80);
      expect(lines.join('\n'), contains('lost'));
      expect(lines.join('\n'), isNot(contains('running')));
    });
  });
}
