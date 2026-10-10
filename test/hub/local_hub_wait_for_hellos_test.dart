// waitForHellos (#538): the PTY integration legs dial the wait timeout up
// (cold JIT on loaded CI runners), so the method takes a timeout — this
// unit test pins both arms without a PTY: the fast return when enough
// hellos were already seen, and the bounded wait (timeout firing when
// nobody ever says hello; resolving when a real client connects).
import 'dart:async';

import 'package:fa_hub_client/fa_hub_client.dart';
import 'package:flutter_agent_harness/src/hub/local_hub.dart';
import 'package:test/test.dart';

void main() {
  test(
    'waitForHellos returns immediately when n hellos were already seen',
    () async {
      final hub = LocalHub(port: 0);
      await hub.start();
      addTearDown(() => hub.stop());

      // Zero hellos are needed for n = 0 — the fast path must not touch
      // the clock at all.
      final sw = Stopwatch()..start();
      await hub.waitForHellos(0, timeout: const Duration(minutes: 5));
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    },
  );

  test('waitForHellos times out when no client ever says hello', () async {
    final hub = LocalHub(port: 0);
    await hub.start();
    addTearDown(() => hub.stop());

    await expectLater(
      hub.waitForHellos(1, timeout: const Duration(milliseconds: 150)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('waitForHellos resolves once a real client says hello', () async {
    final hub = LocalHub(port: 0);
    await hub.start();
    addTearDown(() => hub.stop());

    final identity = await HubIdentity.generate();
    final client = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: identity,
      backoff: (int _) => const Duration(milliseconds: 5),
    );

    final wait = hub.waitForHellos(1, timeout: const Duration(seconds: 5));
    await client.connect();
    addTearDown(() => client.disconnect());
    await wait;
    // Already satisfied now — the fast path again.
    await hub.waitForHellos(1);
  });

  // gh-1007: the PTY shard flaked dap_tui_menu_test's master-secret case
  // with `waitForHellos(1, timeout: 30s)` — under runner load the dial's
  // hello arrives in bursts past one fixed window. The ceiling poll
  // (waitForHellosUnderLoad) re-polls in bounded chunks until a global
  // ceiling; these tests pin all three arms without a PTY.
  group('waitForHellosUnderLoad (gh-1007)', () {
    test(
      'resolves when a late hello lands past the first chunk window',
      () async {
        final hub = LocalHub(port: 0);
        await hub.start();
        addTearDown(() => hub.stop());

        final identity = await HubIdentity.generate();
        final client = HubClient(
          config: HubConfig(url: hub.url.toString()),
          identity: identity,
          backoff: (int _) => const Duration(milliseconds: 5),
        );
        addTearDown(() => client.disconnect());

        // The hello lands 400ms in — past several 100ms chunk windows. A
        // single fixed window is exactly what flaked the CI shard; the
        // poll must ride through the early misses and still resolve.
        final wait = hub.waitForHellosUnderLoad(
          1,
          ceiling: const Duration(seconds: 5),
          chunk: const Duration(milliseconds: 100),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await client.connect();
        await wait;
      },
    );

    test('times out at the ceiling, not at the first chunk, when nobody '
        'ever says hello', () async {
      final hub = LocalHub(port: 0);
      await hub.start();
      addTearDown(() => hub.stop());

      final sw = Stopwatch()..start();
      await expectLater(
        hub.waitForHellosUnderLoad(
          1,
          ceiling: const Duration(milliseconds: 300),
          chunk: const Duration(milliseconds: 80),
        ),
        throwsA(isA<TimeoutException>()),
      );
      // The failure must arrive at the CEILING — a single fixed window
      // is what this method exists to replace (gh-1007 shard flake).
      expect(sw.elapsed, greaterThan(const Duration(milliseconds: 250)));
    });

    test('returns immediately when n hellos were already seen', () async {
      final hub = LocalHub(port: 0);
      await hub.start();
      addTearDown(() => hub.stop());

      final sw = Stopwatch()..start();
      await hub.waitForHellosUnderLoad(0, ceiling: const Duration(minutes: 5));
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });
}
