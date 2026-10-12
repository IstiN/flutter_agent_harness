// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/cli/ask_menu.dart';
import 'package:flutter_agent_harness/src/tools/ask_tool.dart';
import 'package:test/test.dart';

AskQuestion _question({
  String text = 'Proceed with the plan?',
  List<AskOption> options = const [
    AskOption(label: 'Yes'),
    AskOption(label: 'No', description: 'Stop here'),
    AskOption(label: 'Ask later'),
  ],
  int? recommended,
}) => AskQuestion(question: text, options: options, recommended: recommended);

void main() {
  group('askQuestionLines', () {
    test('one question renders header + one row per option', () {
      final lines = askQuestionLines(_question(), 0, 1);
      expect(lines.length, 4); // header + 3 options
      expect(lines.first, '[ask] Proceed with the plan?');
    });

    test('a multi-question batch shows 1-based progress on the header', () {
      expect(
        askQuestionLines(_question(), 0, 2).first,
        '[ask] Proceed with the plan? (1/2)',
      );
      expect(
        askQuestionLines(_question(), 1, 2).first,
        '[ask] Proceed with the plan? (2/2)',
      );
    });

    test('a single question shows no progress suffix', () {
      expect(askQuestionLines(_question(), 0, 1).first, isNot(contains('/')));
    });

    test('options are numbered 1-based and keep their descriptions', () {
      final lines = askQuestionLines(_question(), 0, 1);
      expect(lines[1], '[ask]   1) Yes');
      expect(lines[2], '[ask]   2) No — Stop here');
      expect(lines[3], '[ask]   3) Ask later');
    });

    test('only the recommended option carries the marker', () {
      final lines = askQuestionLines(_question(recommended: 1), 0, 1);
      expect(lines[1], isNot(contains('(Recommended)')));
      expect(lines[2], '[ask]   2) No — Stop here (Recommended)');
    });

    test('a blank description renders like none at all', () {
      final lines = askQuestionLines(
        _question(
          options: const [
            AskOption(label: 'A', description: '   '),
            AskOption(label: 'B'),
          ],
        ),
        0,
        1,
      );
      expect(lines[1], '[ask]   1) A');
      expect(lines[2], '[ask]   2) B');
    });
  });

  group('pickedLabel', () {
    test('an empty selection renders as a dash', () {
      expect(pickedLabel({}), '-');
    });

    test('selections render 1-based, sorted, comma-separated', () {
      expect(pickedLabel({1, 0, 3}), '1, 2, 4');
      expect(pickedLabel({2}), '3');
    });
  });
}
