import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:flutter_agent_harness/src/tools/ask_tool.dart';
import 'package:test/test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Ask prompt — single-select
  // ---------------------------------------------------------------------------
  group('Ask prompt — single-select', () {
    final spec = AskPromptSpec(
      header: 'Ask',
      question: 'Which color?',
      index: 0,
      total: 2,
      options: [
        AskOption(label: 'Red', description: 'The warm one'),
        AskOption(label: 'Blue', description: 'The cool one'),
        AskOption(label: 'Green'),
      ],
      recommended: 1,
    );

    test('initial state has singleSelect mode and cursor at 0', () {
      final state = TuiPromptState(spec);
      expect(state.askMode, AskInputMode.singleSelect);
      expect(state.askCursor, 0);
      expect(state.askSelected, isEmpty);
      expect(state.hasOptions, isTrue);
    });

    test('PromptArrowDown moves cursor (clamped to last option)', () {
      var state = TuiPromptState(spec);
      // Move from 0 to 1
      var result = handleTuiPromptKey(state, const PromptArrowDown());
      expect(result.resolved, isNull);
      expect(result.state.askCursor, 1);
      // Move from 1 to 2
      result = handleTuiPromptKey(result.state, const PromptArrowDown());
      expect(result.state.askCursor, 2);
      // Clamped at 2 (options.length - 1)
      result = handleTuiPromptKey(result.state, const PromptArrowDown());
      expect(result.state.askCursor, 2);
    });

    test('PromptArrowUp moves cursor (clamped at 0)', () {
      var state = TuiPromptState(spec).copyWith(askCursor: 1);
      var result = handleTuiPromptKey(state, const PromptArrowUp());
      expect(result.resolved, isNull);
      expect(result.state.askCursor, 0);
      // Clamped at 0
      result = handleTuiPromptKey(result.state, const PromptArrowUp());
      expect(result.state.askCursor, 0);
    });

    test('PromptEnter selects the option at cursor and resolves', () {
      final state = TuiPromptState(spec).copyWith(askCursor: 1);
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(result.resolved, isA<AskPromptAnswer>());
      final answer = result.resolved as AskPromptAnswer;
      expect(answer.value.selected, ['Blue']);
      expect(answer.value.freeText, isNull);
    });

    test('digit char selects option (1-indexed)', () {
      final state = TuiPromptState(spec);
      // Pressing '2' selects option index 1 (Blue)
      final result = handleTuiPromptKey(state, PromptChar('2'));
      expect(result.resolved, isA<AskPromptAnswer>());
      final answer = result.resolved as AskPromptAnswer;
      expect(answer.value.selected, ['Blue']);
    });

    test('digit 1 selects the first option', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar('1'));
      final answer = result.resolved as AskPromptAnswer;
      expect(answer.value.selected, ['Red']);
    });

    test('out-of-range digit does nothing', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar('9'));
      expect(result.resolved, isNull);
      expect(result.state.askCursor, 0);
    });

    test('PromptEscape resolves with TuiPromptCancelled', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptEscape());
      expect(result.resolved, isA<TuiPromptCancelled>());
    });

    test('space enters free-text mode', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar(' '));
      expect(result.resolved, isNull);
      expect(result.state.askMode, AskInputMode.freeText);
      expect(result.state.secretValue, '');
    });

    test('pressing a letter enters free-text mode with prepend', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar('a'));
      expect(result.state.askMode, AskInputMode.freeText);
      expect(result.state.secretValue, 'a');
    });

    test('render contains the recommended ★ marker', () {
      final state = TuiPromptState(spec);
      final rows = renderTuiPrompt(state, 60);
      // Option index 1 (Blue) is recommended, so ★ should appear
      expect(
        rows.any((r) => r.contains('★')),
        isTrue,
        reason: 'recommended option should have a ★ marker',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Ask prompt — multi-select
  // ---------------------------------------------------------------------------
  group('Ask prompt — multi-select', () {
    final spec = AskPromptSpec(
      header: 'Ask',
      question: 'Pick fruits?',
      index: 0,
      total: 1,
      options: [
        AskOption(label: 'Apple'),
        AskOption(label: 'Banana'),
        AskOption(label: 'Cherry'),
        AskOption(label: 'Date'),
      ],
      multiSelect: true,
    );

    test('initial state has multiSelect mode', () {
      final state = TuiPromptState(spec);
      expect(state.askMode, AskInputMode.multiSelect);
      expect(state.askCursor, 0);
      expect(state.askSelected, isEmpty);
    });

    test('digit chars toggle selections (1 and 3 select 0, 2)', () {
      var state = TuiPromptState(spec);
      // Press '1' → toggles index 0 (Apple) ON
      var result = handleTuiPromptKey(state, PromptChar('1'));
      expect(result.resolved, isNull);
      expect(result.state.askSelected, {0});
      // Press '3' → toggles index 2 (Cherry) ON
      result = handleTuiPromptKey(result.state, PromptChar('3'));
      expect(result.state.askSelected, {0, 2});
      // Press '1' again → toggles index 0 OFF
      result = handleTuiPromptKey(result.state, PromptChar('1'));
      expect(result.state.askSelected, {2});
    });

    test('PromptChar(d) resolves with sorted selections', () {
      var state = TuiPromptState(spec);
      // Toggle 1 and 3 (indices 0 and 2)
      state = handleTuiPromptKey(state, PromptChar('1')).state;
      state = handleTuiPromptKey(state, PromptChar('3')).state;
      // Press 'd' to done
      final result = handleTuiPromptKey(state, PromptChar('d'));
      expect(result.resolved, isA<AskPromptAnswer>());
      final answer = result.resolved as AskPromptAnswer;
      expect(answer.value.selected, ['Apple', 'Cherry']);
    });

    test('PromptChar(D) works case-insensitively', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, PromptChar('2')).state;
      state = handleTuiPromptKey(state, PromptChar('4')).state;
      final result = handleTuiPromptKey(state, PromptChar('D'));
      final answer = result.resolved as AskPromptAnswer;
      expect(answer.value.selected, ['Banana', 'Date']);
    });

    test('PromptEnter with empty selection enters free text', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(result.resolved, isNull);
      expect(result.state.askMode, AskInputMode.freeText);
      expect(result.state.secretValue, '');
    });

    test(
      'PromptEnter in free-text with empty buffer reverts to option selection',
      () {
        // First Enter with empty selection → enters free text
        var state = TuiPromptState(spec);
        state = handleTuiPromptKey(state, const PromptEnter()).state;
        expect(state.askMode, AskInputMode.freeText);
        // Second Enter with empty buffer → reverts to multi-select (not cancel)
        final result = handleTuiPromptKey(state, const PromptEnter());
        expect(result.resolved, isNull);
        expect(result.state.askMode, AskInputMode.multiSelect);
        expect(result.state.askCursor, 0);
        expect(result.state.secretValue, '');
      },
    );

    test('arrow keys navigate in multi-select', () {
      var state = TuiPromptState(spec);
      expect(state.askCursor, 0);
      state = handleTuiPromptKey(state, const PromptArrowDown()).state;
      expect(state.askCursor, 1);
      state = handleTuiPromptKey(state, const PromptArrowDown()).state;
      expect(state.askCursor, 2);
      state = handleTuiPromptKey(state, const PromptArrowUp()).state;
      expect(state.askCursor, 1);
    });

    test('PromptEscape resolves with TuiPromptCancelled', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptEscape());
      expect(result.resolved, isA<TuiPromptCancelled>());
    });
  });

  // ---------------------------------------------------------------------------
  // Ask prompt — free text (empty options)
  // ---------------------------------------------------------------------------
  group('Ask prompt — free text (empty options)', () {
    final spec = AskPromptSpec(
      header: 'Ask',
      question: 'What is your favorite color?',
      index: 0,
      total: 1,
    );

    test('initial state has freeText mode when options is empty', () {
      final state = TuiPromptState(spec);
      expect(state.askMode, AskInputMode.freeText);
      expect(state.optionCount, 0);
    });

    test('typing chars appends to buffer', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, PromptChar('h')).state;
      expect(state.secretValue, 'h');
      expect(state.askCursor, 1);
      state = handleTuiPromptKey(state, PromptChar('i')).state;
      expect(state.secretValue, 'hi');
      expect(state.askCursor, 2);
    });

    test('PromptEnter resolves with typed text', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, PromptChar('h')).state;
      state = handleTuiPromptKey(state, PromptChar('i')).state;
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(result.resolved, isA<AskPromptAnswer>());
      final answer = result.resolved as AskPromptAnswer;
      expect(answer.value.selected, isEmpty);
      expect(answer.value.freeText, 'hi');
    });

    test('PromptEscape resolves with TuiPromptCancelled', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, PromptChar('h')).state;
      final result = handleTuiPromptKey(state, const PromptEscape());
      expect(result.resolved, isA<TuiPromptCancelled>());
    });

    test('empty buffer + PromptEnter resolves TuiPromptCancelled', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(result.resolved, isA<TuiPromptCancelled>());
    });

    test('exclamation mark cancels', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, PromptChar('!')).state;
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(result.resolved, isA<TuiPromptCancelled>());
    });

    test('arrow left/right moves cursor within buffer', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, PromptChar('a')).state;
      state = handleTuiPromptKey(state, PromptChar('b')).state;
      state = handleTuiPromptKey(
        state,
        PromptChar('c'),
      ).state; // buffer = 'abc', cursor = 3
      state = handleTuiPromptKey(state, const PromptArrowLeft()).state;
      expect(state.askCursor, 2);
      state = handleTuiPromptKey(state, const PromptArrowLeft()).state;
      expect(state.askCursor, 1);
      state = handleTuiPromptKey(state, const PromptArrowRight()).state;
      expect(state.askCursor, 2);
    });

    test('backspace removes char before cursor', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, PromptChar('a')).state;
      state = handleTuiPromptKey(
        state,
        PromptChar('b'),
      ).state; // 'ab', cursor 2
      state = handleTuiPromptKey(state, const PromptBackspace()).state;
      expect(state.secretValue, 'a');
      expect(state.askCursor, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Secret prompt
  // ---------------------------------------------------------------------------
  group('Secret prompt', () {
    final spec = SecretPromptSpec(name: 'FOO', reason: 'needed');

    test('initial state has spec name, empty value, and name focus', () {
      final state = TuiPromptState(spec);
      expect(state.secretName, 'FOO');
      expect(state.secretValue, '');
      expect(state.secretCursor, -1, reason: 'name focus is -1');
    });

    test('typing while in name focus appends to name', () {
      var state = TuiPromptState(spec);
      // secretCursor == -1 → name focus: typing appends to name
      state = handleTuiPromptKey(state, PromptChar('B')).state;
      expect(state.secretName, 'FOOB');
      expect(state.secretValue, '');
      state = handleTuiPromptKey(state, PromptChar('A')).state;
      state = handleTuiPromptKey(state, PromptChar('R')).state;
      expect(state.secretName, 'FOOBAR');
    });

    test('Tab moves focus from name to value field', () {
      var state = TuiPromptState(spec);
      expect(state.secretCursor, -1);
      state = handleTuiPromptKey(state, const PromptTab()).state;
      expect(state.secretCursor, 0);
      // Typing now goes to value
      state = handleTuiPromptKey(state, PromptChar('v')).state;
      expect(state.secretValue, 'v');
      expect(state.secretName, 'FOO');
    });

    test('PromptEscape resolves with TuiPromptCancelled', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptEscape());
      expect(result.resolved, isA<TuiPromptCancelled>());
    });

    test('PromptEnter with empty value does NOT submit (not submittable)', () {
      var state = TuiPromptState(spec).copyWith(secretCursor: 0);
      // Name is 'FOO' which matches the pattern, but value is empty
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(
        result.resolved,
        isNull,
        reason: 'should not submit when value is empty',
      );
    });

    test('typing targets the value field once focus is on the value '
        '(secretCursor >= 0)', () {
      // Tab to value first, then type.
      var state = TuiPromptState(
        spec,
      ).copyWith(secretName: 'MY_KEY', secretValue: 'x', secretCursor: 0);
      // Insert into value at cursor 0
      state = handleTuiPromptKey(state, PromptChar('1')).state;
      expect(state.secretValue, '1x');
      expect(state.secretCursor, 1);
      // Append at cursor 1
      state = handleTuiPromptKey(state, PromptChar('9')).state;
      expect(state.secretValue, '19x');
      expect(state.secretCursor, 2);
      // Name is untouched while in value field
      expect(state.secretName, 'MY_KEY');
    });

    test('PromptEnter submits a submittable secret', () {
      var state = TuiPromptState(SecretPromptSpec(name: 'FOO', reason: 'x'))
          .copyWith(
            secretName: 'MY_KEY',
            secretValue: 'secret',
            secretCursor: 'secret'.length,
          );
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(result.resolved, isA<SecretPromptAnswer>());
      final answer = result.resolved as SecretPromptAnswer;
      expect(answer.value.name, 'MY_KEY');
      expect(answer.value.value, 'secret');
      expect(answer.value.persisted, isFalse);
    });

    test('backspace in value removes char before cursor', () {
      var state = TuiPromptState(
        spec,
      ).copyWith(secretName: 'K', secretValue: 'abc', secretCursor: 3);
      state = handleTuiPromptKey(state, const PromptBackspace()).state;
      expect(state.secretValue, 'ab');
      expect(state.secretCursor, 2);
    });

    test('arrow keys move within value', () {
      var state = TuiPromptState(
        spec,
      ).copyWith(secretName: 'K', secretValue: 'xyz', secretCursor: 3);
      state = handleTuiPromptKey(state, const PromptArrowLeft()).state;
      expect(state.secretCursor, 2);
      state = handleTuiPromptKey(state, const PromptArrowRight()).state;
      expect(state.secretCursor, 3);
    });

    test('PromptEnter with non-matching name does not submit', () {
      // Entering a char while in name-focus keeps name non-submittable
      // if the result doesn't match the UPPER_SNAKE pattern
      // secretName starts as 'FOO' which matches, so we need a non-matching name
      // Set secretValue non-empty via copyWith but keep a non-matching name
      final nonMatch = TuiPromptState(
        SecretPromptSpec(name: 'foo', reason: 'test'),
      );
      // foo doesn't match pattern, Enter does nothing
      final result = handleTuiPromptKey(nonMatch, const PromptEnter());
      expect(result.resolved, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Approval prompt
  // ---------------------------------------------------------------------------
  group('Approval prompt', () {
    final spec = ApprovalPromptSpec(
      request: ApprovalRequest(
        toolName: 'bash',
        tier: ApprovalTier.exec,
        arguments: {'command': 'rm -rf /'},
        reason: 'critical',
      ),
    );

    test('PromptChar(y) resolves approveOnce', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar('y'));
      expect(result.resolved, isA<ApprovalPromptAnswer>());
      expect(
        (result.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.approveOnce,
      );
    });

    test('PromptChar(Y) is case-insensitive', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar('Y'));
      expect(result.resolved, isA<ApprovalPromptAnswer>());
      expect(
        (result.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.approveOnce,
      );
    });

    test('PromptChar(a) resolves approveAlways', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar('a'));
      expect(result.resolved, isA<ApprovalPromptAnswer>());
      expect(
        (result.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.approveAlways,
      );
    });

    test('PromptChar(n) resolves deny', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar('n'));
      expect(result.resolved, isA<ApprovalPromptAnswer>());
      expect(
        (result.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.deny,
      );
    });

    test('PromptEnter resolves deny', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(result.resolved, isA<ApprovalPromptAnswer>());
      expect(
        (result.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.deny,
      );
    });

    test('PromptEscape resolves deny', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptEscape());
      expect(result.resolved, isA<ApprovalPromptAnswer>());
      expect(
        (result.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.deny,
      );
    });

    test('other chars do nothing', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar('x'));
      expect(result.resolved, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------
  group('Rendering', () {
    test('bordered frame characters for ask prompt (single-select)', () {
      final spec = AskPromptSpec(
        header: 'Ask',
        question: 'Test?',
        index: 0,
        total: 1,
        options: [
          AskOption(label: 'Yes'),
          AskOption(label: 'No'),
        ],
      );
      final state = TuiPromptState(spec);
      final rows = renderTuiPrompt(state, 60);
      expect(rows, isNotEmpty);
      expect(rows.first.startsWith('┌'), isTrue);
      for (final row in rows) {
        expect(
          row.startsWith('┌') ||
              row.startsWith('│') ||
              row.startsWith('├') ||
              row.startsWith('└'),
          isTrue,
          reason: 'each row must be a frame row',
        );
      }
      expect(rows.last.startsWith('└'), isTrue);
    });

    test('row count matches tuiPromptRowCount', () {
      final spec = AskPromptSpec(
        header: 'Ask',
        question: 'Test?',
        index: 0,
        total: 1,
        options: [
          AskOption(label: 'Yes', description: 'Agree'),
          AskOption(label: 'No'),
        ],
      );
      final state = TuiPromptState(spec);
      final rows = renderTuiPrompt(state, 60);
      expect(rows.length, tuiPromptRowCount(state, 60));
    });

    test('first row contains the header text for ask', () {
      final state = TuiPromptState(
        AskPromptSpec(header: 'Ask', question: 'Q?', index: 0, total: 1),
      );
      final rows = renderTuiPrompt(state, 60);
      expect(rows.first.contains('Ask'), isTrue);
    });

    test('first row contains the header text for secret', () {
      final state = TuiPromptState(
        SecretPromptSpec(name: 'KEY', reason: 'need it'),
      );
      final rows = renderTuiPrompt(state, 60);
      expect(rows.first.contains('Secret'), isTrue);
    });

    test('first row contains the header text for approval', () {
      final state = TuiPromptState(
        ApprovalPromptSpec(
          request: ApprovalRequest(
            toolName: 'ls',
            tier: ApprovalTier.read,
            arguments: {},
            reason: 'just checking',
          ),
        ),
      );
      final rows = renderTuiPrompt(state, 60);
      expect(rows.first.contains('Approval'), isTrue);
    });

    test('rendered ask options contain each option label', () {
      final spec = AskPromptSpec(
        header: 'Ask',
        question: 'Pick one?',
        index: 0,
        total: 1,
        options: [
          AskOption(label: 'Alpha'),
          AskOption(label: 'Beta'),
          AskOption(label: 'Gamma'),
        ],
      );
      final state = TuiPromptState(spec);
      final rows = renderTuiPrompt(state, 60);
      final joined = rows.join('\n');
      expect(joined, contains('Alpha'));
      expect(joined, contains('Beta'));
      expect(joined, contains('Gamma'));
    });

    test('rendered approval contains tool name and tier', () {
      final state = TuiPromptState(
        ApprovalPromptSpec(
          request: ApprovalRequest(
            toolName: 'write_file',
            tier: ApprovalTier.write,
            arguments: {'path': '/tmp/x'},
            reason: 'writes a file',
          ),
        ),
      );
      final rows = renderTuiPrompt(state, 60);
      final joined = rows.join('\n');
      expect(joined, contains('write_file'));
      expect(joined, contains('write'));
    });

    test('rendered secret contains the credential name', () {
      final state = TuiPromptState(
        SecretPromptSpec(name: 'GITHUB_TOKEN', reason: 'API access'),
      );
      final rows = renderTuiPrompt(state, 60);
      final joined = rows.join('\n');
      expect(joined, contains('GITHUB_TOKEN'));
    });

    test('bordered frame chars for approval prompt', () {
      final state = TuiPromptState(
        ApprovalPromptSpec(
          request: ApprovalRequest(
            toolName: 'bash',
            tier: ApprovalTier.exec,
            arguments: {},
            reason: 'test',
          ),
        ),
      );
      final rows = renderTuiPrompt(state, 60);
      expect(rows.first.startsWith('┌'), isTrue);
      expect(rows.last.startsWith('└'), isTrue);
      expect(rows.any((r) => r.startsWith('├')), isTrue);
    });

    test('row count matches for approval', () {
      final state = TuiPromptState(
        ApprovalPromptSpec(
          request: ApprovalRequest(
            toolName: 'bash',
            tier: ApprovalTier.exec,
            arguments: {},
            reason: 'test',
          ),
        ),
      );
      final rows = renderTuiPrompt(state, 60);
      expect(rows.length, tuiPromptRowCount(state, 60));
    });

    test('row count matches for secret', () {
      final state = TuiPromptState(
        SecretPromptSpec(name: 'K', reason: 'need it'),
      );
      final rows = renderTuiPrompt(state, 60);
      expect(rows.length, tuiPromptRowCount(state, 60));
    });
  });

  // ---------------------------------------------------------------------------
  // TuiPromptState convenience getters
  // ---------------------------------------------------------------------------
  group('TuiPromptState getters', () {
    test('askSpec returns the spec cast to AskPromptSpec', () {
      final spec = AskPromptSpec(
        header: 'Ask',
        question: 'Q?',
        index: 0,
        total: 1,
      );
      final state = TuiPromptState(spec);
      expect(state.askSpec, same(spec));
    });

    test('secretSpec returns the spec cast to SecretPromptSpec', () {
      final spec = SecretPromptSpec(name: 'K', reason: 'r');
      final state = TuiPromptState(spec);
      expect(state.secretSpec, same(spec));
    });

    test('approvalSpec returns the spec cast to ApprovalPromptSpec', () {
      final spec = ApprovalPromptSpec(
        request: ApprovalRequest(
          toolName: 't',
          tier: ApprovalTier.read,
          arguments: {},
          reason: 'r',
        ),
      );
      final state = TuiPromptState(spec);
      expect(state.approvalSpec, same(spec));
    });
  });

  // ---------------------------------------------------------------------------
  // Edge cases
  // ---------------------------------------------------------------------------
  group('Edge cases', () {
    test('non-printable keys return (state, null) for ask free text', () {
      final state = TuiPromptState(
        AskPromptSpec(header: 'Ask', question: 'Q?', index: 0, total: 1),
      );
      // tab in free text does nothing
      var result = handleTuiPromptKey(state, const PromptTab());
      expect(result.resolved, isNull);
      // arrow up/down in free text does nothing
      result = handleTuiPromptKey(state, const PromptArrowUp());
      expect(result.resolved, isNull);
      result = handleTuiPromptKey(state, const PromptArrowDown());
      expect(result.resolved, isNull);
    });

    test('PromptTab in single-select resolves with cursor option', () {
      final spec = AskPromptSpec(
        header: 'Ask',
        question: 'Q?',
        index: 0,
        total: 1,
        options: [
          AskOption(label: 'First'),
          AskOption(label: 'Second'),
        ],
      );
      var state = TuiPromptState(spec).copyWith(askCursor: 1);
      final result = handleTuiPromptKey(state, const PromptTab());
      expect(result.resolved, isA<AskPromptAnswer>());
      expect((result.resolved as AskPromptAnswer).value.selected, ['Second']);
    });

    test('PromptTab in multi-select enters free text', () {
      final spec = AskPromptSpec(
        header: 'Ask',
        question: 'Q?',
        index: 0,
        total: 1,
        options: [
          AskOption(label: 'A'),
          AskOption(label: 'B'),
        ],
        multiSelect: true,
      );
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptTab());
      expect(result.resolved, isNull);
      expect(result.state.askMode, AskInputMode.freeText);
    });

    test('width clamping to 20 minimum', () {
      final state = TuiPromptState(
        AskPromptSpec(header: 'Ask', question: 'Q?', index: 0, total: 1),
      );
      // At width 5 (clamped to 20), rendering still produces a valid frame
      final rows = renderTuiPrompt(state, 5);
      expect(rows, isNotEmpty);
      expect(rows.first.startsWith('┌'), isTrue);
    });
  });

  group('Paste into prompts', () {
    test('PromptPaste inserts the whole clipboard at the cursor', () {
      final spec = TextPromptSpec(question: 'DIAL API key: ', secret: true);
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, const PromptPaste('sk-dial-123')).state;
      expect(state.secretValue, 'sk-dial-123');
      expect(state.secretCursor, 'sk-dial-123'.length);
      // Enter resolves the answer with the pasted value.
      final done = handleTuiPromptKey(state, const PromptEnter());
      expect(done.resolved, isA<TextPromptAnswer>());
      expect((done.resolved as TextPromptAnswer).value, 'sk-dial-123');
    });

    test('PromptPaste between typed characters', () {
      final spec = TextPromptSpec(question: 'base URL: ');
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, const PromptChar('a')).state;
      state = handleTuiPromptKey(state, const PromptChar('c')).state;
      state = handleTuiPromptKey(state, const PromptArrowLeft()).state;
      state = handleTuiPromptKey(state, const PromptPaste('b')).state;
      expect(state.secretValue, 'abc');
      expect(state.secretCursor, 2);
    });

    test('PromptPaste into ask free text', () {
      final spec = AskPromptSpec(
        header: 'Ask',
        question: 'Q?',
        index: 0,
        total: 1,
        options: [AskOption(label: 'A')],
        multiSelect: true,
      );
      // Tab toggles to free text but the spec still HAS options — paste
      // reaches the free-text buffer only in free-text mode.
      var state = handleTuiPromptKey(
        TuiPromptState(spec),
        const PromptTab(),
      ).state;
      expect(state.askMode, AskInputMode.freeText);
      state = handleTuiPromptKey(state, const PromptPaste('hello')).state;
      expect(state.secretValue, 'hello');
      expect(state.askCursor, 'hello'.length);
    });
  });
}
