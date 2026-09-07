// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for [ActiveTabContext] — the per-turn `[context] active tab:`
/// injector. The headliner is the hang guard: a stuck `chrome.tabs` probe
/// must NEVER block the turn (issue #41 — a hung probe held every prompt
/// hostage and the DAP e2e timed out waiting for the agent's reply).
library;

import 'dart:async';

import 'package:test/test.dart';

import '../src/active_tab_context.dart';
import '../src/chrome_api.dart' show Tab;

Tab _tab(String url, [String title = 't']) =>
    Tab(id: 1, url: url, title: title, active: true, windowId: 1);

void main() {
  group('lineFor decision table', () {
    test('first turn injects the line, same tab dedupes', () {
      final ctx = ActiveTabContext();
      expect(
        ctx.lineFor(_tab('https://a.dev', 'A')),
        '[context] active tab: A — https://a.dev',
      );
      expect(ctx.lineFor(_tab('https://a.dev', 'A')), isNull);
    });

    test('a changed tab re-announces', () {
      final ctx = ActiveTabContext();
      ctx.lineFor(_tab('https://a.dev', 'A'));
      expect(
        ctx.lineFor(_tab('https://b.dev', 'B')),
        '[context] active tab: B — https://b.dev',
      );
    });

    test('restricted pages announce the restricted line once', () {
      final ctx = ActiveTabContext();
      expect(
        ctx.lineFor(_tab('chrome://extensions')),
        restrictedTabContextLine,
      );
      expect(ctx.lineFor(_tab('chrome://extensions')), isNull);
    });

    test('no tab announces nothing', () {
      expect(ActiveTabContext().lineFor(null), isNull);
    });
  });

  group('decorate', () {
    test('a throwing probe runs the turn bare', () async {
      final text = await ActiveTabContext().decorate(
        () async => throw StateError('tabs api down'),
        'hello',
      );
      expect(text, 'hello');
    });

    test('a hung probe NEVER blocks the turn (issue #41)', () async {
      final never = Completer<Tab?>(); // never completes — the stuck bridge
      final sw = Stopwatch()..start();
      final text = await ActiveTabContext().decorate(
        () => never.future,
        'hello',
        probeTimeout: const Duration(milliseconds: 200),
      );
      expect(text, 'hello');
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('a slow-but-alive probe inside the budget still decorates', () async {
      final text = await ActiveTabContext().decorate(
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return _tab('https://a.dev', 'A');
        },
        'hello',
        probeTimeout: const Duration(seconds: 2),
      );
      expect(text, '[context] active tab: A — https://a.dev\nhello');
    });
  });
}
