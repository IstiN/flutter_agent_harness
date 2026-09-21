@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
/// gh-760: a persisted provider can never brick the CLI.
///
/// Boot-level tests against the REAL headless `fah` binary
/// (`dart run bin/fah.dart`, HOME pointed at a temp dir) with config
/// fixtures poisoned the way the shared-config family can poison them:
///
/// - IT-B2/AC2 (E1/E2): `provider: from-the-future` (an id no version
///   knows) → the CLI boots with the named warning on stderr and
///   completes a turn on the fallback provider (the mock LLM).
/// - AC1: `provider: chatgpt-codex` exactly as the app writes it → the
///   boot crash signature (uncaught `ConfigException: unknown provider` +
///   crash.log) is gone; the boot reaches the provider call. The pure
///   resolution chain (UT-B1) is asserted in
///   test/model_roles/provider_catalog_coverage_test.dart.
/// - E3: a `roles:` chain referencing the unknown provider degrades to
///   the legacy single-model path with a named warning — never a boot
///   throw.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'fa_cube_headless_helper.dart';

void main() {
  group('gh-760 poisoned-provider boot (real CLI)', () {
    late Directory tempHome;
    late Directory workspace;
    late MockLlmServer server;

    setUp(() async {
      tempHome = Directory.systemTemp.createTempSync('fa_gh760_home_');
      workspace = Directory.systemTemp.createTempSync('fa_gh760_ws_');
      server = await MockLlmServer.start(
        script: MockLlmScript.parse('''
responses:
  - text: fallback reply
'''),
      );
      addTearDown(server.stop);
    });

    tearDown(() {
      tempHome.deleteSync(recursive: true);
      workspace.deleteSync(recursive: true);
    });

    void writeConfig(String body) {
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }

    Future<FaResult> runFa(
      String prompt, {
      Map<String, String> extraEnv = const {},
    }) {
      return runFaHeadlessRaw(
        workspace: workspace,
        prompt: prompt,
        env: {'HOME': tempHome.path},
        extraEnv: extraEnv,
      );
    }

    test('IT-B2/AC2: an unknown persisted provider id boots on the '
        'fallback with a named warning', () async {
      writeConfig('''
provider: from-the-future
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
''');

      final result = await runFa('say something');

      // The loud named warning: bad value, file, fallback taken.
      expect(result.exitCode, 0, reason: result.output);
      expect(
        result.stderr,
        contains('unknown provider "from-the-future"'),
        reason: result.output,
      );
      expect(result.stderr, contains('.fah/config.yaml'));
      // The headless turn completed on the FALLBACK provider.
      expect(result.stdout, contains('fallback reply'));
      // Nothing was silently rewritten (warn, don't mutate).
      expect(
        File('${tempHome.path}/.fah/config.yaml').readAsStringSync(),
        contains('from-the-future'),
      );
    });

    test('AC1: the app-written chatgpt-codex provider no longer bricks '
        'the boot', () async {
      writeConfig('''
provider: chatgpt-codex
model: gpt-5-codex
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
''');

      final result = await runFa(
        'say something',
        extraEnv: const {'CHATGPT_OAUTH_CREDENTIALS': 'dummy-creds'},
      );

      // The boot-crash signature is gone: no uncaught ConfigException, no
      // crash.log. (The turn itself cannot complete against the mock —
      // the Codex Responses wire is unmatched — but the boot MUST reach
      // the provider call instead of dying at model construction.)
      expect(result.output, isNot(contains('unknown provider')));
      expect(
        File('${tempHome.path}/.fah/crash.log').existsSync(),
        isFalse,
        reason: result.output,
      );
    });

    test('E3: a roles chain on the unknown provider degrades to the '
        'legacy model instead of failing the boot', () async {
      writeConfig('''
provider: openai-completions
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
roles:
  default:
    - provider: from-the-future
      model: future-model
''');

      final result = await runFa('say something');

      expect(result.exitCode, 0, reason: result.output);
      expect(
        result.stderr,
        contains('model roles config is unusable'),
        reason: result.output,
      );
      expect(result.stderr, contains('unknown provider'));
      expect(result.stdout, contains('fallback reply'));
    });

    test('BLOCKING regression: a persisted catalog NAME (provider: openai) '
        'boots and completes a turn on its adapter kind', () async {
      // gh-760 review blocker: the raw saved NAME reaching
      // providerStreamFunction bricked the boot with
      // `ConfigException: Unknown provider kind: openai` + crash.log.
      // The restore must land on the resolved spec's KIND.
      writeConfig('''
provider: openai
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
''');

      final result = await runFa('say something');

      expect(result.exitCode, 0, reason: result.output);
      expect(result.output, isNot(contains('Unknown provider kind')));
      expect(
        File('${tempHome.path}/.fah/crash.log').existsSync(),
        isFalse,
        reason: result.output,
      );
      // The turn completed on the resolved kind (openai-completions) via
      // the mock endpoint.
      expect(result.stdout, contains('fallback reply'));
    });

    test('BLOCKING regression: the name form of the ticket provider '
        '(provider: chatgpt) no longer bricks the boot', () async {
      writeConfig('''
provider: chatgpt
model: gpt-5-codex
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
''');

      final result = await runFa(
        'say something',
        extraEnv: const {'CHATGPT_OAUTH_CREDENTIALS': 'dummy-creds'},
      );

      expect(result.output, isNot(contains('Unknown provider kind')));
      expect(
        File('${tempHome.path}/.fah/crash.log').existsSync(),
        isFalse,
        reason: result.output,
      );
    });

    test('folder model state carrying a catalog NAME normalizes to the '
        'adapter kind instead of bricking the boot', () async {
      // The state file is CLI-written with kinds, but it lives in the
      // same shared-config family — a name-carrying file must normalize
      // (or be ignored with a warning), never leak the raw name into the
      // stream factory.
      writeConfig('''
provider: openai-completions
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
''');
      final stateDir = Directory(
        '${tempHome.path}/.fah/sessions/${encodeSessionCwd(workspace.path)}',
      )..createSync(recursive: true);
      File('${stateDir.path}/model-state.json').writeAsStringSync(
        jsonEncode({
          'providerKind': 'chatgpt',
          'modelId': 'gpt-5-codex',
          'baseUrl': null,
        }),
      );

      final result = await runFa(
        'say something',
        extraEnv: const {'CHATGPT_OAUTH_CREDENTIALS': 'dummy-creds'},
      );

      expect(result.output, isNot(contains('Unknown provider kind')));
      expect(
        File('${tempHome.path}/.fah/crash.log').existsSync(),
        isFalse,
        reason: result.output,
      );
    });
  });
}

