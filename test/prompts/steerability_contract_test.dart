/// IS the observable surface delivered to the model.
library;

import 'package:flutter_agent_harness/src/prompts/prompts.g.dart' as generated;
import 'package:test/test.dart';

void main() {
  group('task tool prompt carries the idle-not-blocked contract (#520)', () {
    test('background spawn ends the turn — completions and mail wake', () {
      expect(
        generated.taskToolDescriptionPrompt,
        contains('background: true'),
        reason: 'the background escape is named',
      );
      expect(
        generated.taskToolDescriptionPrompt,
        contains('END YOUR TURN'),
        reason: 'waiting is idle: the turn ends after spawning',
      );
      expect(
        generated.taskToolDescriptionPrompt,
        contains('wake'),
        reason: 'the wake sources (completions, inbox mail) are named',
      );
      expect(
        generated.taskToolDescriptionPrompt,
        contains('NEVER park your turn'),
        reason: 'watch loops and blocking re-polls are forbidden',
      );
    });
  });

  group('messaging prompt carries the owner-routes-through-main contract', () {
    test('children are never the owner address; route via task_send', () {
      expect(
        generated.cliMessagingSectionPrompt,
        contains('only'),
        reason: 'the owner talks to the main agent only',
      );
      expect(
        generated.cliMessagingSectionPrompt,
        contains('task_send'),
        reason: 'routing to a child is a task_send + report back',
      );
    });
  });
}
