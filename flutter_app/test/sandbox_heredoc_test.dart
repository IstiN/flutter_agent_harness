// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Execution-level heredoc / here-string coverage (gh-1086): stdin bodies
/// through MemoryShell — file writes, pipes, expansion semantics, redirect
/// precedence — plus the loud-failure battery for constructs that must
/// never silently misexecute.
library;

import 'package:fa/sandbox/memory_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    final shell = MemoryShell();
    env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);
  });

  Future<String> stdoutOf(String command) async {
    final result = await env.exec(command);
    expect(result.isOk, isTrue, reason: result.errorOrNull.toString());
    return result.valueOrNull!.stdout;
  }

  group('heredoc execution (gh-1086)', () {
    test('cat echoes the heredoc body', () async {
      expect(await stdoutOf('cat <<EOF\nhello\nEOF'), 'hello\n');
    });

    test('heredoc writes a file via output redirect', () async {
      await stdoutOf('cat <<EOF > /tmp/hd.txt\nline1\nline2\nEOF');
      expect(await stdoutOf('cat /tmp/hd.txt'), 'line1\nline2\n');
    });

    test('heredoc feeds a pipeline', () async {
      expect(await stdoutOf('cat <<EOF | grep b\nab\ncd\nEOF'), 'ab\n');
    });

    test('unquoted delimiter expands \$VAR in the body', () async {
      await stdoutOf('export HD_NAME=world');
      expect(
        await stdoutOf('cat <<EOF\nhello \$HD_NAME\nEOF'),
        'hello world\n',
      );
    });

    test('quoted delimiter keeps the body literal', () async {
      await stdoutOf('export HD_NAME=world');
      expect(
        await stdoutOf("cat <<'EOF'\nhello \$HD_NAME\nEOF"),
        'hello \$HD_NAME\n',
      );
    });

    test('<<- strips leading tabs', () async {
      expect(await stdoutOf('cat <<-EOF\n\t\tbody\n\t\tEOF'), 'body\n');
    });

    test(
      'a later stdin file redirect beats the heredoc (POSIX last wins)',
      () async {
        await stdoutOf('printf file-content > /tmp/hd_src.txt');
        expect(
          await stdoutOf('cat <<EOF < /tmp/hd_src.txt\nbody\nEOF'),
          'file-content',
        );
      },
    );

    test('a later heredoc beats the stdin file redirect', () async {
      await stdoutOf('printf file-content > /tmp/hd_src.txt');
      expect(
        await stdoutOf('cat < /tmp/hd_src.txt <<EOF\nbody\nEOF'),
        'body\n',
      );
    });

    test('heredoc inside an if body executes', () async {
      expect(
        await stdoutOf('if true; then cat <<EOF\nin-if\nEOF\nfi'),
        'in-if\n',
      );
    });

    test('heredoc inside a for body executes per iteration', () async {
      expect(
        await stdoutOf('for i in a b; do cat <<EOF\nitem\nEOF\ndone'),
        'item\nitem\n',
      );
    });

    test('unterminated heredoc is an exec error, not a hang', () async {
      final result = await env.exec('cat <<EOF\nnever closed\n');
      expect(result.isErr, isTrue);
      expect(result.errorOrNull.toString(), contains('EOF'));
    });
  });

  group('here-string execution (gh-1086)', () {
    test('cat reads the here-string with a trailing newline', () async {
      expect(await stdoutOf('cat <<< "hi there"'), 'hi there\n');
    });

    test('here-string expands unquoted words', () async {
      await stdoutOf('export HS=42');
      expect(await stdoutOf('cat <<< \$HS'), '42\n');
    });
  });
}