/// [runFaHeadless] without the explicit `--provider/--base-url/--model`
/// flags: the boot must resolve everything from the (poisoned) config.
Future<FaResult> runFaHeadlessRaw({
  required Directory workspace,
  required String prompt,
  Map<String, String> env = const {},
  Map<String, String> extraEnv = const {},
  Duration timeout = const Duration(minutes: 2),
}) async {
  // Scrub the ambient environment (the developer's/CI's own provider
  // preconfig, queue, log file, and any REAL provider keys — see
  // [scrubbedChildEnv]) so the boot resolves ONLY from the poisoned
  // config fixture — an inherited FA_PROVIDER_* declaration would
  // legitimately override it and defeat the test.
  final result = await Process.run(
    'dart',
    ['run', 'bin/fah.dart', '--cwd', workspace.path, '-p', prompt],
    workingDirectory: Directory.current.path,
    environment: {
      ...scrubbedChildEnv(),
      'OPENAI_API_KEY': 'mock',
      // The ambient FA_* injection fills missing vars only — explicit
      // blanks neutralize the preconfig/queue/log-file (blank reads as
      // unset at every consumer) so the boot resolves from the fixture.
      'FA_PROVIDER_TYPE': '',
      'FA_PROVIDER_NAME': '',
      'FA_PROVIDER_CONFIG': '',
      'FA_PROVIDER_CONFIG_BASE64': '',
      'FA_PROVIDERS_QUEUE': '',
      'FA_LOG_FILE': '',
      ...env,
      ...extraEnv,
    },
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(timeout);
  return FaResult(
    stdout: result.stdout as String,
    stderr: result.stderr as String,
    exitCode: result.exitCode,
  );
}
