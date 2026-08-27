import 'package:flutter_agent_harness/src/cli/sigint_action.dart';
import 'package:test/test.dart';

void main() {
  group('sigintAction', () {
    test('interactive press exits like /exit whether busy or idle', () {
      expect(sigintAction(headless: false), SigintAction.exitInteractive);
    });

    test('headless exits immediately regardless of busy', () {
      expect(sigintAction(headless: true), SigintAction.exitHeadless);
    });
  });
}
