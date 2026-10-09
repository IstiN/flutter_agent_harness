import 'package:flutter_agent_harness/src/cli/agent_hub_panel.dart';
import 'package:test/test.dart';

void main() {
  test('probe equality vs literal', () {
    final line = shellJobLiveSummaryLine(running: 1, lost: 999, width: 40)!;
    final expected = '◐ Background jobs (1) · 999 lost';
    // ignore: avoid_print
    print('EQUAL: ${line == expected}');
    // ignore: avoid_print
    print('EXP RUNES: '
        '${expected.runes.map((r) => 'U+${r.toRadixString(16)}').join(' ')}');
  });
}
