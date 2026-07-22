import 'package:fa/shell_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCommandLine', () {
    test('parses a simple command', () {
      final cmd = parseCommandLine('ls /');
      expect(cmd.statements.length, 1);
      final stage = cmd.statements.single.pipeline.stages.single;
      expect(stage.command, 'ls');
      expect(stage.args, ['/']);
      expect(stage.redirects, isEmpty);
    });

    test('parses quoted arguments', () {
      final cmd = parseCommandLine('echo "hello world" \'single quote\'');
      final stage = cmd.statements.single.pipeline.stages.single;
      expect(stage.command, 'echo');
      expect(stage.args, ['hello world', 'single quote']);
    });

    test('preserves escaped characters', () {
      final cmd = parseCommandLine(r'echo hello\ world');
      final stage = cmd.statements.single.pipeline.stages.single;
      expect(stage.args, ['hello world']);
    });

    test('keeps backslash-n literal inside double quotes', () {
      final cmd = parseCommandLine(r'printf "b\na\nc\n"');
      final stage = cmd.statements.single.pipeline.stages.single;
      expect(stage.args, [r'b\na\nc\n']);
    });

    test('escapes quotes and backslashes inside double quotes', () {
      final cmd = parseCommandLine(r'echo "say \"hi\" and \\ backslash"');
      final stage = cmd.statements.single.pipeline.stages.single;
      expect(stage.args, ['say "hi" and \\ backslash']);
    });

    test('parses a pipeline', () {
      final cmd = parseCommandLine('cat /data | sort | head -5');
      final stages = cmd.statements.single.pipeline.stages;
      expect(stages.length, 3);
      expect(stages[0].command, 'cat');
      expect(stages[1].command, 'sort');
      expect(stages[2].command, 'head');
      expect(stages[2].args, ['-5']);
    });

    test('parses logical operators and semicolons', () {
      final cmd = parseCommandLine('a; b \u0026\u0026 c || d');
      expect(cmd.statements.length, 4);
      expect(cmd.statements[0].operator, StatementOperator.none);
      expect(cmd.statements[1].operator, StatementOperator.and);
      expect(cmd.statements[2].operator, StatementOperator.or);
      expect(cmd.statements[3].operator, StatementOperator.none);
    });

    test('parses output redirects', () {
      final cmd = parseCommandLine('echo hi > /tmp/out');
      final stage = cmd.statements.single.pipeline.stages.single;
      expect(stage.redirects.length, 1);
      expect(stage.redirects.single.kind, RedirectKind.write);
      expect(stage.redirects.single.fd, 1);
      expect(stage.redirects.single.target, '/tmp/out');
    });

    test('parses append and stderr redirects', () {
      final cmd = parseCommandLine('echo hi >> /tmp/out 2> /tmp/err');
      final stage = cmd.statements.single.pipeline.stages.single;
      expect(stage.redirects.length, 2);
      expect(stage.redirects[0].kind, RedirectKind.append);
      expect(stage.redirects[0].fd, 1);
      expect(stage.redirects[1].kind, RedirectKind.write);
      expect(stage.redirects[1].fd, 2);
    });

    test('parses combined redirect', () {
      final cmd = parseCommandLine('echo hi &> /tmp/all');
      final stage = cmd.statements.single.pipeline.stages.single;
      expect(stage.redirects.single.fd, -1);
      expect(stage.redirects.single.target, '/tmp/all');
    });

    test('parses input redirect', () {
      final cmd = parseCommandLine('sort < /tmp/in');
      final stage = cmd.statements.single.pipeline.stages.single;
      expect(stage.redirects.single.kind, RedirectKind.read);
      expect(stage.redirects.single.fd, 0);
      expect(stage.redirects.single.target, '/tmp/in');
    });

    test('rejects empty input', () {
      expect(() => parseCommandLine(''), throwsA(isA<ShellParseException>()));
      expect(
        () => parseCommandLine('   '),
        throwsA(isA<ShellParseException>()),
      );
    });

    test('rejects unmatched quote', () {
      expect(
        () => parseCommandLine('echo "hi'),
        throwsA(isA<ShellParseException>()),
      );
    });
  });
}
