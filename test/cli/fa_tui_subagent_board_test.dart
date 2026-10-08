import 'package:dart_tui/dart_tui.dart' hide stripAnsi;
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/subagent_board.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart' show stripAnsi;
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:test/test.dart';

/// gh-1415 — the subagent status board's TUI region: frame wiring tests.
/// AC4 (quiet zero — the empty region never perturbs a frame) and AC2
/// (N rows stack above the busy row, no wrap, no interleaving); the
/// sibling-region guarantee (AC7) rides the exact-height assertions the
/// frame-budget suite already pins.
void main() {
  final t0 = DateTime(2026, 1, 1, 12, 0, 0);

  SubagentBoardRow row(
    String text, {
    bool bright = true,
    SubagentDisplayState state = SubagentDisplayState.running,
  }) {
    // Render through the real renderer so the frames test the whole path.
    final line = subagentStatusLine(
      SubagentStatusRecord(
        id: text,
        name: text,
        state: state,
        spawnedAt: t0,
        tokens: 41000,
      ),
      now: t0,
      width: 100,
    );
    return SubagentBoardRow(text: line, bright: bright);
  }

  FaTuiModel build({
    int termWidth = 80,
    int termHeight = 24,
    List<SubagentBoardRow> subagents = const [],
    List<String> board = const [],
    bool busy = false,
  }) {
    final model =
        FaTuiModel(
              callbacks: FaTuiCallbacks(
                onSubmit: (_, {images = const []}) async {},
                onModelSelected: (_) async {},
                buildSlashMenu: (_) => const [],
                buildModelMenu: (_, _) => const [],
                statusLine: () => '/work · 0tok · turn 0 · test-model',
                prompt: 'fa> ',
              ),
              isExited: () => false,
              termWidth: termWidth,
              termHeight: termHeight,
            ).update(BusyMsg(busy)).$1
            as FaTuiModel;
    return model.copyWith(subagentBoardRows: subagents, jobBoardLines: board);
  }

  FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

  List<String> rowsOf(FaTuiModel m) => m.view().content.split('\n');

  String plainRow(String row) => stripAnsi(row);

  test('UT-4 / AC4: an empty board renders zero extra rows (quiet zero)', () {
    final bare = build(termHeight: 24);
    final withEmptyMsg = send(bare, const SubagentBoardMsg([]));
    // The empty push changes nothing: same frame as a model never told
    // about the region.
    expect(rowsOf(withEmptyMsg), rowsOf(bare));
    expect(rowsOf(withEmptyMsg), hasLength(24));
  });

  test('UT-2 / AC2: 10 subagents stack as 10 rows above the busy row', () {
    final rows = [
      for (var i = 1; i <= 10; i++)
        row('agent-${i.toString().padLeft(2, '0')}'),
    ];
    final model = send(
      build(termHeight: 40, busy: true),
      SubagentBoardMsg(rows),
    );
    final frame = rowsOf(model);
    expect(frame, hasLength(40));
    final plain = frame.map(plainRow).toList();
    // All 10 rows painted, in order, above the busy row.
    final busyIdx = plain.indexWhere((r) => r.contains('Working'));
    expect(busyIdx, greaterThanOrEqualTo(10));
    for (var i = 1; i <= 10; i++) {
      final name = 'agent-${i.toString().padLeft(2, '0')}';
      final idx = plain.indexWhere((r) => r.contains(name), busyIdx - 12);
      expect(idx, greaterThanOrEqualTo(0), reason: name);
      expect(
        idx,
        lessThan(busyIdx),
        reason: '$name must sit above the busy row',
      );
    }
    int nameCell(String frameRow, String name) =>
        tuiTextWidth(frameRow.substring(0, frameRow.indexOf(name)));
    final first = plain.firstWhere((r) => r.contains('agent-01'));
    final last = plain.firstWhere((r) => r.contains('agent-10'));
    expect(nameCell(first, 'agent-01'), nameCell(last, 'agent-10'));
    // No row wraps: every painted row stays within the terminal width.
    for (final r in plain) {
      expect(tuiTextWidth(r), lessThanOrEqualTo(80));
    }
  });

  test('AC7: sibling regions keep their slots (board → waiting → subagents '
      '→ busy)', () {
    final board = [
      '⟳ Background jobs (1) · 1 running · 0 done · 0 lost',
      '↳ sh-1-x · echo hi',
    ];
    final model = build(
      termHeight: 24,
      busy: true,
      board: board,
      subagents: [row('worker')],
    );
    final plain = rowsOf(model).map(plainRow).toList();
    final boardIdx = plain.indexWhere((r) => r.contains('Background jobs'));
    final agentIdx = plain.indexWhere((r) => r.contains('worker'));
    final busyIdx = plain.indexWhere((r) => r.contains('Working'));
    expect(boardIdx, greaterThanOrEqualTo(0));
    expect(agentIdx, greaterThan(boardIdx));
    expect(busyIdx, greaterThan(agentIdx));
  });

  test('squeeze: the newest subagent rows keep the region, never wrap', () {
    final rows = [
      for (var i = 1; i <= 10; i++)
        row('agent-${i.toString().padLeft(2, '0')}'),
    ];
    // A tiny terminal: the optional chrome must yield, not wrap.
    final model = build(termHeight: 10, busy: true, subagents: rows);
    final frame = rowsOf(model);
    expect(frame, hasLength(10));
    final plain = frame.map(plainRow).toList();
    // The newest row survives; somewhere the yield tail may hide the rest.
    expect(plain.where((r) => r.contains('agent-10')), isNotEmpty);
    for (final r in plain) {
      expect(tuiTextWidth(r), lessThanOrEqualTo(80));
    }
  });
}
