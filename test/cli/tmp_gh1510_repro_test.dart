import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

void main() {
  test('repro: boundary space at exact wrap edge is preserved', () {
    final rows = wrapAnsiLine('aaaa bbbb', 4);
    print(rows.map((r) => '>[$r]<').join('\n'));
    expect(rows.join(), 'aaaa bbbb');
  });
}
