import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/tool_row_content.dart';
import 'package:flutter_agent_harness/src/cli/tui_chrome.dart'
    show paintDiffstat;
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

/// Visible-cell width of a possibly styled row (the renderer's measure).
int cells(String row) =>
    tuiTextWidth(row.replaceAll(AnsiMarkdown.ansiSgrPattern, ''));

void main() {
  group('UT-diffstat (gh-1933 AC2)', () {
    test('add-only change counts added lines, removes none', () {
      final stat = diffStatLines('a\nb\n', 'a\nb\nc');
      expect(stat.added, 1);
      expect(stat.removed, 0);
      expect(stat.label, '+1 −0');
    });

    test('delete-only change counts removed lines, adds none', () {
      final stat = diffStatLines('a\nb\nc\n', 'a\n');
      expect(stat.added, 0);
      expect(stat.removed, 2);
      expect(stat.label, '+0 −2');
    });

    test('mixed change counts both directions', () {
      final stat = diffStatLines('a\nb\nc\n', 'a\nx\nc\n');
      expect(stat.added, 1);
      expect(stat.removed, 1);
      expect(stat.label, '+1 −1');
    });

    test('identical text yields an empty stat with no label', () {
      final stat = diffStatLines('a\nb\n', 'a\nb\n');
      expect(stat.isEmpty, isTrue);
      expect(stat.label, '');
      // A trailing newline is not a line change.
      expect(diffStatLines('a\nb', 'a\nb\n').isEmpty, isTrue);
    });

    test('reordered identical lines are a no-op (multiset accounting)', () {
      expect(diffStatLines('a\nb\nc\n', 'c\na\nb\n').isEmpty, isTrue);
    });

    test('duplicate lines are counted per occurrence', () {
      final stat = diffStatLines('a\n', 'a\na\na\n');
      expect(stat.added, 2);
      expect(stat.removed, 0);
    });

    test('exact-match edit args derive the stat from oldText/newText', () {
      final stat = diffStatFromEditArgs({
        'path': 'a.yml',
        'oldText': 'x: 1\ny: 2',
        'newText': 'x: 1\ny: 3\nz: 4',
      });
      expect(stat, isNotNull);
      expect(stat!.added, 2);
      expect(stat.removed, 1);
    });

    test('hashline patch args derive lines touched from the parsed edits', () {
      const patch = '[a.yml#AB12]\nSWAP 1.=1:\n+replaced line\nDEL 3\n';
      final stat = diffStatFromEditArgs({'patch': patch});
      expect(stat, isNotNull);
      expect(stat!.added, 1, reason: 'one `+` payload row');
      expect(stat.removed, 2, reason: 'SWAP range line 1 + DEL line 3');
    });

    test('non-editable args (no oldText/newText/patch) derive nothing', () {
      expect(diffStatFromEditArgs({'path': 'a.yml'}), isNull);
      expect(diffStatFromEditArgs({'path': 'a.yml', 'content': 'x'}), isNull);
    });
  });

  group('UT-read-selector (gh-1933 AC1)', () {
    test('no selector renders the bare brief path', () {
      expect(
        readRowSelector('lib/src/cli/tool_rows.dart'),
        'lib/src/cli/tool_rows.dart',
      );
    });

    test('offset/limit args render the legacy :A-B shape', () {
      expect(
        readRowSelector('lib/a.dart', offset: 50, limit: 150),
        'lib/a.dart:50-150',
      );
      // Open-ended start (offset only).
      expect(readRowSelector('lib/a.dart', offset: 90), 'lib/a.dart:90-');
    });

    test('trailing :N selector renders compactly', () {
      expect(readRowSelector('sm.yml:90'), 'sm.yml:90-');
    });

    test('trailing :A-B selector renders compactly', () {
      expect(readRowSelector('sm.yml:90-140'), 'sm.yml:90-140');
      // `..` is the forgiving alias — normalized to `-`.
      expect(readRowSelector('sm.yml:90..140'), 'sm.yml:90-140');
    });

    test(':A+C selector normalizes to the inclusive :A-B shape', () {
      expect(readRowSelector('sm.yml:50+20'), 'sm.yml:50-69');
    });

    test('multi-range selectors render comma-joined, merged order', () {
      expect(readRowSelector('f.txt:5-16,960-973'), 'f.txt:5-16,960-973');
    });

    test(':raw renders the raw token; a compound keeps both chunks', () {
      expect(readRowSelector('f.txt:raw'), 'f.txt:raw');
      expect(readRowSelector('f.txt:50-100:raw'), 'f.txt:50-100:raw');
    });

    test('archive and sqlite colon syntax stays part of the path', () {
      expect(readRowSelector('a.zip:inner/file.txt'), 'a.zip:inner/file.txt');
      expect(readRowSelector('data.db:table'), 'data.db:table');
      expect(
        readRowSelector('data.db:table?limit=20&offset=40'),
        'data.db:table?limit=20&offset=40',
      );
    });
  });

  group('UT-read-outcome (gh-1933 AC1)', () {
    test('a plain result counts its lines', () {
      expect(readOutcomeMeta('a\nb\nc'), '3 lines read');
      expect(readOutcomeMeta('only one'), '1 line read');
    });

    test('a truncated read reports shown-of-total from the notice', () {
      const text = 'l1\nl2\n\n[Showing lines 1-2 of 200. '
          'Use offset=3 to continue.]';
      expect(readOutcomeMeta(text), '2 of 200 lines read');
    });

    test('an empty result contributes no count fragment', () {
      expect(readOutcomeMeta(''), isNull);
      expect(readOutcomeMeta('   \n  '), isNull);
    });
  });

  group('UT-bash-row (gh-1933 AC3)', () {
    test('the intent label is the collapsed command when it is short', () {
      expect(bashIntentLabel('git status'), 'git status');
      expect(bashIntentLabel('cd /work/repo && flutter test'), 'flutter test');
    });

    test('a long command truncates the label to its first words', () {
      const command =
          'flutter test test/cli/tool_rows_test.dart '
          '--plain-name "golden transcript" --coverage';
      final label = bashIntentLabel(command);
      expect(label, startsWith('flutter test test/cli'));
      expect(label, endsWith('…'));
      expect(label.length, lessThan(command.length));
    });

    test('a heredoc command previews its first line only', () {
      final label = bashIntentLabel('cat <<EOF\nbody line\nEOF');
      expect(label, contains('cat <<EOF…'));
      expect(label, isNot(contains('body line')));
    });

    test('the output-lines count pluralizes and detects empties', () {
      expect(bashOutputMeta('a\nb\nc\nd'), '4 lines');
      expect(bashOutputMeta('single'), '1 line');
      expect(bashOutputMeta(''), isNull);
    });
  });

  group('UT-thinking-row (gh-1933 AC4)', () {
    test('the collapsed row carries the streamed seconds', () {
      expect(thinkingRowLabel(19), 'Thought for 19s');
      expect(thinkingRowLabel(0), 'Thought for 0s');
      // Replay has no duration on the record — the honest lossy bit.
      expect(thinkingRowLabel(null), 'Thought for —');
    });

    test('collapsed rendering is one row; expanded appends the text', () {
      final collapsed = thinkingCollapsedRows(
        text: 'step one\nstep two',
        seconds: 7,
      );
      expect(collapsed, hasLength(1));
      expect(collapsed.single, '> Thought for 7s');

      final expanded = thinkingCollapsedRows(
        text: 'step one\nstep two',
        seconds: 7,
        expanded: true,
      );
      expect(expanded.first, '> Thought for 7s');
      expect(expanded.skip(1), ['step one', 'step two']);
    });
  });

  group('UT-content-contract (gh-1933 capability table)', () {
    List<ContentBlock> text(String s) => [TextContent(text: s)];

    test('read: path + selector detail, lines-read meta', () {
      final c = toolRowContent(
        'read',
        {'path': 'sm.yml:90-140'},
        resultContent: text('a\nb'),
      );
      expect(c.detail, 'sm.yml:90-140');
      expect(c.meta, contains('2 lines read'));
      expect(c.diffstat, isNull);
      expect(c.preview, isEmpty);
    });

    test('edit: path detail + diffstat fragment; write: path + +N', () {
      final edit = toolRowContent(
        'edit',
        {'path': 'a.yml', 'oldText': 'x: 1', 'newText': 'x: 2\ny: 3'},
      );
      expect(edit.detail, 'a.yml');
      expect(edit.diffstat, '+2 −1');

      final write = toolRowContent(
        'write',
        {'path': 'notes.txt', 'content': 'one\ntwo\nthree'},
      );
      expect(write.detail, 'notes.txt');
      expect(write.diffstat, '+3 −0');
    });

    test('bash: intent detail + lines meta + dim command preview', () {
      final c = toolRowContent(
        'bash',
        {'command': 'cd /w && dart analyze && dart test'},
        resultContent: text('out1\nout2\nout3'),
      );
      expect(c.detail, 'dart analyze && dart test');
      expect(c.meta, contains('3 lines'));
      expect(c.preview, hasLength(1));
      expect(c.preview.single, 'dart analyze && dart test');
    });

    test('task rows name the child and the transition', () {
      final spawn = toolRowContent('task', {
        'tasks': [
          {
            'name': 'explorer',
            'task': 'find every caller of layoutToolRow and list them',
          },
        ],
      });
      expect(spawn.detail, contains('explorer'));
      final send = toolRowContent(
        'task_send',
        {'id': 'explorer', 'message': 'also check the tests'},
      );
      expect(send.detail, contains('explorer'));
      final resume = toolRowContent('task_resume', {'id': 'explorer'});
      expect(resume.detail, contains('explorer'));
    });

    test('checkpoint/rewind rows carry the span summary', () {
      final cp = toolRowContent('checkpoint', {'goal': 'explore the parser'});
      expect(cp.detail, contains('explore the parser'));
      final rw = toolRowContent('rewind', {});
      expect(rw.detail, isNotEmpty);
    });

    test('request_secret names the credential', () {
      final c = toolRowContent(
        'request_secret',
        {'name': 'GITHUB_TOKEN'},
        resultContent: text('saved'),
      );
      expect(c.detail, contains('GITHUB_TOKEN'));
    });

    test('ask keeps the question-text contract (#366)', () {
      final c = toolRowContent('ask', {
        'questions': [
          {'question': 'Ship now or later?'},
        ],
      });
      expect(c.detail, 'Ship now or later?');
    });

    test('unknown tools degrade to their first string argument', () {
      final c = toolRowContent(
        'mcp__fs__stat',
        {'path': '/tmp/x'},
        resultContent: const [],
      );
      expect(c.detail, '/tmp/x');
      expect(c.meta, isEmpty);
    });

    test('an error result leads with the failure line, no counts', () {
      final c = toolRowContent(
        'bash',
        {'command': 'cargo test'},
        resultContent: text('Command exited with code 1\n--- partial ---'),
        isError: true,
      );
      expect(c.detail, 'Command exited with code 1');
      expect(c.meta, isEmpty);
      expect(c.diffstat, isNull);
    });

    test('AC5: the derivation is pure — persisted record material is '
        'never mutated (rendering-only)', () {
      final args = <String, dynamic>{
        'path': 'a.yml',
        'oldText': 'x: 1',
        'newText': 'x: 2',
      };
      final resultContent = [TextContent(text: 'out')];
      final argsSnapshot = Map.of(args);
      final resultSnapshot = List.of(resultContent);
      settledCallCardRows(
        toolName: 'edit',
        args: args,
        resultContent: resultContent,
        isError: false,
        width: 80,
        elapsed: '1s',
      );
      expect(args, argsSnapshot);
      expect(resultContent, resultSnapshot);
    });
  });

  group('UT-width (gh-1933 AC6)', () {
    test('right-aligned elapsed never wraps and ends at the edge', () {
      final card = settledBashCardRows(
        intent: 'dart analyze && dart test',
        commandPreview: 'dart analyze && dart test',
        outputMeta: '3 lines',
        elapsed: '12s',
        width: 40,
      );
      final header = card.first;
      expect(cells(header), lessThanOrEqualTo(40));
      expect(header, contains('12s'));
      // Preview survives as its own row, inside the budget.
      expect(card, hasLength(2));
      expect(cells(card[1]), lessThanOrEqualTo(40));
    });

    test('at a degenerate width the elapsed drops rather than wrapping', () {
      final card = settledBashCardRows(
        intent: 'a long intent label that cannot fit anywhere',
        commandPreview: 'a long intent label that cannot fit anywhere',
        outputMeta: '3 lines',
        elapsed: '120s',
        width: 12,
      );
      final header = card.first;
      expect(cells(header), lessThanOrEqualTo(12));
      expect(header.contains('\n'), isFalse);
    });
  });

  group('UT-theme (gh-1933 AC7)', () {
    test('diffstat/dim-preview/right-zone roles exist in every shipped '
        'theme', () {
      for (final entry in kBuiltInTuiThemes.entries) {
        final t = entry.value;
        expect(
          t.toolDiffAdded.foregroundRgb,
          isNotNull,
          reason: '${entry.key}: toolDiffAdded',
        );
        expect(
          t.toolDiffRemoved.foregroundRgb,
          isNotNull,
          reason: '${entry.key}: toolDiffRemoved',
        );
        expect(
          t.toolOutput.foregroundRgb,
          isNotNull,
          reason: '${entry.key}: toolOutput (dim preview)',
        );
        // The right-zone role exists everywhere; the default palette
        // renders it dim-only by design (its muted carries no fg).
        expect(
          t.muted.isDim == true || t.muted.foregroundRgb != null,
          isTrue,
          reason: '${entry.key}: muted (right-zone elapsed)',
        );
      }
    });

    test('the diffstat paints through the theme roles, never raw SGR', () {
      FaThemeController.instance.switchTo('ohmypi-dark');
      final c = FaThemeController.instance;
      final painted = paintDiffstat('+2 −1');
      expect(painted, contains(c.toolDiffAdded('+2')));
      expect(painted, contains(c.toolDiffRemoved(' −1')));
      FaThemeController.instance.reset();
    });
  });
}
