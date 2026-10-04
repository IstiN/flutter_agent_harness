@TestOn('vm')
@Tags(['integration', 'llm'])
@Timeout(Duration(minutes: 5))
/// gh-760 AC1 (live half) + gh-1199 AC3: a persisted `chatgpt-codex`
/// provider exactly as the app writes it (its default
/// `https://chatgpt.com/backend-api/codex` endpoint) must get the boot
/// PAST the key gate and into the provider call — never the old crash
/// signature (uncaught `ConfigException` + crash.log).
///
/// This leg is the only one in the gh-760 family that touches the real
/// wire: the injected `CHATGPT_OAUTH_CREDENTIALS` is a DUMMY blob, so the
/// endpoint answers 401 and the assertions are about the BOOT (no
/// missing-key refusal, no crash) — but network reachability of
/// chatgpt.com is load-bearing, which is exactly the class gh-1199 evicts
/// from the deterministic gate. Tagged `integration` + `llm`: it runs in
/// the tag-only provider-smoke job and nightly (supervised) and is
/// excluded from every per-PR leg via `--exclude-tags llm` /
/// shard_files.py `--exclude-tag llm`. The deterministic twin of this
/// test (the pair-guard leg on the loopback mock) lives in
/// poisoned_provider_boot_test.dart.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'fa_cube_headless_helper.dart';

void main() {
  group('gh-760 AC1 live-wire codex boot', () {
    late Directory tempHome;
    late Directory workspace;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('fa_gh760_live_home_');
      workspace = Directory.systemTemp.createTempSync('fa_gh760_live_ws_');
    });

    tearDown(() {
      tempHome.deleteSync(recursive: true);
      workspace.deleteSync(recursive: true);
    });

    test('persisted chatgpt-codex with its default endpoint passes the '
        'key gate and reaches the provider call', () async {
      // baseUrl = the codex endpoint itself (what /provider chatgpt
      // writes): the pair is servable, the env creds resolve — the boot
      // gets PAST the key gate into the provider call (which fails on the
      // real wire; CI has no valid OAuth account). The URL must be written
      // explicitly: loadCliConfig defaults an absent baseUrl to the
      // openrouter endpoint, which the pair guard would reject.
      File('${tempHome.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''
provider: chatgpt-codex
model: gpt-5-codex
baseUrl: https://chatgpt.com/backend-api/codex
mode: code
approvalMode: yolo
''');

      final result = await runFaHeadlessRaw(
        workspace: workspace,
        prompt: 'say something',
        env: {'HOME': tempHome.path},
        extraEnv: const {'CHATGPT_OAUTH_CREDENTIALS': 'dummy-creds'},
      );

      // The key gate PASSED (the injected creds resolved): neither the
      // missing-key refusal nor any degrade warning fired, and there is
      // no construction-time crash.
      expect(result.stderr, isNot(contains('missing API key')));
      expect(result.stderr, isNot(contains('unknown provider')));
      expect(result.stderr, isNot(contains('only works with its own')));
      expect(
        File('${tempHome.path}/.fah/crash.log').existsSync(),
        isFalse,
        reason: result.output,
      );
    });
  });
}
