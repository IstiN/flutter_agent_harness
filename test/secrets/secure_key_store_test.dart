import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

/// One recorded helper-process invocation.
final class _Call {
  _Call(this.executable, this.arguments, {this.stdin, this.environment});

  final String executable;
  final List<String> arguments;
  final String? stdin;
  final Map<String, String>? environment;

  String get command => '$executable ${arguments.join(' ')}';
}

/// Scripted [SecureKeyRunner]: records every call and answers from a queue
/// (or [responder] for call-dependent answers).
final class _FakeRunner {
  final calls = <_Call>[];
  final queue = <SecureKeyRunResult>[];
  SecureKeyRunResult Function(_Call call)? responder;

  Future<SecureKeyRunResult> call(
    String executable,
    List<String> arguments, {
    String? stdin,
    Map<String, String>? environment,
  }) async {
    final call = _Call(
      executable,
      arguments,
      stdin: stdin,
      environment: environment,
    );
    calls.add(call);
    final custom = responder;
    if (custom != null) return custom(call);
    return queue.removeAt(0);
  }
}

/// In-memory [SecureKeyStore] for [SecureKeyCache] tests.
final class _MapStore implements SecureKeyStore {
  _MapStore({this.availability = true});

  bool availability;
  final map = <String, String>{};

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => availability;

  @override
  Future<String?> read(String name) async => map[name];

  @override
  Future<void> write(String name, String value) async => map[name] = value;

  @override
  Future<void> delete(String name) async => map.remove(name);
}

