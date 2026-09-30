// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Heredoc / here-string support in the sandbox shell (gh-1086): parser
/// level — body capture, delimiter variants, error cases. Execution-level
/// coverage lives in `sandbox_heredoc_test.dart`.
library;

import 'package:fa/sandbox/shell_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('heredoc parsing (gh-1086)', () {
    Redirect heredocOf(String input) {
      final script = parseShellScript(input);
      final node = script.nodes.single as ScriptPipeline;
      final stage = node.pipeline.stages.single;
      return stage.redirects.single;
    }

    test('captures a single-line body verbatim', () {
      final r = heredocOf('cat <<EOF\nhello\nEOF');
      expect(r.kind, RedirectKind.heredoc);
      expect(r.fd, 0);
      expect(r.target, 'EOF');
      expect(r.body, 'hello\n');
    });

    test('captures a multi-line body verbatim, including blanks', () {
      final r = heredocOf('cat <<EOF\nline one\n\n  indented  \nEOF');
      expect(r.body, 'line one\n\n  indented  \n');
    });

    test('an empty body (delimiter on the next line) parses as empty', () {
      final r = heredocOf('cat <<EOF\nEOF');
      expect(r.body, '');
    });

    test('<<- strips leading tabs from body and delimiter lines', () {
      final r = heredocOf('cat <<-EOF\n\t\tbody\n\t\tEOF');
      expect(r.body, 'body\n');
    });

    test('a single-quoted delimiter disables body expansion', () {
      final r = heredocOf("cat <<'EOF'\nraw \$VAR\nEOF");
      expect(r.expandable, isFalse);
      expect(r.body, 'raw \$VAR\n');
    });

    test('a double-quoted delimiter also disables body expansion', () {
      final r = heredocOf('cat <<"EOF"\nraw \$VAR\nEOF');
      expect(r.expandable, isFalse);
    });

    test('an unquoted delimiter keeps the body expandable', () {
      final r = heredocOf('cat <<EOF\nexpand \$VAR\nEOF');
      expect(r.expandable, isTrue);
    });

    test('unterminated heredoc names the delimiter', () {
      expect(
        () => parseShellScript('cat <<MYSTOP\nnever closed\n'),
        throwsA(
          isA<ShellParseException>().having(
            (e) => e.message,
            'message',
            contains('MYSTOP'),
          ),
        ),
      );
    });

    test('heredoc at end of input without a body line is unterminated', () {
      expect(
        () => parseShellScript('cat <<EOF'),
        throwsA(isA<ShellParseException>()),
      );
    });

    test('heredoc feeds a pipeline stage, later stages parse normally', () {
      final script = parseShellScript('cat <<EOF | grep x\nax\nbx\nEOF');
      final node = script.nodes.single as ScriptPipeline;
      expect(node.pipeline.stages, hasLength(2));
      expect(node.pipeline.stages[0].redirects.single.body, 'ax\nbx\n');
      expect(node.pipeline.stages[1].command, 'grep');
    });

    test('heredoc composes with an output redirect', () {
      final script = parseShellScript('cat <<EOF > /tmp/f.txt\nbody\nEOF');
      final stage =
          (script.nodes.single as ScriptPipeline).pipeline.stages.single;
      expect(stage.redirects, hasLength(2));
      expect(stage.redirects[0].kind, RedirectKind.heredoc);
      expect(stage.redirects[1].kind, RedirectKind.write);
      expect(stage.redirects[1].target, '/tmp/f.txt');
    });

    test('two heredocs on one command line capture bodies in order', () {
      final script = parseShellScript('cat <<A; cat <<B\nfirst\nA\nsecond\nB');
      final stages = [
        for (final n in script.nodes)
          (n as ScriptPipeline).pipeline.stages.single,
      ];
      expect(stages[0].redirects.single.body, 'first\n');
      expect(stages[1].redirects.single.body, 'second\n');
    });

    test('a statement after the heredoc line parses after the body', () {
      final script = parseShellScript('cat <<EOF\nbody\nEOF\necho done');
      expect(script.nodes, hasLength(2));
      expect(
        (script.nodes[1] as ScriptPipeline).pipeline.stages.single.command,
        'echo',
      );
    });

    test('heredoc inside an if body', () {
      final script = parseShellScript('if true; then cat <<EOF\nbody\nEOF\nfi');
      final ifNode = script.nodes.single as ScriptIf;
      final body = ifNode.branches.single.body.single as ScriptPipeline;
      expect(body.pipeline.stages.single.redirects.single.body, 'body\n');
    });

    test('heredoc inside a for body', () {
      final script = parseShellScript(
        'for i in 1; do cat <<EOF\nbody\nEOF\ndone',
      );
      final forNode = script.nodes.single as ScriptFor;
      final body = forNode.body.single as ScriptPipeline;
      expect(body.pipeline.stages.single.redirects.single.body, 'body\n');
    });

    test('fd-prefixed heredoc binds the descriptor', () {
      final r = heredocOf('cat 3<<EOF\nbody\nEOF');
      expect(r.kind, RedirectKind.heredoc);
      expect(r.fd, 3);
    });

    test('a delimiter word missing entirely is a parse error', () {
      expect(
        () => parseShellScript('cat <<\nbody\n'),
        throwsA(isA<ShellParseException>()),
      );
    });

    test('body text equal to a prefix of the delimiter does not terminate', () {
      final r = heredocOf('cat <<EOF\nEO\nEOF');
      expect(r.body, 'EO\n');
    });
  });

  group('here-string parsing (gh-1086)', () {
    test('parses as a here-string redirect with the word as target', () {
      final script = parseShellScript('cat <<< "hi there"');
      final stage =
          (script.nodes.single as ScriptPipeline).pipeline.stages.single;
      final r = stage.redirects.single;
      expect(r.kind, RedirectKind.hereString);
      expect(r.fd, 0);
      expect(r.target, 'hi there');
    });

    test('unquoted here-string word stays expandable', () {
      final script = parseShellScript('cat <<< \$VAR');
      final stage =
          (script.nodes.single as ScriptPipeline).pipeline.stages.single;
      expect(stage.redirects.single.kind, RedirectKind.hereString);
      expect(stage.redirects.single.expandable, isTrue);
    });
  });
}
