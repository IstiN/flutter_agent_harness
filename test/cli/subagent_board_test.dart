import 'package:flutter_agent_harness/src/cli/subagent_board.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:flutter_agent_harness/src/task/subagent.dart';
import 'package:test/test.dart';

/// gh-1415 — the subagent status line-language: one dense live row per
/// subagent in the CLI TUI.
///
/// UT-1..5 map to the card's acceptance criteria AC1–AC5; the E-classes
/// cover the edge table (E1 narrow terminal, E2 duplicate names, E3 clock
/// skew, E5 absent tokens). Below ~20 columns the fixed rail alone exceeds
/// the viewport — the frame painter's cell-aware clip is the documented
/// last resort there (same belt the job board uses), so the pure-render
/// matrix starts at 20.
void main() {
  final t0 = DateTime(2026, 1, 1, 12, 0, 0);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  SubagentStatusRecord rec(
    String id, {
    String? name,
    SubagentDisplayState state = SubagentDisplayState.running,
    DateTime? spawnedAt,
    int? tokens,
    String? preview,
  }) => SubagentStatusRecord(
    id: id,
    name: name ?? id,
    state: state,
    spawnedAt: spawnedAt ?? t0,
    tokens: tokens,
    preview: preview,
  );

  group('UT-1 / AC1 — one record renders exactly one line ≤ width', () {
    test('running golden: glyph state name age cost preview', () {
      final line = subagentStatusLine(
        rec('goal_builder', tokens: 41000, preview: 'List the files'),
        now: at(12 * 60),
        width: 100,
      );
      expect(line, '⠿  run  goal_builder      12m  41k List the files');
      expect(line.contains('\n'), isFalse);
      expect(tuiTextWidth(line), lessThanOrEqualTo(100));
    });

    test('one line per state (glyph + short verb, no prose)', () {
      final rows = [
        for (final state in SubagentDisplayState.values)
          subagentStatusLine(
            rec('agent', state: state, spawnedAt: t0, tokens: 1000),
            now: at(60),
            width: 100,
          ),
      ];
      expect(rows[SubagentDisplayState.running.index], startsWith('⠿'));
      expect(rows[SubagentDisplayState.running.index], contains(' run '));
      expect(rows[SubagentDisplayState.waiting.index], startsWith('⏸'));
      expect(rows[SubagentDisplayState.waiting.index], contains(' wait '));
      expect(rows[SubagentDisplayState.completed.index], startsWith('✓'));
      expect(rows[SubagentDisplayState.completed.index], contains(' done '));
      expect(rows[SubagentDisplayState.failed.index], startsWith('✗'));
      expect(rows[SubagentDisplayState.failed.index], contains(' fail '));
      for (final line in rows) {
        expect(line.contains('\n'), isFalse, reason: line);
        expect(tuiTextWidth(line), lessThanOrEqualTo(100), reason: line);
      }
    });

    test('every render ≤ width across a content matrix (AC1)', () {
      final cases = [
        rec('a', tokens: 1),
        rec('b', tokens: 999999999, preview: 'x' * 300),
        rec('c' * 60, tokens: 123456789),
        rec('d', state: SubagentDisplayState.failed, tokens: 42),
        rec('e', state: SubagentDisplayState.waiting),
      ];
      for (final c in cases) {
        for (final width in [100, 80, 60, 40, 34, 20]) {
          final line = subagentStatusLine(c, now: at(0), width: width);
          expect(
            tuiTextWidth(line),
            lessThanOrEqualTo(width),
            reason: 'w=$width ${c.id}',
          );
        }
      }
    });
  });

  group('UT-5 / AC5 — the name column ellipsizes, never wraps', () {
    test('boundary ±1: exactly-fitting name keeps, +1 ellipsizes in place', () {
      // The name column is 16 cells at default widths.
      final fits = subagentStatusLine(
        rec('abcdefghijklmno'), // 15
        now: at(0),
        width: 100,
      );
      final exact = subagentStatusLine(
        rec('abcdefghijklmnop'), // 16
        now: at(0),
        width: 100,
      );
      final over = subagentStatusLine(
        rec('abcdefghijklmnopq'), // 17
        now: at(0),
        width: 100,
      );
      expect(fits, contains('abcdefghijklmno '));
      expect(exact, contains('abcdefghijklmnop '));
      // 17 cuts inside the column: 15 chars + the ellipsis, still one line,
      // still aligned (the following columns keep their offsets).
      expect(over, contains('abcdefghijklmno… '));
      expect(
        tuiTextWidth(subagentStatusLine(rec('x' * 200), now: at(0))),
        lessThanOrEqualTo(100),
      );
    });

    test('preview truncates to the remaining budget, never past width', () {
      final line = subagentStatusLine(
        rec('a', preview: 'word ' * 40),
        now: at(0),
        width: 60,
      );
      expect(tuiTextWidth(line), lessThanOrEqualTo(60));
      expect(line.contains('\n'), isFalse);
    });
  });

  group('fixed-width fields — age and cost never overflow their 4 cells', () {
    // gh-1415 review thread 2 (BLOCKING): `1h30m` / `12.3k` / `12.3m`
    // rendered 5 cells in 4-cell fields — rows exceeded the width budget
    // (102 cells at width 100) and the fixed rail misaligned whenever
    // neighbors straddled the 1 h / 10 k / 10 m bounds.
    test('age: ≥1 h collapses into ≤4 cells (1h30 / 12h / 99h+)', () {
      String age(int seconds) => subagentAgeLabel(at(0), at(seconds));
      expect(age(59), '59s');
      expect(age(60), '1m');
      expect(age(3599), '59m');
      expect(age(3600), '1h00');
      expect(age(5400), '1h30'); // was `1h30m` — 5 cells, the reported form
      expect(age(36000), '10h'); // ≥10 h: hours only (12h34 would be 5 cells)
      expect(age(45840), '12h'); // 12 h 34 m → 12h
      expect(age(356400), '99h');
      expect(age(360000), '99h+');
      for (final s in [
        59,
        60,
        3599,
        3600,
        5400,
        36000,
        45840,
        356400,
        360000,
      ]) {
        expect(tuiTextWidth(age(s)), lessThanOrEqualTo(4), reason: '${s}s');
      }
    });

    test('cost: one decimal only below 10 units (4.1k / 12k / 9.9m / 12m)', () {
      expect(subagentCompactTokens(1), '1');
      expect(subagentCompactTokens(999), '999');
      expect(subagentCompactTokens(4100), '4.1k');
      expect(subagentCompactTokens(9999), '10k');
      expect(subagentCompactTokens(12345), '12k'); // was 12.3k — 5 cells
      expect(subagentCompactTokens(41000), '41k');
      expect(subagentCompactTokens(999949), '999k');
      expect(subagentCompactTokens(1234567), '1.2m');
      expect(subagentCompactTokens(12345678), '12m'); // was 12.3m — 5 cells
      expect(subagentCompactTokens(41000000), '41m');
      expect(subagentCompactTokens(1234567890), '999m');
      const cases = [
        1, 999, 4100, 9999, 12345, 41000, 999949, //
        1234567, 12345678, 41000000, 1234567890,
      ];
      for (final t in cases) {
        expect(
          tuiTextWidth(subagentCompactTokens(t)),
          lessThanOrEqualTo(4),
          reason: '$t',
        );
      }
    });

    test('a ≥1 h record with a full preview still fills exactly the width '
        '(AC1 — the review reproducer measured 102 at width 100)', () {
      final line = subagentStatusLine(
        rec('watcher', tokens: 12345, preview: 'w' * 100),
        now: at(5400),
        width: 100,
      );
      expect(tuiTextWidth(line), 100);
    });

    test('the rail stays aligned when neighbors straddle the 1 h / 10 k '
        'bounds', () {
      final young = subagentStatusLine(
        rec('young', spawnedAt: at(0), tokens: 41000, preview: 'P1'),
        now: at(120),
        width: 120,
      );
      final senior = subagentStatusLine(
        rec('senior', spawnedAt: at(0), tokens: 12345, preview: 'P2'),
        now: at(5400),
        width: 120,
      );
      int previewCell(String line, String marker) =>
          tuiTextWidth(line.substring(0, line.indexOf(marker)));
      expect(previewCell(senior, 'P2'), previewCell(young, 'P1'));
    });
  });

  group('UT-2 / AC2 — the region stacks N rows in order', () {
    test('10 simultaneous subagents render as 10 stacked rows, same order', () {
      final region = TaskBoardRegion(now: () => t0);
      final ids = List.generate(
        10,
        (i) => 'agent-${(i + 1).toString().padLeft(2, '0')}',
      );
      for (final id in ids) {
        region.upsert(rec(id, spawnedAt: t0));
      }
      final rows = region.rows(now: t0, width: 120);
      expect(rows, hasLength(10));
      // Same order, never interleaved: each row carries its own agent's
      // name and no other's.
      for (var i = 0; i < ids.length; i++) {
        expect(rows[i].text, contains(ids[i]));
        expect(rows[i].text, isNot(contains(ids[(i + 1) % ids.length])));
        expect(tuiTextWidth(rows[i].text), lessThanOrEqualTo(120));
      }
    });

    test('wide-terminal fixture: rows align on the fixed left rail', () {
      final region = TaskBoardRegion(now: () => t0);
      region.upsert(rec('alpha', spawnedAt: t0, tokens: 41000));
      region.upsert(
        rec('beta', state: SubagentDisplayState.waiting, spawnedAt: t0),
      );
      final rows = region.rows(now: at(120), width: 120);
      // The name column starts at the same CELL on every row (the ⠿ glyph
      // is 1 cell, the ⏸ glyph 2 — the fixed glyph zone pads the rail).
      int nameStartCell(SubagentBoardRow row, String name) =>
          tuiTextWidth(row.text.substring(0, row.text.indexOf(name)));
      expect(nameStartCell(rows[0], 'alpha'), nameStartCell(rows[1], 'beta'));
    });
  });

  group('UT-3 / AC3 — settle collapses per spec, rows are never reused', () {
    test('settle flashes bright, then collapses to a dim one-liner', () {
      final clock = _ManualClock(t0);
      final region = TaskBoardRegion(now: clock.now);
      region.upsert(rec('worker', spawnedAt: t0, tokens: 5000));
      region.upsert(
        rec(
          'worker',
          state: SubagentDisplayState.completed,
          spawnedAt: t0,
          tokens: 5000,
        ),
        at: at(10),
      );
      // Inside the 3 s flash window: still bright.
      expect(region.rows(now: at(12), width: 100).single.bright, isTrue);
      // Past the window: the dim one-line summary persists.
      final settled = region.rows(now: at(20), width: 100);
      expect(settled.single.bright, isFalse);
      expect(settled.single.text, contains('done'));
      expect(settled.single.text, contains('worker'));
    });

    test(
      'the settled row is reused by no one: a new spawn appends after it',
      () {
        final clock = _ManualClock(t0);
        final region = TaskBoardRegion(now: clock.now);
        region.upsert(rec('first', spawnedAt: t0));
        region.upsert(
          rec('first', state: SubagentDisplayState.completed, spawnedAt: t0),
          at: at(5),
        );
        region.upsert(rec('second', spawnedAt: at(6)));
        final rows = region.rows(now: at(10), width: 100);
        expect(rows, hasLength(2));
        expect(rows[0].text, contains('first'));
        expect(rows[0].bright, isFalse); // settled keeps its old slot
        expect(rows[1].text, contains('second'));
        expect(rows[1].bright, isTrue);
      },
    );

    test('a resume revives the row (clears the settle stamp)', () {
      final clock = _ManualClock(t0);
      final region = TaskBoardRegion(now: clock.now);
      region.upsert(rec('w', spawnedAt: t0));
      region.upsert(
        rec('w', state: SubagentDisplayState.completed, spawnedAt: t0),
        at: at(5),
      );
      region.upsert(
        rec('w', state: SubagentDisplayState.running, spawnedAt: t0),
        at: at(6),
      );
      final rows = region.rows(now: at(7), width: 100);
      expect(rows.single.bright, isTrue);
      expect(rows.single.text, contains('run'));
    });

    test('settled rows fold oldest-first beyond the cap (scroll pressure)', () {
      final clock = _ManualClock(t0);
      final region = TaskBoardRegion(now: clock.now, maxSettledRows: 2);
      for (var i = 1; i <= 4; i++) {
        region.upsert(rec('child-$i', spawnedAt: at(i)));
        region.upsert(
          rec(
            'child-$i',
            state: SubagentDisplayState.completed,
            spawnedAt: at(i),
          ),
          at: at(i),
        );
      }
      final texts = region
          .rows(now: at(100), width: 100)
          .map((r) => r.text)
          .toList();
      expect(texts, hasLength(2));
      expect(texts.join('\n'), isNot(contains('child-1')));
      expect(texts.join('\n'), isNot(contains('child-2')));
      expect(texts[0], contains('child-3'));
      expect(texts[1], contains('child-4'));
    });
  });

  group('UT-4 / AC4 — quiet zero', () {
    test('an empty region emits zero rows', () {
      final region = TaskBoardRegion(now: () => t0);
      expect(region.isEmpty, isTrue);
      expect(region.rows(now: t0, width: 100), isEmpty);
    });

    test('a never-seen-live terminal child is history, not news', () {
      final region = TaskBoardRegion(now: () => t0);
      region.upsert(
        rec('old', state: SubagentDisplayState.completed, spawnedAt: t0),
        at: t0,
      );
      expect(region.rows(now: t0, width: 100), isEmpty);
      expect(region.isEmpty, isTrue);
    });
  });

  group('E1 — narrow terminal: preview dies first, glyph never', () {
    test('preview truncates before the name shrinks', () {
      final wide = subagentStatusLine(
        rec('worker', preview: 'Do the thing now'),
        now: at(0),
        width: 100,
      );
      final narrow = subagentStatusLine(
        rec('worker', preview: 'Do the thing now'),
        now: at(0),
        width: 40,
      );
      // Name column intact on both; preview shrank; glyph intact.
      expect(narrow, contains('worker'));
      expect(tuiTextWidth(narrow), lessThanOrEqualTo(40));
      expect(narrow.length, lessThan(wide.length));
      expect(narrow.startsWith('⠿'), isTrue);
    });

    test('below the fixed minimum the name shrinks, the rail stays', () {
      final line = subagentStatusLine(
        rec('a-very-long-agent-name', preview: 'task'),
        now: at(0),
        width: 24,
      );
      expect(line.startsWith('⠿'), isTrue);
      expect(line, contains('run'));
      expect(tuiTextWidth(line), lessThanOrEqualTo(24));
    });
  });

  group('E2 — duplicate names disambiguate with a 4-char id suffix', () {
    test('two same-named subagents carry ·id4 in the name column', () {
      final region = TaskBoardRegion(now: () => t0);
      region.upsert(rec('goal_builder-1', name: 'goal_builder', spawnedAt: t0));
      region.upsert(rec('goal_builder-2', name: 'goal_builder', spawnedAt: t0));
      final rows = region.rows(now: t0, width: 120);
      expect(rows, hasLength(2));
      expect(rows[0].text, contains('·er-1'));
      expect(rows[1].text, contains('·er-2'));
    });

    test('a unique name carries no suffix', () {
      final region = TaskBoardRegion(now: () => t0);
      region.upsert(rec('goal_builder-1', name: 'goal_builder', spawnedAt: t0));
      region.upsert(rec('explore-1', name: 'explore', spawnedAt: t0));
      final texts = region.rows(now: t0, width: 120).map((r) => r.text);
      expect(texts, everyElement(isNot(contains('·'))));
    });
  });

  group('E3 — age recomputes from timestamps, never accumulated ticks', () {
    test('the same record at a later now renders a larger age', () {
      final record = rec('w', spawnedAt: t0);
      final early = subagentStatusLine(record, now: at(30), width: 100);
      final late = subagentStatusLine(record, now: at(90 * 60), width: 100);
      expect(early, contains('  30s'));
      expect(late, contains('1h30'));
    });

    test('a clock jump backwards clamps the age at zero', () {
      final line = subagentStatusLine(
        rec('w', spawnedAt: at(100)),
        now: t0,
        width: 100,
      );
      expect(line, contains('   0s'));
    });
  });

  group('E5 — absent data renders em-dash with alignment preserved', () {
    test('absent tokens render – (zero-usage children included)', () {
      final line = subagentStatusLine(
        rec('w', spawnedAt: t0),
        now: at(60),
        width: 100,
      );
      expect(line, contains('  1m'));
      expect(line, contains('    –'));
    });

    test('absent preview renders – inside the preview zone', () {
      final line = subagentStatusLine(
        rec('w', spawnedAt: t0, tokens: 10),
        now: at(60),
        width: 100,
      );
      expect(line, endsWith('–'));
    });

    test('absent spawn time renders – in the age field', () {
      final line = subagentStatusLine(
        SubagentStatusRecord(
          id: 'w',
          name: 'w',
          state: SubagentDisplayState.running,
          spawnedAt: null,
          tokens: 10,
        ),
        now: at(60),
        width: 100,
      );
      expect(line, contains('    –'));
    });
  });

  group('IT-1 — composition from the task machinery (no new fields)', () {
    SubagentHandle handle(
      String id, {
      String? name,
      SubagentStatus status = SubagentStatus.running,
      String? createdAt,
      String? lastActivity,
      int tokens = 0,
      int liveTokens = 0,
      String task = '',
    }) {
      final h =
          SubagentHandle(
              id: id,
              name: name ?? id,
              agentType: 'explore',
              sessionId: 'parent/$id',
              createdAt: createdAt ?? '2026-01-01T12:00:00.000Z',
              task: task,
            )
            ..status = status
            ..tokens = tokens
            ..liveTokens = liveTokens;
      if (lastActivity != null) h.lastActivity = lastActivity;
      return h;
    }

    test('running handle → running record with live tokens folded in', () {
      final record = subagentRecordOf(
        handle('w', tokens: 40000, liveTokens: 1000),
        task: 'List the files',
      );
      expect(record.state, SubagentDisplayState.running);
      expect(record.tokens, 41000);
      expect(record.name, 'w');
      expect(record.spawnedAt, DateTime.parse('2026-01-01T12:00:00.000Z'));
      expect(record.preview, 'List the files');
    });

    test('every SubagentStatus maps onto the four display states', () {
      expect(
        subagentRecordOf(handle('a', status: SubagentStatus.queued)).state,
        SubagentDisplayState.waiting,
      );
      expect(
        subagentRecordOf(handle('b', status: SubagentStatus.idle)).state,
        SubagentDisplayState.waiting,
      );
      expect(
        subagentRecordOf(handle('c', status: SubagentStatus.running)).state,
        SubagentDisplayState.running,
      );
      expect(
        subagentRecordOf(handle('d', status: SubagentStatus.completed)).state,
        SubagentDisplayState.completed,
      );
      expect(
        subagentRecordOf(handle('e', status: SubagentStatus.failed)).state,
        SubagentDisplayState.failed,
      );
      expect(
        subagentRecordOf(handle('f', status: SubagentStatus.aborted)).state,
        SubagentDisplayState.failed,
      );
    });

    test('degraded columns render em-dash (no timestamps, no usage)', () {
      final record = subagentRecordOf(
        handle('g', createdAt: 'not-a-date', lastActivity: ''),
      );
      expect(record.tokens, isNull);
      expect(record.spawnedAt, isNull);
      final line = subagentStatusLine(record, now: t0, width: 100);
      expect(line, contains('    –'));
    });

    test('a multi-line task preview flattens to one line', () {
      final record = subagentRecordOf(
        handle('h', task: 'first line\nsecond line'),
      );
      expect(record.preview, 'first line second line');
      final line = subagentStatusLine(record, now: t0, width: 100);
      expect(line.contains('\n'), isFalse);
    });

    test(
      'the preview strips ANSI escapes (host-side plain-text, thread 3)',
      () {
        final record = subagentRecordOf(
          handle('i', task: '\x1b[31mred\x1b[0m and plain'),
        );
        expect(record.preview, 'red and plain');
        expect(record.preview!.contains('\x1b'), isFalse);
      },
    );
  });
}

/// Manual wall clock for lifecycle tests (E3 discipline: ages come from
/// timestamps, never from ticking the region).
final class _ManualClock {
  _ManualClock(this._now);
  final DateTime _now;
  DateTime now() => _now;
}
