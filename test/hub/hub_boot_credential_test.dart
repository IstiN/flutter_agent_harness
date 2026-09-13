import 'package:flutter_agent_harness/src/hub/hub_boot_credential.dart';
import 'package:test/test.dart';

void main() {
  const master = 'DAP_MASTER_SECRET';
  const client = 'DAP_CLIENT_SECRET';

  group('seedHubBootCredential', () {
    test('master already set in env — nothing seeded, env untouched', () {
      final env = <String, String>{master: 'm1'};
      final seeded = seedHubBootCredential(
        env,
        masterSecretKey: master,
        clientSecretKey: client,
        dapConfig: const {'clientSecret': 'from-config'},
      );
      expect(seeded, isNull);
      expect(env, {master: 'm1'});
    });

    test('client env set, master unset — master mirrors the client value', () {
      final env = <String, String>{client: 'c1'};
      final seeded = seedHubBootCredential(
        env,
        masterSecretKey: master,
        clientSecretKey: client,
        dapConfig: null,
      );
      expect(seeded, 'c1');
      expect(env[master], 'c1');
      expect(env[client], 'c1');
    });

    test('both env credentials set — nothing seeded', () {
      final env = <String, String>{master: 'm1', client: 'c1'};
      final seeded = seedHubBootCredential(
        env,
        masterSecretKey: master,
        clientSecretKey: client,
        dapConfig: const {'clientSecret': 'from-config'},
      );
      expect(seeded, isNull);
      expect(env[master], 'm1');
      expect(env[client], 'c1');
    });

    test('env clean + persisted config clientSecret — seeded from config', () {
      final env = <String, String>{};
      final seeded = seedHubBootCredential(
        env,
        masterSecretKey: master,
        clientSecretKey: client,
        dapConfig: const {
          'url': 'ws://127.0.0.1:8787/ws',
          'clientSecret': 'hello',
        },
      );
      expect(seeded, 'hello');
      expect(env[master], 'hello');
    });

    test('env clean + config without clientSecret — nothing seeded', () {
      final env = <String, String>{};
      final seeded = seedHubBootCredential(
        env,
        masterSecretKey: master,
        clientSecretKey: client,
        dapConfig: const {'url': 'ws://127.0.0.1:8787/ws'},
      );
      expect(seeded, isNull);
      expect(env, isEmpty);
    });

    test('env clean + empty-string clientSecret — nothing seeded', () {
      final env = <String, String>{};
      final seeded = seedHubBootCredential(
        env,
        masterSecretKey: master,
        clientSecretKey: client,
        dapConfig: const {'clientSecret': '  '},
      );
      expect(seeded, isNull);
      expect(env, isEmpty);
    });

    test('env clean + null config — nothing seeded (never opted in)', () {
      final env = <String, String>{};
      final seeded = seedHubBootCredential(
        env,
        masterSecretKey: master,
        clientSecretKey: client,
        dapConfig: null,
      );
      expect(seeded, isNull);
      expect(env, isEmpty);
    });

    test('env vars with whitespace-only values count as unset', () {
      final env = <String, String>{master: '   ', client: ''};
      final seeded = seedHubBootCredential(
        env,
        masterSecretKey: master,
        clientSecretKey: client,
        dapConfig: const {'clientSecret': 'hello'},
      );
      expect(seeded, 'hello');
      expect(env[master], 'hello');
    });
  });
}
