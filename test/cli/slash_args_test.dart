import 'package:flutter_agent_harness/src/cli/slash_args.dart';
import 'package:test/test.dart';

void main() {
  test('empty rest yields empty sub and no args', () {
    final (:sub, :args) = splitSlashArgs('');
    expect(sub, '');
    expect(args, isEmpty);
  });

  test('whitespace-only rest behaves like empty', () {
    final (:sub, :args) = splitSlashArgs('   ');
    expect(sub, '');
    expect(args, isEmpty);
  });

  test('collapses runs of whitespace and trims', () {
    final (:sub, :args) = splitSlashArgs(' /skills  access \t ask ');
    expect(sub, '/skills');
    expect(args, ['access', 'ask']);
  });

  test('tail excludes the subcommand itself', () {
    final (:sub, :args) = splitSlashArgs('tools enable my-tool session');
    expect(sub, 'tools');
    expect(args, ['enable', 'my-tool', 'session']);
  });

  test('sub with no tail yields empty args, not [sub]', () {
    final (:sub, :args) = splitSlashArgs('reload');
    expect(sub, 'reload');
    expect(args, isEmpty);
  });
}
