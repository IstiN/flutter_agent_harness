// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// REG-1 battery (gh-1086 AC5): every class-B construct — silently wrong
/// before this card — must now fail LOUDLY with a named ShellParseException
/// at parse time. This table blocks merges: a construct regressing to
/// silent misexecution fails CI even when every other suite is green.
library;

import 'package:fa/sandbox/shell_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('class-B fail-fast battery (gh-1086 AC5 / REG-1)', () {
    /// command → expected message fragment.
    const battery = <String, String>{
      // Arithmetic expansion (was: `echo $((1+2))` printed `)`).
      r'echo $((1+2))': 'arithmetic expansion',
      r'echo "$((1+2))"': 'arithmetic expansion',
      // Prefix assignment (was: `VAR=42 cmd` → "VAR=42: command not found").
      'VAR=42 echo hi': 'prefix assignments',
      // Subshell (was: `(cd dir && ls)` → "(cd: command not found").
      '(cd dir && ls)': 'subshells',
      // Process substitution (was: read a file literally named `(echo`).
      'diff <(echo a) <(echo b)': 'process substitution',
      'tee >(cat)': 'process substitution',
      // fd-prefixed process substitution (was: wrote a file named `(tee`).
      'echo x 2>(tee y)': 'process substitution',
      'cat 2<(echo x)': 'process substitution',
      // fd-prefixed here-string (was: misleading heredoc + read redirect).
      'cat 3<<<word': 'fd-prefixed here-strings',
      // Heredoc on a bare assignment (was: body silently dropped).
      'X=1 <<EOF\nbody\nEOF': 'here-document/here-string on a bare assignment',
      // Same guard fires for here-strings — the named error must cover
      // both forms (gh-1086 review round 2).
      'X=1 <<<word': 'here-document/here-string on a bare assignment',
      // Unquoted globs (were: passed literally, never expanded).
      'ls *.dart': 'glob patterns',
      // Brace expansion.
      'echo {a,b}.txt': 'brace expansion',
      // Tilde expansion.
      'cd ~/proj': 'tilde expansion',
      // Background execution.
      'sleep 1 &': 'background jobs',
      // fd duplication.
      'echo x 2>&1': 'fd duplication',
      // Reserved shell constructs (were: "command not found" or a confusing
      // downstream parse error).
      'while true; do echo x; done': "'while'",
      'until false; do echo x; done': "'until'",
      'case x in esac': "'case'",
      'select x in a; do echo; done': "'select'",
      'function f { echo; }': "'function'",
    };

    for (final entry in battery.entries) {
      test('rejects `${entry.key}`', () {
        expect(
          () => parseShellScript(entry.key),
          throwsA(
            isA<ShellParseException>().having(
              (e) => e.message,
              'message',
              contains(entry.value),
            ),
          ),
        );
      });
    }
  });

  group('class-C negative controls (gh-1086 AC6)', () {
    /// Constructs that must KEEP working — quoting passes text literally.
    const working = <String>[
      // Quoted glob/brace/tilde text is literal data, not a pattern.
      "find /proj -name '*.dart'",
      'echo "a*b"',
      "echo '{a,b}'",
      "echo '~'",
      // jq empty-bracket iteration is not a glob.
      'jq .tags.[] /data.json',
      // Bracket expressions pass literally (stat format / char classes).
      'stat -c [%q-%s] f.txt',
      'ls src/[a-z].dart',
      // The test command brackets are not globs.
      '[ 1 -eq 2 ]',
      // Assignment-looking ARGUMENTS (not command position) are fine.
      'env A=1 echo x',
      'echo A=1',
      // Bare `&>` / `&>>` redirects stay supported.
      'echo x &> /tmp/f',
      // Command substitution and pipes are class-C.
      'echo \$(echo hi) | cat',
      // A bare `*` is the expr multiplication idiom (pinned exemption).
      'expr 6 * 7 > /tmp/f',
    ];

    for (final command in working) {
      test('still parses `$command`', () {
        expect(() => parseShellScript(command), returnsNormally);
      });
    }
  });
}
