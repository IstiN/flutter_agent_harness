// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Boot diagnostics (gh-1507): the [BootSteps] ledger and the
/// [BootWatchdog] first-frame watchdog. The watchdog is the ticket's fix —
/// a pre-frame wedge must leave an actionable breadcrumb (uptime + last
/// completed boot step) in the logs instead of a silent freeze.
library;

import 'package:fa/boot/boot_watchdog.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(BootSteps.reset);
  tearDown(BootSteps.reset);

  group('BootSteps (boot-step ledger)', () {
    test('marks steps with process uptime, oldest first', () {
      BootSteps.mark('window');
      BootSteps.mark('services');
      final described = BootSteps.describe();
      expect(described, contains('window@'));
      expect(described, contains('services@'));
      expect(
        described.indexOf('window@'),
        lessThan(described.indexOf('services@')),
      );
    });

    test('reports the in-flight step when a step wedges mid-way', () {
      BootSteps.mark('window');
      BootSteps.begin('storage:sessionKeys');
      final described = BootSteps.describe();
      expect(described, contains('window@'));
      expect(described, contains('(in flight: storage:sessionKeys)'));
    });

    test('a completed mark clears the in-flight step', () {
      BootSteps.begin('storage:sessionKeys');
      BootSteps.mark('storage:sessionKeys');
      expect(BootSteps.describe(), isNot(contains('in flight')));
    });

    test('describe caps the tail at the last six steps', () {
      for (var i = 0; i < 10; i++) {
        BootSteps.mark('step-$i');
      }
      final described = BootSteps.describe();
      expect(described, contains('step-9'));
      expect(described, isNot(contains('step-3')));
    });
  });

  group('BootWatchdog (first-frame watchdog)', () {
    test('a breadcrumb fires when the first frame misses the threshold', () {
      fakeAsync((async) {
        final breadcrumbs = <String>[];
        final watchdog = BootWatchdog(
          threshold: const Duration(seconds: 4),
          repeatInterval: const Duration(seconds: 30),
          onBreadcrumb: breadcrumbs.add,
        );
        watchdog.install();
        expect(breadcrumbs, isEmpty);

        async.elapse(const Duration(seconds: 5));
        expect(breadcrumbs, hasLength(1));
        expect(breadcrumbs.single, contains('first frame not reached'));
        expect(breadcrumbs.single, contains('firing #1'));
        // Boot-steps context rides along — the actionable part of the
        // breadcrumb (gh-1507 AC3).
        expect(breadcrumbs.single, contains('boot steps ['));
      });
    });

    test('keeps re-firing on the repeat interval until the first frame', () {
      fakeAsync((async) {
        final breadcrumbs = <String>[];
        final watchdog = BootWatchdog(
          threshold: const Duration(seconds: 4),
          repeatInterval: const Duration(seconds: 30),
          onBreadcrumb: breadcrumbs.add,
        );
        watchdog.install();

        async.elapse(const Duration(seconds: 4) + const Duration(seconds: 1));
        expect(breadcrumbs, hasLength(1));
        async.elapse(const Duration(seconds: 30));
        expect(breadcrumbs, hasLength(2));
        expect(breadcrumbs[1], contains('firing #2'));
        // No breadcrumb storm: one per firing, not per tick.
        async.elapse(const Duration(seconds: 5));
        expect(breadcrumbs, hasLength(2));
      });
    });

    test('the first frame cancels the watchdog without any breadcrumb', () {
      fakeAsync((async) {
        final breadcrumbs = <String>[];
        final watchdog = BootWatchdog(
          threshold: const Duration(seconds: 4),
          repeatInterval: const Duration(seconds: 30),
          onBreadcrumb: breadcrumbs.add,
        );
        watchdog.install();
        async.elapse(const Duration(seconds: 3));
        watchdog.firstFrame();
        async.elapse(const Duration(minutes: 5));
        expect(breadcrumbs, isEmpty);
      });
    });

    test(
      'a late first frame after firings logs the recovery with the uptime',
      () {
        fakeAsync((async) {
          final breadcrumbs = <String>[];
          final watchdog = BootWatchdog(
            threshold: const Duration(seconds: 4),
            repeatInterval: const Duration(seconds: 30),
            onBreadcrumb: breadcrumbs.add,
          );
          watchdog.install();
          async.elapse(const Duration(seconds: 10));
          expect(breadcrumbs, hasLength(1));
          watchdog.firstFrame();
          expect(breadcrumbs, hasLength(2));
          expect(breadcrumbs.last, contains('first frame landed at'));
          expect(breadcrumbs.last, contains('watchdog had fired 1×'));
        });
      },
    );

    test('install is idempotent — one timer, one breadcrumb stream', () {
      fakeAsync((async) {
        final breadcrumbs = <String>[];
        final watchdog = BootWatchdog(
          threshold: const Duration(seconds: 4),
          repeatInterval: const Duration(seconds: 30),
          onBreadcrumb: breadcrumbs.add,
        );
        watchdog.install();
        watchdog.install();
        async.elapse(const Duration(seconds: 40));
        // Two installs still mean firing #1 then firing #2 — no double arm.
        expect(breadcrumbs, hasLength(2));
      });
    });
  });
}
