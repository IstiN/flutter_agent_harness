// UT-consent-1: the mobile device-automation consent state machine.
//
// Pure Dart (no flutter imports in the code under test), so this runs
// without a widget binding. Covers the full legal transition graph,
// illegal transitions throwing StateError, and the audit log growing on
// every transition.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:fa/services/mobile/mobile_consent.dart';

void main() {
  group('MobileConsentModel legal transitions', () {
    test('happy path: notShown → acknowledged → pending → on', () {
      final model = MobileConsentModel();
      expect(model.stage, MobileConsentStage.notShown);
      expect(model.eventLog, isEmpty);

      model.acknowledge();
      expect(model.stage, MobileConsentStage.acknowledged);

      model.markServicePending();
      expect(model.stage, MobileConsentStage.servicePending);

      model.refreshService(true);
      expect(model.stage, MobileConsentStage.serviceOn);
      expect(model.eventLog.length, 3);
      // Every transition appended one audit line.
    });

    test('refreshService(false) from pending lands on serviceOff', () {
      final model = MobileConsentModel()
        ..acknowledge()
        ..markServicePending()
        ..refreshService(false);
      expect(model.stage, MobileConsentStage.serviceOff);
    });

    test('refreshService(true) is legal straight from acknowledged', () {
      final model = MobileConsentModel()
        ..acknowledge()
        ..refreshService(true);
      expect(model.stage, MobileConsentStage.serviceOn);
    });

    test('refreshService(false) is legal straight from acknowledged', () {
      final model = MobileConsentModel()
        ..acknowledge()
        ..refreshService(false);
      expect(model.stage, MobileConsentStage.serviceOff);
    });

    test('disable() works from any stage, serviceOn → serviceOff', () {
      for (final stage in MobileConsentStage.values) {
        final model = MobileConsentModel(stage: stage)..disable();
        expect(model.stage, MobileConsentStage.serviceOff, reason: 'from $stage');
      }
    });

    test('reset() re-arms to notShown and keeps the audit trail', () {
      final model = MobileConsentModel()
        ..acknowledge()
        ..markServicePending()
        ..refreshService(true);
      final logLength = model.eventLog.length;

      model.reset();
      expect(model.stage, MobileConsentStage.notShown);
      expect(model.eventLog.length, logLength + 1);
    });

    test('event log lines are ISO-timestamped with the event name', () {
      final model = MobileConsentModel()..acknowledge();
      final line = model.eventLog.single;
      expect(DateTime.tryParse(line.split(' ').first), isNotNull);
      expect(line.endsWith(' acknowledge'), isTrue);
    });
  });

  group('MobileConsentModel illegal transitions', () {
    test('acknowledge only from notShown', () {
      expect(
        () => (MobileConsentModel()..acknowledge()).acknowledge(),
        throwsStateError,
      );
    });

    test('markServicePending only from acknowledged', () {
      expect(() => MobileConsentModel().markServicePending(), throwsStateError);
      expect(
        () =>
            (MobileConsentModel()..refreshService(true)).markServicePending(),
        throwsStateError,
      );
    });

    test('refreshService not from notShown or terminal stages', () {
      expect(
        () => MobileConsentModel().refreshService(true),
        throwsStateError,
      );
      expect(
        () => (MobileConsentModel()..disable()).refreshService(false),
        throwsStateError,
      );
    });

    test('failed transitions leave stage and log untouched', () {
      final model = MobileConsentModel();
      expect(() => model.markServicePending(), throwsStateError);
      expect(model.stage, MobileConsentStage.notShown);
      expect(model.eventLog, isEmpty);
    });
  });
}
