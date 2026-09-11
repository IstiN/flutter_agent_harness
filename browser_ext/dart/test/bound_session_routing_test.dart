// The inbound hub-mail routing decision table (faDap.boundSession): pure
// and fully pinned here; AgentHost maps actions onto session primitives.
import 'package:test/test.dart';

import '../src/dap/bound_session_routing.dart';

void main() {
  group('boundSessionAction', () {
    test('current mode never moves the session', () {
      expect(
        boundSessionAction(
          mode: 'current',
          boundId: 'abc',
          currentId: 'live',
          pristineLive: false,
        ),
        BoundSessionAction.stay,
      );
    });

    test('unrecognized modes behave like current', () {
      expect(
        boundSessionAction(
          mode: 'weird',
          boundId: 'abc',
          currentId: 'live',
          pristineLive: false,
        ),
        BoundSessionAction.stay,
      );
    });

    test('named opens the pinned session', () {
      expect(
        boundSessionAction(
          mode: 'named',
          boundId: 'abc',
          currentId: 'live',
          pristineLive: false,
        ),
        BoundSessionAction.openBound,
      );
    });

    test('named stays when already on the bound session', () {
      expect(
        boundSessionAction(
          mode: 'named',
          boundId: 'abc',
          currentId: 'abc',
          pristineLive: false,
        ),
        BoundSessionAction.stay,
      );
    });

    test('named without an id stays — never lose mail over dangling config',
        () {
      expect(
        boundSessionAction(
          mode: 'named',
          boundId: null,
          currentId: 'live',
          pristineLive: false,
        ),
        BoundSessionAction.stay,
      );
      expect(
        boundSessionAction(
          mode: 'named',
          boundId: '',
          currentId: 'live',
          pristineLive: false,
        ),
        BoundSessionAction.stay,
      );
    });

    test('dedicated with a remembered id opens it', () {
      expect(
        boundSessionAction(
          mode: 'dedicated',
          boundId: 'ded1',
          currentId: 'live',
          pristineLive: false,
        ),
        BoundSessionAction.openBound,
      );
    });

    test('dedicated stays when the dedicated session is already live', () {
      expect(
        boundSessionAction(
          mode: 'dedicated',
          boundId: 'ded1',
          currentId: 'ded1',
          pristineLive: false,
        ),
        BoundSessionAction.stay,
      );
    });

    test('dedicated without a remembered id creates one', () {
      expect(
        boundSessionAction(
          mode: 'dedicated',
          boundId: null,
          currentId: 'live',
          pristineLive: false,
        ),
        BoundSessionAction.createDedicated,
      );
      expect(
        boundSessionAction(
          mode: 'dedicated',
          boundId: '',
          currentId: 'live',
          pristineLive: true,
        ),
        BoundSessionAction.createDedicated,
      );
    });
  });
}
