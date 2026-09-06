// Background machinery tests (issue #30): IT-B1 covers the AlarmScheduler
// (clock-driven fires, exactly-once ledger across a simulated SW restart +
// replayed alarm, task persistence through a real JSON round trip, the
// 100-task cap, alarm cleanup on remove, storage quota passthrough) and
// IT-B2 the BadgeController state machine (idle/busy/mail transitions,
// E25 resync honesty, E20 denied-notification badge fallback).
//
// Sync broadcast events mean no await-flush: after an awaited drive the
// listener side effects are already visible.
import 'dart:convert';

import 'package:test/test.dart';

// The package has no lib/ — the SW entry compiles src/ directly.
import '../src/background/alarms.dart';
import '../src/background/badge.dart';
import '../src/chrome_api.dart';
import '../src/fake_chrome.dart';

/// Matches a ChromeApiException by its stable code (ops.js vocabulary).
Matcher coded(String code) =>
    isA<ChromeApiException>().having((e) => e.code, 'code', code);

void main() {
  group('IT-B1: AlarmScheduler', () {
    test('hourly task fires exactly once per tick on the fake clock', () async {
      const t0 = 1000000;
      const periodMs = 3600000;
      final chrome = FakeChrome(clock: () => t0);
      final fired = <String>[];
      final scheduler = AlarmScheduler(
        chrome,
        clock: () => chrome.nowMs,
        onDue: (task) => fired.add(task.id),
      );
      await scheduler.boot();
      await scheduler.schedule(
        ScheduledTask(
          id: 'hourly',
          prompt: 'check mail',
          period: const Duration(hours: 1),
        ),
      );

      await chrome.advanceTo(t0 + periodMs);
      expect(fired, ['hourly']); // exactly once
      await chrome.advanceTo(t0 + periodMs); // same instant again: silent
      expect(fired, ['hourly']);
      await chrome.advanceTo(t0 + 2 * periodMs);
      expect(fired, ['hourly', 'hourly']); // next period fires again
    });

    test(
      'SW restart + replayed alarm delivers the tick exactly once',
      () async {
        const t0 = 2000000;
        const periodMs = 3600000;
        const tick1 = t0 + periodMs;
        final chrome1 = FakeChrome(clock: () => t0);
        final fired1 = <String>[];
        final s1 = AlarmScheduler(
          chrome1,
          clock: () => chrome1.nowMs,
          onDue: (task) => fired1.add(task.id),
        );
        await s1.boot();
        await s1.schedule(
          ScheduledTask(
            id: 'hourly',
            prompt: 'p',
            period: const Duration(hours: 1),
          ),
        );
        await chrome1.advanceTo(tick1);
        expect(fired1, ['hourly']);

        // SW restart: the fresh chrome inherits ONLY storage (its alarm
        // pool is empty), and the snapshot goes through a real JSON round
        // trip like chrome.storage would.
        final snapshot = Map<String, Object?>.from(
          jsonDecode(jsonEncode(await chrome1.storage.get())) as Map,
        );
        final chrome2 = FakeChrome(clock: () => tick1);
        await chrome2.storage.set(snapshot);
        final fired2 = <String>[];
        final s2 = AlarmScheduler(
          chrome2,
          clock: () => chrome2.nowMs,
          onDue: (task) => fired2.add(task.id),
        );
        await s2.boot(); // re-arms for the NEXT period, no double fire
        expect(fired2, isEmpty);

        // Chrome re-delivers the recent tick1 alarm (replay after wake).
        await chrome2.alarms.create(
          name: 'fa-task-hourly',
          periodMinutes: 60,
          whenMs: tick1,
        );
        await chrome2.advanceTo(tick1);
        expect(fired2, isEmpty); // ledger suppressed the replay
        expect(fired1.length + fired2.length, 1); // exactly once in total

        // Persisted task list survived, unchanged.
        final task = s2.list().single;
        expect(task.id, 'hourly');
        expect(task.prompt, 'p');
        expect(task.period, const Duration(hours: 1));

        // ... and the next period still fires on the rebuilt schedule.
        await chrome2.advanceTo(tick1 + periodMs);
        expect(fired2, ['hourly']);
      },
    );

    test('cap of $maxScheduledTasks rejects the next task', () async {
      final chrome = FakeChrome(clock: () => 1000);
      final scheduler = AlarmScheduler(chrome, clock: () => chrome.nowMs);
      await scheduler.boot();
      for (var i = 1; i <= maxScheduledTasks; i++) {
        await scheduler.schedule(
          ScheduledTask(
            id: 't$i',
            prompt: 'p',
            period: const Duration(hours: 1),
          ),
        );
      }
      await expectLater(
        scheduler.schedule(
          ScheduledTask(
            id: 'over',
            prompt: 'p',
            period: const Duration(hours: 1),
          ),
        ),
        throwsA(coded('too_many_tasks')),
      );
      expect(scheduler.list(), hasLength(maxScheduledTasks));
    });

    test('removing a task clears its chrome alarm', () async {
      final chrome = FakeChrome(clock: () => 1000);
      final scheduler = AlarmScheduler(chrome, clock: () => chrome.nowMs);
      await scheduler.boot();
      await scheduler.schedule(
        ScheduledTask(
          id: 'hourly',
          prompt: 'p',
          period: const Duration(hours: 1),
        ),
      );
      expect(
        (await chrome.alarms.getAll()).map((a) => a.name),
        contains('fa-task-hourly'),
      );

      expect(await scheduler.remove('hourly'), isTrue);
      expect(
        (await chrome.alarms.getAll()).map((a) => a.name),
        isNot(contains('fa-task-hourly')),
      );
      expect(scheduler.list(), isEmpty);
      expect(await scheduler.remove('hourly'), isFalse);
    });

    test('storage quota errors surface as ChromeApiException', () async {
      final chrome = FakeChrome(clock: () => 1000, quotaBytes: 32);
      final scheduler = AlarmScheduler(chrome, clock: () => chrome.nowMs);
      await scheduler.boot();
      await expectLater(
        scheduler.schedule(
          ScheduledTask(
            id: 'hourly',
            prompt: 'p',
            period: const Duration(hours: 1),
          ),
        ),
        throwsA(coded('quota_exceeded')), // passthrough, not swallowed
      );
    });
  });

  group('IT-B2: BadgeController', () {
    test('transition table: idle→busy→mail!→busy→idle', () async {
      final chrome = FakeChrome(clock: () => 1000);
      final badge = BadgeController(chrome);
      expect(badge.state, BadgeState.idle);
      expect(chrome.badgeText, isNull); // nothing written until first event

      await badge.runStarted();
      expect(badge.state, BadgeState.busy);
      expect(chrome.badgeText, 'busy');
      expect(chrome.badgeBackgroundColor, '#1a73e8');

      await badge.runEnded();
      expect(badge.state, BadgeState.idle);
      expect(chrome.badgeText, ''); // chrome's clear-the-badge value

      await badge.runStarted();
      await badge.mailArrived(); // mail during busy wins
      expect(badge.state, BadgeState.mail);
      expect(chrome.badgeText, 'mail!');
      expect(chrome.badgeBackgroundColor, '#d93025');

      await badge.mailArrived(); // more unread mail: still 'mail!'
      expect(chrome.badgeText, 'mail!');

      await badge.mailSeen(); // back to the still-running state
      expect(badge.state, BadgeState.busy);
      expect(chrome.badgeText, 'busy');

      await badge.runEnded();
      expect(badge.state, BadgeState.idle);
      expect(chrome.badgeText, '');
    });

    test(
      'E25: resync corrects a badge stuck on busy after a forced kill',
      () async {
        final chrome = FakeChrome(clock: () => 1000);
        final badge = BadgeController(chrome);
        await badge.runStarted();
        expect(chrome.badgeText, 'busy');

        // Authoritative inputs after the wake: mail arrived, run still on.
        await badge.resync(running: true, unreadMail: 2);
        expect(badge.state, BadgeState.mail);
        expect(chrome.badgeText, 'mail!');

        // Nothing runs anymore, no unread mail: stuck 'busy' corrected.
        await badge.resync(running: false, unreadMail: 0);
        expect(badge.state, BadgeState.idle);
        expect(chrome.badgeText, '');
      },
    );

    test(
      'E20: denied permission → notify() false, badge carries the signal',
      () async {
        final denied = FakeChrome(
          clock: () => 1000,
          notificationPermission: 'denied',
        );
        final badge = BadgeController(denied);
        expect(await badge.notify(title: 'Mail', message: '2 new'), isFalse);
        expect(denied.badgeText, '!'); // badge-only fallback, no throw
        expect(denied.badgeText, isNot('mail!'));

        final granted = FakeChrome(clock: () => 1000);
        final ok = BadgeController(granted);
        expect(await ok.notify(title: 'Mail', message: '2 new'), isTrue);
        expect(
          granted.badgeText,
          isNull,
        ); // shown notification needs no fallback
      },
    );
  });
}