void main() {
  group('macOS Keychain backend', () {
    test(
      'read returns the stored value without the trailing newline',
      () async {
        final runner = _FakeRunner()
          ..queue.add(const SecureKeyRunResult(0, 'sk-secret-123\n'));
        final store = platformSecureKeyStore(
          runner: runner.call,
          platform: 'macos',
        );

        final value = await store.read('OPENAI_API_KEY');

        expect(value, 'sk-secret-123');
        expect(
          runner.calls.single.command,
          'security find-generic-password -s fah -a OPENAI_API_KEY -w',
        );
      },
    );

    test('read maps a non-zero exit (item not found) to null', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(44, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'macos',
      );

      expect(await store.read('OPENAI_API_KEY'), isNull);
    });

    test('write updates the generic-password item', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(0, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'macos',
      );

      await store.write('OPENAI_API_KEY', 'sk-secret-123');

      expect(
        runner.calls.single.command,
        'security add-generic-password -s fah -a OPENAI_API_KEY '
        '-w sk-secret-123 -U',
      );
    });

    test('write surfaces a failing exit code', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(1, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'macos',
      );

      expect(
        () => store.write('OPENAI_API_KEY', 'sk-secret-123'),
        throwsStateError,
      );
    });

    test('delete tolerates a missing entry', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(44, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'macos',
      );

      await store.delete('OPENAI_API_KEY');

      expect(
        runner.calls.single.command,
        'security delete-generic-password -s fah -a OPENAI_API_KEY',
      );
    });

    test('availability follows the security binary probe', () async {
      final runner = _FakeRunner()
        ..queue.add(const SecureKeyRunResult(0, '/usr/bin/security\n'));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'macos',
      );

      expect(await store.isAvailable(), isTrue);
      expect(runner.calls.single.command, 'which security');
      expect(store.label, 'macOS Keychain');
    });
  });

  group('Linux Secret Service backend', () {
    test('unavailable without the secret-tool binary', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(1, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'linux',
      );

      expect(await store.isAvailable(), isFalse);
      expect(runner.calls.single.command, 'which secret-tool');
    });

    test('read looks the entry up by service and name', () async {
      final runner = _FakeRunner()
        ..queue.add(const SecureKeyRunResult(0, 'sk-secret-123'));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'linux',
      );

      final value = await store.read('OPENAI_API_KEY');

      expect(value, 'sk-secret-123');
      expect(
        runner.calls.single.command,
        'secret-tool lookup service fah name OPENAI_API_KEY',
      );
    });

    test('write passes the secret over stdin, never argv', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(0, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'linux',
      );

      await store.write('OPENAI_API_KEY', 'sk-secret-123');

      final call = runner.calls.single;
      expect(call.stdin, 'sk-secret-123');
      expect(call.command, isNot(contains('sk-secret-123')));
      expect(
        call.command,
        'secret-tool store --label=fah: OPENAI_API_KEY '
        'service fah name OPENAI_API_KEY',
      );
    });

    test('delete clears the attributes', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(0, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'linux',
      );

      await store.delete('OPENAI_API_KEY');

      expect(
        runner.calls.single.command,
        'secret-tool clear service fah name OPENAI_API_KEY',
      );
      expect(store.label, 'Secret Service');
    });
  });

  group('Windows Credential Locker backend', () {
    test('read retrieves the credential and unprotects the password', () async {
      final runner = _FakeRunner()
        ..queue.add(const SecureKeyRunResult(0, 'sk-secret-123\r\n'));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'windows',
      );

      final value = await store.read('OPENAI_API_KEY');

      expect(value, 'sk-secret-123');
      final call = runner.calls.single;
      expect(call.executable, 'powershell.exe');
      expect(call.arguments.take(3), [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
      ]);
      final script = call.arguments[3];
      expect(script, contains("Retrieve('fah','OPENAI_API_KEY')"));
      expect(script, contains('RetrievePassword()'));
    });

    test('write passes the secret through the child environment', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(0, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'windows',
      );

      await store.write('OPENAI_API_KEY', 'sk-secret-123');

      final call = runner.calls.single;
      expect(call.environment, {'FAH_SECRET': 'sk-secret-123'});
      final script = call.arguments[3];
      expect(script, isNot(contains('sk-secret-123')));
      expect(script, contains(r'$env:FAH_SECRET'));
      expect(script, contains('PasswordCredential'));
      expect(script, contains(r'$v.Add($c)'));
    });

    test('delete removes the credential, ignoring a miss', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(0, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'windows',
      );

      await store.delete('OPENAI_API_KEY');

      expect(
        runner.calls.single.arguments[3],
        contains(r'$v.Remove($v.Retrieve('),
      );
      expect(store.label, 'Windows Credential Locker');
    });
  });

  group('backend invariants', () {
    test(
      'unsupported platforms stay unavailable and throw on writes',
      () async {
        final store = platformSecureKeyStore(
          runner: _FakeRunner().call,
          platform: 'freebsd',
        );

        expect(await store.isAvailable(), isFalse);
        expect(await store.read('X'), isNull);
        expect(() => store.write('X', 'v'), throwsUnsupportedError);
        expect(() => store.delete('X'), throwsUnsupportedError);
      },
    );

    test('key names must match the env-var shape', () async {
      final store = platformSecureKeyStore(
        runner: _FakeRunner().call,
        platform: 'macos',
      );

      expect(() => store.read("bad'; rm -rf ~; '"), throwsArgumentError);
      expect(() => store.write('a b', 'v'), throwsArgumentError);
      expect(() => store.delete(r'$(x)'), throwsArgumentError);
    });

    test('a runner failure reads as unavailable / missing', () async {
      Future<SecureKeyRunResult> boom(
        String executable,
        List<String> arguments, {
        String? stdin,
        Map<String, String>? environment,
      }) => throw ProcessException(executable, arguments);

      final store = platformSecureKeyStore(runner: boom, platform: 'linux');
      expect(await store.isAvailable(), isFalse);
    });
  });

  group('SecureKeyCache', () {
    test('preload fills the synchronous snapshot', () async {
      final store = _MapStore()..map['OPENAI_API_KEY'] = 'sk-1';
      final cache = SecureKeyCache(store);

      await cache.preload(['OPENAI_API_KEY', 'ANTHROPIC_API_KEY']);

      expect(cache.available, isTrue);
      expect(cache.read('OPENAI_API_KEY'), 'sk-1');
      expect(cache.read('ANTHROPIC_API_KEY'), isNull);
      expect(cache.names, ['OPENAI_API_KEY']);
      expect(cache.label, 'fake store');
    });

    test('an unavailable store preloads nothing and rejects writes', () async {
      final store = _MapStore(availability: false);
      final cache = SecureKeyCache(store);

      await cache.preload(['OPENAI_API_KEY']);

      expect(cache.available, isFalse);
      expect(cache.read('OPENAI_API_KEY'), isNull);
      expect(await cache.save('OPENAI_API_KEY', 'sk-1'), isFalse);
      expect(await cache.delete('OPENAI_API_KEY'), isFalse);
      expect(store.map, isEmpty);
    });

    test('save and delete write through and update the snapshot', () async {
      final store = _MapStore();
      final cache = SecureKeyCache(store);
      await cache.probe();

      expect(await cache.save('OPENAI_API_KEY', 'sk-1'), isTrue);
      expect(store.map['OPENAI_API_KEY'], 'sk-1');
      expect(cache.read('OPENAI_API_KEY'), 'sk-1');

      expect(await cache.delete('OPENAI_API_KEY'), isTrue);
      expect(store.map, isEmpty);
      expect(cache.read('OPENAI_API_KEY'), isNull);
    });

    test('a null store behaves as unavailable', () async {
      final cache = SecureKeyCache(null);

      await cache.preload(['OPENAI_API_KEY']);

      expect(cache.available, isFalse);
      expect(cache.label, isNull);
      expect(cache.read('OPENAI_API_KEY'), isNull);
      expect(await cache.save('OPENAI_API_KEY', 'sk-1'), isFalse);
    });
  });
}
