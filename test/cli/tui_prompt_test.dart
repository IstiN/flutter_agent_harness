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

    test('render contains the recommended * marker', () {
      final state = TuiPromptState(spec);
      final rows = renderTuiPrompt(state, 60);
      // Option index 1 (Blue) is recommended, so * should appear. ASCII on
      // purpose: ★ measures 2 cells in the width table but terminals draw
      // it 1 wide, shifting every padded row (issue #109).
      expect(
        rows.any((r) => r.contains('*')),
        isTrue,
        reason: 'recommended option should have a * marker',
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

    test('initial state: value focus, suggestion is a placeholder (F1/F2)', () {
      final state = TuiPromptState(spec);
      expect(
        state.secretName,
        '',
        reason: 'the suggested name must not be committed input',
      );
      expect(state.effectiveSecretName, 'FOO');
      expect(state.secretValue, '');
      expect(
        state.secretCursor,
        0,
        reason: 'initial focus is the value field, not the name',
      );
    });

    test('the first keystroke lands in the masked value field', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, PromptChar('a')).state;
      expect(state.secretValue, 'a');
      expect(state.secretName, '');
      expect(state.secretCursor, 1);
    });

    test('a paste lands in the masked value field at the cursor', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(
        state,
        const PromptPaste('pasted-secret'),
      ).state;
      expect(state.secretValue, 'pasted-secret');
      expect(state.secretCursor, 'pasted-secret'.length);
    });

    test('Tab toggles focus; typing in name focus replaces the suggestion', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, const PromptTab()).state;
      expect(state.secretCursor, -1, reason: 'name focus');
      state = handleTuiPromptKey(state, PromptChar('M')).state;
      expect(
        state.secretName,
        'M',
        reason: 'typing replaces the suggestion wholesale (F1)',
      );
      state = handleTuiPromptKey(state, const PromptTab()).state;
      expect(state.secretCursor, 0);
      state = handleTuiPromptKey(state, PromptChar('v')).state;
      expect(state.secretValue, 'v');
      expect(state.secretName, 'M');
    });

    test('Ctrl+U on name focus restores the placeholder suggestion', () {
      var state = TuiPromptState(spec);
      state = handleTuiPromptKey(state, const PromptTab()).state;
      state = handleTuiPromptKey(state, PromptChar('X')).state;
      expect(state.secretName, 'X');
      state = handleTuiPromptKey(state, const PromptCtrlU()).state;
      expect(state.secretName, '');
      expect(state.effectiveSecretName, 'FOO');
    });

    test('Ctrl+U kills the value back to the cursor', () {
      var state = TuiPromptState(
        spec,
      ).copyWith(secretValue: 'secret', secretCursor: 6);
      state = handleTuiPromptKey(state, const PromptCtrlU()).state;
      expect(state.secretValue, '');
      expect(state.secretCursor, 0);

      state = TuiPromptState(
        spec,
      ).copyWith(secretValue: 'secret', secretCursor: 3);
      state = handleTuiPromptKey(state, const PromptCtrlU()).state;
      expect(state.secretValue, 'ret');
      expect(state.secretCursor, 0);
    });

    test('the sheet hint names the focus-switch key (F4)', () {
      final rows = renderTuiPrompt(TuiPromptState(spec), 60).join('\n');
      expect(rows, contains('>'));
    });

    test('Ctrl+R toggles the value visibility (hidden by default)', () {
      var state = TuiPromptState(spec);
      expect(state.secretValueVisible, isFalse);
      state = handleTuiPromptKey(state, const PromptCtrlR()).state;
      expect(state.secretValueVisible, isTrue);
      state = handleTuiPromptKey(state, const PromptCtrlR()).state;
      expect(state.secretValueVisible, isFalse);
    });

    test('hidden renders dots, revealed renders the typed value', () {
      var state = TuiPromptState(spec).copyWith(secretCursor: 0);
      state = handleTuiPromptKey(state, PromptChar('s')).state;
      state = handleTuiPromptKey(state, PromptChar('3')).state;
      state = handleTuiPromptKey(state, PromptChar('c')).state;

      final hidden = renderTuiPrompt(state, 60).join('\n');
      expect(hidden, contains('•••'));
      expect(hidden, isNot(contains('s3c')));
      expect(hidden, contains('Ctrl+R reveals'));

      state = handleTuiPromptKey(state, const PromptCtrlR()).state;
      final shown = renderTuiPrompt(state, 60).join('\n');
      expect(shown, contains('s3c'));
      expect(shown, contains('Ctrl+R hides'));
    });

    test('PromptEscape resolves with TuiPromptCancelled', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptEscape());
      expect(result.resolved, isA<TuiPromptCancelled>());
    });

    test('blocked Enter shows the reason, then it goes stale (F3)', () {
      var state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(
        result.resolved,
        isNull,
        reason: 'should not submit when value is empty',
      );
      expect(result.state.secretEnterError, contains('value'));
      state = handleTuiPromptKey(result.state, PromptChar('x')).state;
      expect(state.secretEnterError, '');
      expect(state.secretValue, 'x');
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

    test('Enter with an untouched name submits the suggested name', () {
      // The trapped production sequence from issue #97: open the sheet,
      // type the secret, press Enter — the suggestion is the name.
      var state = TuiPromptState(SecretPromptSpec(name: 'FOO', reason: 'x'));
      for (final char in 'secret'.runes) {
        state = handleTuiPromptKey(
          state,
          PromptChar(String.fromCharCode(char)),
        ).state;
      }
      final result = handleTuiPromptKey(state, const PromptEnter());
      final answer = result.resolved as SecretPromptAnswer;
      expect(answer.value.name, 'FOO');
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

    test('Enter with a non-matching name shows the name reason (F3)', () {
      final nonMatch = TuiPromptState(
        SecretPromptSpec(name: 'foo', reason: 'test'),
      ).copyWith(secretValue: 'x', secretCursor: 1);
      final result = handleTuiPromptKey(nonMatch, const PromptEnter());
      expect(result.resolved, isNull);
      expect(result.state.secretEnterError, contains('Name must match'));
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

    test('unrecognized char is echoed into approvalInput', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, PromptChar('x'));
      expect(result.resolved, isNull);
      expect(result.state.approvalInput, 'x');
    });

    test('backspace erases the last typed note character', () {
      var state = TuiPromptState(spec).copyWith(approvalInput: 'не');
      state = handleTuiPromptKey(state, const PromptBackspace()).state;
      expect(state.approvalInput, 'н');
      state = handleTuiPromptKey(state, const PromptBackspace()).state;
      expect(state.approvalInput, isEmpty);
      // Erasing the note re-arms the Enter-submits-decision rule.
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(
        (result.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.deny,
      );
    });

    test('backspace on an empty note is a no-op', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptBackspace());
      expect(result.resolved, isNull);
      expect(result.state.approvalInput, isEmpty);
    });

    test('ctrl+u clears the whole note (readline unix-line-discard)', () {
      var state = TuiPromptState(spec).copyWith(approvalInput: 'не делать');
      final result = handleTuiPromptKey(state, const PromptCtrlU());
      expect(
        result.resolved,
        isNull,
        reason: 'ctrl+u only clears, never submits',
      );
      state = result.state;
      expect(state.approvalInput, isEmpty);
      // And the prompt still works afterwards.
      final answer = handleTuiPromptKey(state, PromptChar('y'));
      expect(
        (answer.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.approveOnce,
      );
      expect((answer.resolved as ApprovalPromptAnswer).note, isEmpty);
    });

    test('ctrl+u on an empty note is a no-op', () {
      final state = TuiPromptState(spec);
      final result = handleTuiPromptKey(state, const PromptCtrlU());
      expect(result.resolved, isNull);
      expect(result.state.approvalInput, isEmpty);
    });

    test('PromptEnter does not resolve while approvalInput is non-empty', () {
      final state = TuiPromptState(spec).copyWith(approvalInput: 'ф');
      final result = handleTuiPromptKey(state, const PromptEnter());
      expect(result.resolved, isNull);
      expect(result.state.approvalInput, 'ф');
    });

    test('number keys 1/2/3 resolve decisions (layout-proof)', () {
      ApprovalDecision decisionOf(String key) =>
          (handleTuiPromptKey(TuiPromptState(spec), PromptChar(key)).resolved!
                  as ApprovalPromptAnswer)
              .value;
      expect(decisionOf('1'), ApprovalDecision.approveOnce);
      expect(decisionOf('2'), ApprovalDecision.approveAlways);
      expect(decisionOf('3'), ApprovalDecision.deny);
    });

    test('number keys carry the typed note and clear the buffer', () {
      final state = TuiPromptState(spec).copyWith(approvalInput: 'ф');
      final result = handleTuiPromptKey(state, const PromptChar('3'));
      expect((result.resolved as ApprovalPromptAnswer).note, 'ф');
      expect(result.state.approvalInput, '');
    });

    test('arrow keys move the selection and Enter confirms it', () {
      var result = handleTuiPromptKey(
        TuiPromptState(spec),
        const PromptArrowUp(),
      );
      expect(result.state.approvalSelected, 1);
      result = handleTuiPromptKey(result.state, const PromptArrowUp());
      expect(result.state.approvalSelected, 0);
      result = handleTuiPromptKey(result.state, const PromptEnter());
      expect(
        (result.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.approveOnce,
      );
    });

    test('selection defaults to deny and clamps at the bounds', () {
      expect(TuiPromptState(spec).approvalSelected, 2);
      var result = handleTuiPromptKey(
        TuiPromptState(spec),
        const PromptArrowDown(),
      );
      expect(result.state.approvalSelected, 2);
      result = handleTuiPromptKey(result.state, const PromptArrowUp());
      result = handleTuiPromptKey(result.state, const PromptArrowUp());
      expect(result.state.approvalSelected, 0);
    });

    test('selection rows render the numbered options', () {
      final rows = renderTuiPrompt(TuiPromptState(spec), 60).join('\n');
      expect(rows, contains('1.'));
      expect(rows, contains('Approve once'));
      expect(rows, contains('2.'));
      expect(rows, contains('Always approve'));
      expect(rows, contains('3.'));
      expect(rows, contains('Deny'));
    });

    test('recognized answer key clears a stale approvalInput buffer', () {
      final state = TuiPromptState(spec).copyWith(approvalInput: 'ф');
      final result = handleTuiPromptKey(state, PromptChar('y'));
      expect(result.resolved, isA<ApprovalPromptAnswer>());
      expect(
        (result.resolved as ApprovalPromptAnswer).value,
        ApprovalDecision.approveOnce,
      );
      expect(result.state.approvalInput, '');
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
  group('Frame width invariant (issue #109)', () {
    // Every rendered row must fit the requested width in terminal cells:
    // one over-wide row wraps in the real terminal and desyncs the diff
    // renderer — visible as torn borders and stale previous-frame text.
    String visible(String row) =>
        row.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');

    void expectRowsFit(List<String> rows, int width) {
      for (final row in rows) {
        expect(
          visible(row).length,
          lessThanOrEqualTo(width),
          reason: 'row overflows $width columns: ${visible(row)}',
        );
      }
    }

    test('exact-width wrapped body rows stay inside the frame', () {
      // A question long enough that _wrapText slices it at the full inner
      // width — the historical off-by-one (padding ' ' * -1) case.
      final spec = AskPromptSpec(
        header: 'Ask',
        question:
            'На каких поверхностях виджеты должны рендериться '
            'в первой версии продукта и почему именно так?',
        index: 1,
        total: 4,
        options: [
          const AskOption(
            label: 'Flutter app + browser extension, CLI — текстовый фолбэк',
            description:
                'Виджеты живут в чат-аппи и панели расширения; в CLI '
                'динамическое сообщение деградирует в текстовое '
                'представление (та же data-модель, плоский рендер).',
          ),
          const AskOption(label: 'Только Flutter app для начала'),
        ],
        recommended: 0,
      );
      for (final width in [40, 60, 80, 100]) {
        expectRowsFit(renderTuiPrompt(TuiPromptState(spec), width), width);
      }
    });

    test('a long single-line answer wraps into framed input rows', () {
      final spec = AskPromptSpec(
        header: 'Ask',
        question: 'Q?',
        index: 0,
        total: 1,
      );
      final buffer =
          'только flutter app, extension в cli такого не делаем. '
          'там надо будет думать другую форму и ещё немного текста сверху';
      final state = TuiPromptState(spec).copyWith(
        askMode: AskInputMode.freeText,
        secretValue: buffer,
        askCursor: buffer.length,
      );
      final rows = renderTuiPrompt(state, 60);
      expectRowsFit(rows, 60);
      // The whole buffer stays visible inside the frame.
      expect(rows.join('\n'), contains('и ещё немного текста'));
    });

    test('a pasted multi-line answer renders one framed row per line', () {
      final spec = AskPromptSpec(
        header: 'Ask',
        question: 'Q?',
        index: 0,
        total: 1,
      );
      const buffer = 'первая строка ответа\nвторая строка ответа';
      final state = TuiPromptState(spec).copyWith(
        askMode: AskInputMode.freeText,
        secretValue: buffer,
        askCursor: buffer.length,
      );
      final rows = renderTuiPrompt(state, 60);
      expectRowsFit(rows, 60);
      // Each logical line gets its OWN framed row — pre-fix both lived in
      // one over-wide row whose embedded \n tore the frame apart.
      final first = rows.singleWhere((r) => r.contains('первая строка'));
      final second = rows.singleWhere((r) => r.contains('вторая строка'));
      expect(first, isNot(second));
    });

    test('the text prompt input obeys the same invariant', () {
      const spec = TextPromptSpec(question: 'base URL:', secret: false);
      final state = TuiPromptState(
        spec,
      ).copyWith(secretValue: 'a' * 200, secretCursor: 200);
      expectRowsFit(renderTuiPrompt(state, 50), 50);
    });
  });
}
