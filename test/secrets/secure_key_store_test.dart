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
  bool failWrites = false;
  final map = <String, String>{};

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => availability;

  @override
  Future<String?> read(String name) async => map[name];

  @override
  Future<void> write(String name, String value) async {
    if (failWrites) throw StateError('keychain write failed (exit 45)');
    map[name] = value;
  }

  @override
  Future<void> delete(String name) async {
    if (failWrites) throw StateError('keychain write failed (exit 45)');
    map.remove(name);
  }
}

/// A store whose every read throws — the degraded-keychain shape whose
/// silence gh-1059 is about: the preload must REPORT the failure, not
/// quietly leave the snapshot empty.
final class _ThrowingStore implements SecureKeyStore {
  @override
  String get label => 'throwing store';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> read(String name) async =>
      throw StateError('keychain read failed (exit 45)');

  @override
  Future<void> write(String name, String value) async {}

  @override
  Future<void> delete(String name) async {}
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
      final runner = _FakeRunner()
        ..queue.add(const SecureKeyRunResult(0, ''))
        ..queue.add(const SecureKeyRunResult(0, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'macos',
      );

      await store.write('OPENAI_API_KEY', 'sk-secret-123');

      // Preflight first (no default keychain → no system dialog), then add.
      expect(runner.calls.first.command, 'security default-keychain');
      expect(
        runner.calls.last.command,
        'security add-generic-password -s fah -a OPENAI_API_KEY '
        '-w sk-secret-123 -U',
      );
    });

    test('write surfaces a failing exit code', () async {
      final runner = _FakeRunner()
        ..queue.add(const SecureKeyRunResult(0, ''))
        ..queue.add(const SecureKeyRunResult(1, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'macos',
      );

      expect(
        () => store.write('OPENAI_API_KEY', 'sk-secret-123'),
        throwsStateError,
      );
    });

    test('write without a default keychain fails before the add (no system '
        'dialog)', () async {
      final runner = _FakeRunner()..queue.add(const SecureKeyRunResult(1, ''));
      final store = platformSecureKeyStore(
        runner: runner.call,
        platform: 'macos',
      );

      expect(
        () => store.write('OPENAI_API_KEY', 'sk-secret-123'),
        throwsStateError,
      );
      // The preflight alone ran — add-generic-password (which would pop the
      // "Keychain Not Found" dialog) was never invoked.
      expect(runner.calls.single.command, 'security default-keychain');
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

    test(
      'a failing backend degrades save/delete to false, never throws',
      () async {
        final store = _MapStore()..failWrites = true;
        final cache = SecureKeyCache(store);
        await cache.probe();

        expect(await cache.save('OPENAI_API_KEY', 'sk-1'), isFalse);
        expect(cache.read('OPENAI_API_KEY'), isNull);
        expect(await cache.delete('OPENAI_API_KEY'), isFalse);
      },
    );

    test('the process runner kills a hung helper instead of hanging', () async {
      final previous = secureKeyProcessTimeout;
      secureKeyProcessTimeout = const Duration(milliseconds: 300);
      addTearDown(() => secureKeyProcessTimeout = previous);

      final sw = Stopwatch()..start();
      final result = await secureKeyProcessRunner('sleep', const ['30']);
      expect(result.exitCode, -1);
      expect(result.timedOut, isTrue);
      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason: 'a modal/hung keychain helper must not block the CLI',
      );
    });

    test('the process runner reports spawn failures as -1', () async {
      final result = await secureKeyProcessRunner('definitely-not-a-binary', [
        'x',
      ]);
      expect(result.exitCode, -1);
      expect(result.timedOut, isFalse);
    });

    test('the process runner captures the helper stderr', () async {
      final result = await secureKeyProcessRunner('sh', const [
        '-c',
        'echo to-stdout; echo to-stderr >&2; exit 3',
      ]);
      expect(result.exitCode, 3);
      expect(result.stdout, 'to-stdout\n');
      expect(result.stderr, contains('to-stderr'));
    });

    test('helper environment overrides ride the inherited environment', () {
      // gh-1059 H1: a non-null map on Process.start REPLACES the child env;
      // the runner must merge overrides over the full inherited environment
      // so a helper never runs without PATH/HOME/SystemRoot.
      final merged = secureKeyChildEnvironment({'FAH_SECRET': 'x'});
      expect(merged, isNotNull);
      expect(merged!['FAH_SECRET'], 'x');
      for (final inherited in Platform.environment.entries) {
        expect(merged[inherited.key], inherited.value);
      }
      expect(secureKeyChildEnvironment(null), isNull);
    });

    test('a keychain read with an explicit env override still works '
        '(inherited env survives the spawn)', () async {
      // Real-spawn guard for the merge: the child sees BOTH the override
      // and the inherited environment (sh prints the inherited PATH).
      final result = await secureKeyProcessRunner(
        'sh',
        const ['-c', 'test -n "\$PATH" && echo "\$OVERRIDE_MARKER"'],
        environment: {'OVERRIDE_MARKER': 'inherited-env-intact'},
      );
      expect(result.exitCode, 0);
      expect(result.stdout, 'inherited-env-intact\n');
    });
  });

  group('SecureKeyCache preload report (gh-1059)', () {
    test('classifies found / absent / error per name', () async {
      final runner = _FakeRunner()
        ..queue.add(const SecureKeyRunResult(0, '/usr/bin/security\n')) // which
        ..queue.add(const SecureKeyRunResult(0, 'sk-1\n')) // found
        ..queue.add(const SecureKeyRunResult(44, '')) // not stored
        ..queue.add(
          const SecureKeyRunResult(
            45,
            '',
            stderr:
                'security: SecKeychainItemCopyFromAttributes:'
                ' Interaction is not allowed.',
          ),
        ) // ACL refusal
        ..queue.add(
          const SecureKeyRunResult(-1, '', timedOut: true),
        ); // bounded runner gave up
      final cache = SecureKeyCache(
        platformSecureKeyStore(runner: runner.call, platform: 'macos'),
      );

      final report = await cache.preload([
        'OPENAI_API_KEY',
        'MISSING_KEY',
        'ACL_KEY',
        'MODAL_KEY',
      ]);

      expect(report.storeAvailable, isTrue);
      expect(report.outcomes.map((o) => o.status).toList(), [
        SecureKeyReadStatus.found,
        SecureKeyReadStatus.absent,
        SecureKeyReadStatus.error,
        SecureKeyReadStatus.error,
      ]);
      expect(report.foundCount, 1);
      expect(report.absentCount, 1);
      expect(report.errorCount, 2);
      expect(cache.read('OPENAI_API_KEY'), 'sk-1');
      // The ACL refusal carries the stderr diagnostic instead of reading
      // as "no key ever saved" — the gh-1059 silent-absence hole.
      expect(report.outcomes[2].error, contains('Interaction is not allowed'));
      expect(report.outcomes[3].error, contains('timed out'));
    });

    test(
      'a plain store still reports errors instead of silent absence',
      () async {
        final store = _MapStore()..map['GOOD_KEY'] = 'sk-1';
        final cache = SecureKeyCache(store);

        final report = await cache.preload(['GOOD_KEY', 'MISSING_KEY']);

        expect(report.foundCount, 1);
        expect(report.absentCount, 1);
        expect(cache.read('GOOD_KEY'), 'sk-1');
      },
    );

    test(
      'a throwing read surfaces as an error outcome, preload still ends',
      () async {
        final store = _ThrowingStore();
        final cache = SecureKeyCache(store);

        final report = await cache.preload(['ANY_KEY']);

        expect(report.storeAvailable, isTrue);
        expect(report.errorCount, 1);
        expect(report.outcomes.single.error, contains('keychain read failed'));
      },
    );

    test('an unavailable store preloads nothing and reports it', () async {
      final store = _MapStore(availability: false);
      final cache = SecureKeyCache(store);

      final report = await cache.preload(['OPENAI_API_KEY']);

      expect(report.storeAvailable, isFalse);
      expect(report.outcomes, isEmpty);
    });

    test('save degradations are counted for the /key status summary', () async {
      final store = _MapStore()..failWrites = true;
      final cache = SecureKeyCache(store);
      await cache.probe();

      expect(await cache.save('OPENAI_API_KEY', 'sk-1'), isFalse);
      expect(cache.saveFailures, 1);
      expect(cache.lastSaveError, contains('keychain write failed'));

      final unavailable = SecureKeyCache(_MapStore(availability: false));
      expect(await unavailable.save('OPENAI_API_KEY', 'sk-1'), isFalse);
      expect(unavailable.saveFailures, 1);
      expect(unavailable.lastSaveError, contains('unavailable'));
    });
  });

  // `tags: integration` (gh-1059 review): this group performs a REAL
  // `security add-generic-password` against the developer's default
  // keychain — excluded from the pre-commit gate and the plain per-PR
  // core shards, executed by ci.yml's macOS cube-kernel-live leg
  // (`dart test test/secrets/secure_key_store_test.dart --tags
  // integration`) and runnable standalone with `--tags integration`.
  // (The file-level `@Tags` form would sweep the side-effect-free
  // `sleep`/`sh` runner groups into the tag; the group parameter keeps
  // them untagged.)
  group('real keychain runner (gh-1059 AC4, macOS only)', () {
    const testName = 'FA_KEY_SELFTEST_GH1059';

    bool securityUsable = false;
    setUpAll(() async {
      if (!Platform.isMacOS) return;
      // "Skip when no interactive keychain": a default keychain must exist
      // (the same preflight the write path runs before add-generic-password).
      final probe = await secureKeyProcessRunner('security', const [
        'default-keychain',
      ]);
      securityUsable = probe.exitCode == 0;
    });

    test(
      'the bounded runner writes, reads and deletes a real keychain item',
      () async {
        if (!Platform.isMacOS) return;
        // CI guard, not an assumption: the setUpAll probe decides.
        if (!securityUsable) return;
        final store = platformSecureKeyStore();

        await store.write(testName, 'sk-gh1059-selftest');
        try {
          final read = await store.read(testName);
          expect(read, 'sk-gh1059-selftest');
        } finally {
          await store.delete(testName);
        }
        expect(await store.read(testName), isNull);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }, tags: 'integration');
}
