import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// In-memory [SecureKeyStore] whose write failure is a configurable thrown
/// error: the generic keychain failure, or the macOS "no default keychain"
/// preflight shape (gh-1679).
final class _FlakyStore implements SecureKeyStore {
  _FlakyStore({this.writeError});

  Object? writeError;
  final map = <String, String>{};

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> read(String name) async => map[name];

  @override
  Future<void> write(String name, String value) async {
    final error = writeError;
    if (error != null) throw error;
    map[name] = value;
  }

  @override
  Future<void> delete(String name) async => map.remove(name);
}

/// A [Shell] that stands in for the macOS `security` CLI: records the
/// command and clears the store's write failure — simulating the default
/// keychain pointer coming back.
final class _RepairShell implements Shell {
  _RepairShell(this.store);

  final _FlakyStore store;
  final commands = <String>[];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    store.writeError = null;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}

void main() {
  late FakeCliIO io;

  setUp(() => io = FakeCliIO());
  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    ExecutionEnv? env,
    void Function(String name, String value)? onSecretStored,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env ?? MemoryExecutionEnv(cwd: '/work'),
        sessionRoot: '/sessions',
        secureKeys: secureKeys,
        customProviders: customProviders,
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
        onSecretStored: onSecretStored,
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  /// Drives `/provider custom` through the scripted line-mode wizard:
  /// openai-like (1), [baseUrl], name, [key], manual model [model].
  Future<void> runWizard({
    required String baseUrl,
    required String name,
    required String key,
  }) async {
    io.sendLine('/provider custom');
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.sendLine('1');
    await waitForIt(() => io.out.toString().contains('base URL (empty ='));
    io.sendLine(baseUrl);
    await waitForIt(
      () => io.out.toString().contains('provider name (empty ='),
    );
    io.sendLine(name);
    await waitForIt(
      () => io.out.toString().contains('API key (empty for none):'),
    );
    io.sendLine(key);
    await waitForIt(
      () => io.out.toString().contains('no model list from the endpoint'),
    );
    io.sendLine('proxy-model');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openai'),
    );
  }

  group('wizard loud save failure (gh-1679 UT-1, IT-1, AC1, AC4)', () {
    test('a failing store prints slot + label + diagnostic on the spot, '
        'records the entry flagged, and never renders the key value',
        () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = _FlakyStore()
        ..writeError = StateError('keychain write failed (exit 45)');
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry(const []);
      final cli = cliFor(
        fake.call,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      await runWizard(
        baseUrl: 'https://api.kimi.com/coding/v1',
        name: 'kimi_ira',
        key: 'sk-ira-secret-789',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      const slot = 'FA_KEY_API_KIMI_COM_KIMI_IRA';
      // Loud on the spot: slot + store label + diagnostic (AC1).
      expect(output, contains('could not save $slot to fake store'));
      expect(output, contains('keychain write failed (exit 45)'));
      expect(
        output,
        contains('/key set $slot <value>'),
      );
      // The session keeps working off the typed token.
      expect(output, contains('key: provided'));
      // AC4 byte-scan: no rendered string carries any byte of the value.
      expect(output, isNot(contains('sk-ira-secret-789')));

      // The entry is still recorded, carrying its slot + the flag.
      final entry = registry.find('kimi_ira');
      expect(entry, isNotNull);
      expect(entry!.keyName, slot);
      expect(entry.keyNotPersisted, isTrue);
      // The store stayed empty; the cache tracks the failed name.
      expect(store.map, isEmpty);
      expect(cache.failedSaveNames, [slot]);
    });

    test('a working store keeps the flow byte-identical (no loud message, '
        'no flag)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = _FlakyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry(const []);
      final cli = cliFor(
        fake.call,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      await runWizard(
        baseUrl: 'https://api.kimi.com/coding/v1',
        name: 'kimi_ira',
        key: 'sk-ira-secret-789',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, isNot(contains('could not save')));
      expect(output, isNot(contains('keyNotPersisted')));
      expect(
        store.map['FA_KEY_API_KIMI_COM_KIMI_IRA'],
        'sk-ira-secret-789',
      );
      final entry = registry.find('kimi_ira');
      expect(entry!.keyNotPersisted, isFalse);
      expect(cache.failedSaveNames, isEmpty);
    });

    test('wizard and /key set failure handling converge (AC5 parity)',
        () async {
      const slot = 'FA_KEY_API_KIMI_COM_KIMI_IRA';
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final store = _FlakyStore()
        ..writeError = StateError('keychain write failed (exit 45)');
      final cache = SecureKeyCache(store);
      await cache.probe();
      final cli = cliFor(fake.call, secureKeys: cache);
      final run = cli.run();

      // /key set on the same failing store.
      io.sendLine('/key set $slot sk-ira-secret-789');
      await waitForIt(
        () => io.out.toString().contains('could not save $slot'),
      );

      // The wizard on the same failing store.
      await runWizard(
        baseUrl: 'https://api.kimi.com/coding/v1',
        name: 'kimi_ira',
        key: 'sk-ira-secret-789',
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      // Both write paths converge on the shared loud-failure surface:
      // `could not save <slot> to <label>: the write failed` (/key set's
      // wording is the frozen golden; the wizard matches it and adds the
      // diagnostic + retry command — the incident RCA's ask).
      final keySetLine = output
          .split('\n')
          .firstWhere((l) => l.contains('could not save $slot'));
      final wizardLine = output
          .split('\n')
          .reversed
          .firstWhere((l) => l.contains('could not save $slot'));
      for (final line in [keySetLine, wizardLine]) {
        expect(
          line,
          contains('could not save $slot to fake store: the write failed'),
        );
      }
      expect(wizardLine, contains('keychain write failed (exit 45)'));
      expect(wizardLine, contains('/key set $slot <value>'));
      expect(output, isNot(contains('sk-ira-secret-789')));
    });
  });

  group('macOS default-keychain repair offer (gh-1679 AC7)', () {
    test('an explicit "n" degrades to advisory text; nothing runs without '
        'the yes', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = _FlakyStore()
        ..writeError = StateError('no default keychain (exit 1)');
      final shell = _RepairShell(store);
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry(const []);
      final cli = cliFor(
        fake.call,
        secureKeys: cache,
        customProviders: registry,
        env: env,
      );
      final run = cli.run();

      io.sendLine('/provider custom');
      await waitForIt(() => io.out.toString().contains('type a number:'));
      io.sendLine('1');
      await waitForIt(() => io.out.toString().contains('base URL (empty ='));
      io.sendLine('https://api.kimi.com/coding/v1');
      await waitForIt(
        () => io.out.toString().contains('provider name (empty ='),
      );
      io.sendLine('kimi_ira');
      await waitForIt(
        () => io.out.toString().contains('API key (empty for none):'),
      );
      io.sendLine('sk-ira-secret-789');
      await waitForIt(
        () => io.out.toString().contains('no model list from the endpoint'),
      );
      io.sendLine('proxy-model');
      // The loud failure names the missing default keychain...
      await waitForIt(
        () => io.out.toString().contains('no default keychain (exit 1)'),
      );
      // ...and the [y/N] offer appears.
      await waitForIt(
        () => io.out.toString().contains('[y/N]'),
      );
      io.sendLine('n');
      await waitForIt(
        () => io.out.toString().contains('switched provider to openai'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      // AC6: advisory names the system remedy; AC7: it never executed.
      expect(output, contains('security default-keychain -s'));
      expect(shell.commands, isEmpty);
      expect(store.map, isEmpty);
      expect(registry.find('kimi_ira')!.keyNotPersisted, isTrue);
      expect(output, isNot(contains('sk-ira-secret-789')));
    });

    test('a "y" runs the exact repair command and re-attempts the save',
        () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = _FlakyStore()
        ..writeError = StateError('no default keychain (exit 1)');
      final shell = _RepairShell(store);
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry(const []);
      final cli = cliFor(
        fake.call,
        secureKeys: cache,
        customProviders: registry,
        env: env,
      );
      final run = cli.run();

      io.sendLine('/provider custom');
      await waitForIt(() => io.out.toString().contains('type a number:'));
      io.sendLine('1');
      await waitForIt(() => io.out.toString().contains('base URL (empty ='));
      io.sendLine('https://api.kimi.com/coding/v1');
      await waitForIt(
        () => io.out.toString().contains('provider name (empty ='),
      );
      io.sendLine('kimi_ira');
      await waitForIt(
        () => io.out.toString().contains('API key (empty for none):'),
      );
      io.sendLine('sk-ira-secret-789');
      await waitForIt(
        () => io.out.toString().contains('no model list from the endpoint'),
      );
      io.sendLine('proxy-model');
      await waitForIt(() => io.out.toString().contains('[y/N]'));
      io.sendLine('y');
      await waitForIt(
        () => io.out.toString().contains('saved FA_KEY_API_KIMI_COM_KIMI_IRA'),
      );
      io.sendLine('/exit');
      await run;

      // The exact repair command ran once, then the save landed.
      expect(
        shell.commands,
        ['security default-keychain -s ~/Library/Keychains/login.keychain-db'],
      );
      expect(
        store.map['FA_KEY_API_KIMI_COM_KIMI_IRA'],
        'sk-ira-secret-789',
      );
      expect(registry.find('kimi_ira')!.keyNotPersisted, isFalse);
      expect(io.out.toString(), isNot(contains('sk-ira-secret-789')));
    });
  });
}
