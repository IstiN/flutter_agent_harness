import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:test/test.dart';

/// Unit tests for the pure visible-waiting row builder (issue #450): the
/// `⏳ waiting` headline, capped detail rows, and the restart-honesty note.
void main() {
  const timers = [
    (dueMs: 90_000, preview: 'timer one'),
    (dueMs: 240_000, preview: 'timer two'),
  ];

  test('busy renders nothing and no waiters renders nothing', () {
    expect(
      waitingRowLines(
        busy: true,
        waitingJobs: const ['job'],
        waitingTimers: timers,
        waitingLostJobs: 0,
        nowMs: 0,
      ),
      isEmpty,
    );
    expect(
      waitingRowLines(
        busy: false,
        waitingJobs: const [],
        waitingTimers: const [],
        waitingLostJobs: 3,
        nowMs: 0,
      ),
      isEmpty,
    );
  });

  test('single job and single timer make one headline row', () {
    final lines = waitingRowLines(
      busy: false,
      waitingJobs: const ['gh run watch 42'],
      waitingTimers: const [(dueMs: 30_000, preview: 'timer one')],
      waitingLostJobs: 0,
      nowMs: 0,
    );
    expect(lines, hasLength(1));
    expect(lines.single, contains('⏳ waiting · gh run watch 42'));
    expect(lines.single, contains('next wake in 30s (timer)'));
  });

  test('multiple waiters cap detail rows at two and count in the headline', () {
    final lines = waitingRowLines(
      busy: false,
      waitingJobs: const ['job a', 'job b', 'job c'],
      waitingTimers: timers,
      waitingLostJobs: 0,
      nowMs: 0,
    );
    expect(lines.first, contains('3 jobs'));
    expect(lines.first, contains('2 timers · next wake in '));
    // 2 capped detail rows only — no lost row.
    expect(lines, hasLength(3));
    expect(lines[1], contains('job a'));
    expect(lines[2], contains('job b'));
  });

  test('lost jobs render the restart-honesty note with correct grammar', () {
    final one = waitingRowLines(
      busy: false,
      waitingJobs: const ['job a'],
      waitingTimers: const [],
      waitingLostJobs: 1,
      nowMs: 0,
    );
    expect(
      one.last,
      contains('1 background job from the previous run was lost'),
    );
    final many = waitingRowLines(
      busy: false,
      waitingJobs: const ['job a'],
      waitingTimers: const [],
      waitingLostJobs: 2,
      nowMs: 0,
    );
    expect(
      many.last,
      contains('2 background jobs from the previous run were lost'),
    );
  });

  test('multiline job and timer are sanitized to single lines', () {
    final lines = waitingRowLines(
      busy: false,
      waitingJobs: const ['python3 -c "\nimport os\nprint(1)\n" (sh-1)'],
      waitingTimers: const [(dueMs: 30_000, preview: 'line 1\nline 2')],
      waitingLostJobs: 0,
      nowMs: 0,
    );
    expect(lines, hasLength(1));
    expect(lines.single, isNot(contains('\n')));
    expect(lines.single, contains('python3 -c " import os print(1) " (sh-1)'));
  });
}
