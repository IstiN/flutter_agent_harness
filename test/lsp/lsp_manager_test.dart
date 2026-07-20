@Timeout(Duration(seconds: 10))
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'fake_lsp_server.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeLspServerFactory factory;

  LspClientManager makeManager({
    Duration? idleTimeout,
    Duration idleCheckInterval = const Duration(milliseconds: 20),
    int maxRestarts = 3,
    Duration initFailureBackoff = const Duration(minutes: 3),
    Duration crashWindow = const Duration(seconds: 10),
    LspConfig? config,
  }) => LspClientManager(
    env: env,
    config: config ?? LspConfig.defaults(),
    transportFactory: factory.call,
    idleTimeout: idleTimeout,
    idleCheckInterval: idleCheckInterval,
    maxRestarts: maxRestarts,
    initFailureBackoff: initFailureBackoff,
    crashWindow: crashWindow,
  );

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/ws');
    await env.writeFile('/ws/pubspec.yaml', 'name: ws\n');
    await env.writeFile('/ws/lib/a.dart', 'void main() {}\n');
    factory = FakeLspServerFactory();
  });

  group('lazy lifecycle', () {
    test('starts on first use and reuses the client', () async {
      final manager = makeManager();
      addTearDown(manager.shutdownAll);

      expect(factory.spawned, isEmpty);
      final first = await manager.clientForFile('/ws/lib/a.dart');
      expect(factory.spawned, hasLength(1));
      expect(first.status, LspClientStatus.ready);
      expect(first.rootPath, '/ws');

      final second = await manager.clientForFile('/ws/lib/a.dart');
      expect(identical(first, second), isTrue);
      expect(factory.spawned, hasLength(1));
      expect(manager.clients.keys, ['dart:/ws']);
    });

    test('no server for the extension throws LspNoServerException', () async {
      final manager = makeManager();
      addTearDown(manager.shutdownAll);
      await expectLater(
        manager.clientForFile('/ws/notes.txt'),
        throwsA(isA<LspNoServerException>()),
      );
      expect(factory.spawned, isEmpty);
    });

    test('concurrent clientForFile calls share one spawn', () async {
      final manager = makeManager();
      addTearDown(manager.shutdownAll);
      final results = await Future.wait([
        manager.clientForFile('/ws/lib/a.dart'),
        manager.clientForFile('/ws/lib/a.dart'),
      ]);
      expect(identical(results[0], results[1]), isTrue);
      expect(factory.spawned, hasLength(1));
    });
  });

  group('failures', () {
    test('spawn failure surfaces as unavailable and is retried', () async {
      var attempts = 0;
      Future<LspTransport> flaky(LspServerConfig config, String cwd) {
        attempts++;
        if (attempts == 1) {
          throw const LspServerUnavailableException(
            'cannot start: not on PATH',
          );
        }
        return factory(config, cwd);
      }

      final manager = LspClientManager(
        env: env,
        config: LspConfig.defaults(),
        transportFactory: flaky,
      );
      addTearDown(manager.shutdownAll);

      await expectLater(
        manager.clientForFile('/ws/lib/a.dart'),
        throwsA(
          isA<LspServerUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('not on PATH'),
          ),
        ),
      );
      // Not negative-cached: the next call spawns successfully.
      final client = await manager.clientForFile('/ws/lib/a.dart');
      expect(client.status, LspClientStatus.ready);
      expect(attempts, 2);
    });

    test('init failure is negative-cached for the backoff window', () async {
      // The handshake hangs (never answered) → the init timeout fires.
      factory.onSpawn = (server) {
        server.autoRespond = false;
      };
      final manager = LspClientManager(
        env: env,
        config: LspConfig.defaults(),
        transportFactory: factory.call,
        initTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(manager.shutdownAll);

      await expectLater(
        manager.clientForFile('/ws/lib/a.dart'),
        throwsA(isA<LspRequestException>()),
      );
      expect(factory.spawned, hasLength(1));

      // Backoff: the next call fails fast without a new spawn.
      await expectLater(
        manager.clientForFile('/ws/lib/a.dart'),
        throwsA(
          isA<LspServerUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('failed to initialize recently'),
          ),
        ),
      );
      expect(factory.spawned, hasLength(1));
    });

    test('a crashed client is dropped and respawned on next use', () async {
      final manager = makeManager(
        crashWindow: Duration.zero, // crashes never count as "quick"
      );
      addTearDown(manager.shutdownAll);

      final first = await manager.clientForFile('/ws/lib/a.dart');
      await factory.spawned.single.simulateCrash();
      await pumpEventQueue();
      expect(manager.clients, isEmpty);
      expect(first.status, LspClientStatus.closed);

      final second = await manager.clientForFile('/ws/lib/a.dart');
      expect(identical(first, second), isFalse);
      expect(factory.spawned, hasLength(2));
    });

    test('repeated quick crashes bound respawning with a backoff', () async {
      final manager = makeManager(maxRestarts: 2);
      addTearDown(manager.shutdownAll);

      // Crash 1 (within the window) then respawn, crash 2 → backoff.
      await manager.clientForFile('/ws/lib/a.dart');
      await factory.spawned[0].simulateCrash();
      await pumpEventQueue();
      await manager.clientForFile('/ws/lib/a.dart');
      await factory.spawned[1].simulateCrash();
      await pumpEventQueue();

      await expectLater(
        manager.clientForFile('/ws/lib/a.dart'),
        throwsA(
          isA<LspServerUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('crashed'),
          ),
        ),
      );
      expect(factory.spawned, hasLength(2));
    });

    test('a disposed manager refuses new clients', () async {
      final manager = makeManager();
      await manager.shutdownAll();
      await expectLater(
        manager.clientForFile('/ws/lib/a.dart'),
        throwsA(isA<LspServerUnavailableException>()),
      );
    });
  });

  group('idle timeout', () {
    test('the sweep shuts down idle clients', () async {
      final manager = makeManager(
        idleTimeout: const Duration(milliseconds: 50),
        idleCheckInterval: const Duration(milliseconds: 10),
      );
      addTearDown(manager.shutdownAll);

      final client = await manager.clientForFile('/ws/lib/a.dart');
      expect(manager.clients, hasLength(1));

      // Wait for at least one sweep past the idle timeout.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(manager.clients, isEmpty);
      expect(client.status, LspClientStatus.closed);
    });

    test('checkIdle keeps recently active clients', () async {
      final manager = makeManager(
        idleTimeout: const Duration(milliseconds: 80),
        // No periodic sweep in this test: drive it manually.
        idleCheckInterval: const Duration(days: 1),
      );
      addTearDown(manager.shutdownAll);

      final client = await manager.clientForFile('/ws/lib/a.dart');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await manager.checkIdle();
      expect(manager.clients, hasLength(1));

      // Activity bumps lastActivity (touched by the manager on reuse).
      await manager.clientForFile('/ws/lib/a.dart');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await manager.checkIdle();
      expect(manager.clients, hasLength(1));
      expect(client.status, LspClientStatus.ready);
    });
  });

  group('shutdownAll', () {
    test('shuts down every client and stops the sweep', () async {
      final manager = makeManager(
        idleTimeout: const Duration(milliseconds: 50),
      );
      final client = await manager.clientForFile('/ws/lib/a.dart');
      await manager.shutdownAll();
      expect(manager.clients, isEmpty);
      expect(client.status, LspClientStatus.closed);
      // The fake exits gracefully on `exit`, so no kill is needed.
      expect(
        factory.spawned.single.notifications.map((n) => n.method),
        contains('exit'),
      );
    });
  });
}
