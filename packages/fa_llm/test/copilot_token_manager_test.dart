import 'dart:async';

import 'package:fa_llm/src/copilot/copilot_token.dart';
import 'package:fa_llm/src/copilot/copilot_token_manager.dart';
import 'package:test/test.dart';

CopilotToken tokenAt(DateTime expiresAt, {String value = 't'}) =>
    CopilotToken(token: value, expiresAt: expiresAt);

void main() {
  final t0 = DateTime.utc(2026, 8, 28, 12);

  group('shouldRefresh predicate', () {
    test('null token refreshes', () {
      expect(
        CopilotTokenManager.shouldRefresh(null, t0, const Duration(minutes: 2)),
        isTrue,
      );
    });

    test('comfortably valid token is cached', () {
      final token = tokenAt(t0.add(const Duration(minutes: 10)));
      expect(
        CopilotTokenManager.shouldRefresh(
          token,
          t0,
          const Duration(minutes: 2),
        ),
        isFalse,
      );
    });

    test('within the lead window refreshes', () {
      final token = tokenAt(t0.add(const Duration(minutes: 2)));
      expect(
        CopilotTokenManager.shouldRefresh(
          token,
          t0,
          const Duration(minutes: 2),
        ),
        isTrue,
      );
    });

    test('expired token refreshes', () {
      final token = tokenAt(t0.subtract(const Duration(seconds: 1)));
      expect(
        CopilotTokenManager.shouldRefresh(
          token,
          t0,
          const Duration(minutes: 2),
        ),
        isTrue,
      );
    });
  });

  test('caches a valid token across calls', () async {
    var exchanges = 0;
    final manager = CopilotTokenManager(
      exchange: () async {
        exchanges++;
        return tokenAt(t0.add(const Duration(minutes: 30)), value: 't1');
      },
      now: () => t0,
    );

    expect(await manager.get(), 't1');
    expect(await manager.get(), 't1');
    expect(exchanges, 1);
  });

  test('proactively refreshes inside the lead window', () async {
    var exchanges = 0;
    var clock = t0;
    final manager = CopilotTokenManager(
      exchange: () async {
        exchanges++;
        return tokenAt(
          clock.add(const Duration(minutes: 10)),
          value: 't$exchanges',
        );
      },
      now: () => clock,
    );

    expect(await manager.get(), 't1');
    expect(exchanges, 1);

    clock = t0.add(const Duration(minutes: 5)); // outside the 2 min lead
    expect(await manager.get(), 't1');
    expect(exchanges, 1);

    clock = t0.add(const Duration(minutes: 8, seconds: 1)); // inside the lead
    expect(await manager.get(), 't2');
    expect(exchanges, 2);
  });

  test('parallel getters share one exchange (single flight)', () async {
    var exchanges = 0;
    final completers = <Completer<CopilotToken>>[];
    final manager = CopilotTokenManager(
      exchange: () {
        exchanges++;
        final completer = Completer<CopilotToken>();
        completers.add(completer);
        return completer.future;
      },
      now: () => t0,
    );

    final futures = [manager.get(), manager.get(), manager.get()];
    expect(completers, hasLength(1));
    expect(exchanges, 1);

    completers.single.complete(
      tokenAt(t0.add(const Duration(minutes: 30)), value: 'shared'),
    );
    expect(await Future.wait(futures), ['shared', 'shared', 'shared']);
    expect(exchanges, 1);
  });

  test('never exchanges more often than minRefreshSpacing', () async {
    var exchanges = 0;
    var clock = t0;
    final waits = <Duration>[];
    final manager = CopilotTokenManager(
      exchange: () async {
        exchanges++;
        return tokenAt(clock.add(const Duration(seconds: 1)), value: 'short');
      },
      now: () => clock,
      delay: (d) async {
        waits.add(d);
        clock = clock.add(d);
      },
      minRefreshSpacing: const Duration(seconds: 30),
    );

    await manager.get(); // exchange #1 at t0
    clock = t0.add(const Duration(seconds: 5));

    await manager.getAgain(); // must wait 25s, then exchange #2

    expect(waits, [const Duration(seconds: 25)]);
    expect(clock, t0.add(const Duration(seconds: 30)));
    expect(exchanges, 2);
  });

  test('invalidate + getAgain forces a refresh', () async {
    var exchanges = 0;
    final manager = CopilotTokenManager(
      exchange: () async {
        exchanges++;
        return tokenAt(
          t0.add(const Duration(minutes: 30)),
          value: 't$exchanges',
        );
      },
      now: () => t0,
      delay: (_) async {},
    );

    expect(await manager.get(), 't1');
    manager.invalidate();
    expect(await manager.getAgain(), 't2');
    expect(exchanges, 2);
  });

  test('entries are isolated', () async {
    var exchangesA = 0;
    var exchangesB = 0;
    final a = CopilotTokenManager(
      exchange: () async {
        exchangesA++;
        return tokenAt(t0.add(const Duration(minutes: 30)), value: 'a');
      },
      now: () => t0,
    );
    final b = CopilotTokenManager(
      exchange: () async {
        exchangesB++;
        return tokenAt(t0.add(const Duration(minutes: 30)), value: 'b');
      },
      now: () => t0,
    );

    expect(await a.get(), 'a');
    expect(await b.get(), 'b');
    a.invalidate();
    expect(await b.get(), 'b');
    expect(exchangesA, 1);
    expect(exchangesB, 1);
  });

  test('works with platform defaults on first exchange', () async {
    final manager = CopilotTokenManager(
      exchange: () async => tokenAt(
        DateTime.now().add(const Duration(minutes: 30)),
        value: 'live',
      ),
    );
    expect(await manager.get(), 'live');
  });
}
