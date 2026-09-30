// REG guards for the issue #823 CLI quota surface (merge-blocking).
//
// REG-1 (AC9): every rendered string across metered / unmetered / unknown /
// cold badge+table states is byte-scanned for credential material — the
// fake OpenRouter key, Anthropic key, DIAL key, and a fake CodeMie SSO
// cookie must never leak into any output.
//
// REG-2: the /quota output SHAPE is pinned with structural regexes (header,
// one row per configured provider, column alignment) so an accidental
// redesign of the table fails instead of silently drifting.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';
import 'quota_cli_test.dart'
    show
        FakeOpenRouterQuotaEndpoint,
        fakeAnthropicKey,
        fakeCodeMieCookie,
        fakeDialKey,
        fakeOpenRouterKey,
        quotaCli,
        quotaEnvKeys,
        quotaTableCount,
        driveQuotaRepl;

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  // A saved CodeMie SSO entry whose session cookie lives in the secure
  // store — the quota surface must resolve it for the (dark) adapter and
  // never render it.
  (SecureKeyCache, CustomProviderRegistry) codeMieSetup() {
    final store = FakeSecureKeyStore()
      ..map['FA_KEY_CODEMIE_EXAMPLE_COM'] = fakeCodeMieCookie;
    final cache = SecureKeyCache(store);
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'codemie-example-com',
        apiType: 'openai',
        baseUrl: 'https://codemie.example.com/code-assistant-api/v1',
        modelId: 'gpt-4o',
        keyName: 'FA_KEY_CODEMIE_EXAMPLE_COM',
        authMethod: CustomProviderAuthMethod.sso,
      ),
    ]);
    return (cache, registry);
  }

  group('REG-1 credential byte-scan (AC9)', () {
    test('no credential material in any /quota or badge render', () async {
      final endpoint = FakeOpenRouterQuotaEndpoint();
      final (secureKeys, registry) = codeMieSetup();
      await secureKeys.probe();
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = quotaCli(
        env,
        io,
        fake.call,
        quotaHttpClient: endpoint.client(),
        envVarValue: quotaEnvKeys,
        quotaBadge: true,
        secureKeys: secureKeys,
        customProviders: registry,
      );

      final out = await driveQuotaRepl(cli, io, () async {
        // Badge on: the cold badge kicks the gated fetch at the first
        // prompt render.
        await waitForIt(
          () => io.out.toString().contains('[OR …]'),
          reason: 'cold badge',
        );
        io.sendLine('/quota');
        await waitForIt(
          () => quotaTableCount(io.out.toString()) >= 1,
          reason: 'cold table',
        );
        io.sendLine('/quota refresh');
        await waitForIt(
          () => io.out.toString().contains(r'$48.20/$150'),
          reason: 'refreshed table',
        );
        // Re-render the badge with fresh cache.
        io.sendLine('/stats');
        await waitForIt(
          () => io.out.toString().contains('[OR \$48/\$150]'),
          reason: 'warm badge',
        );
      });

      // All four credential materials, across every rendered string.
      for (final secret in [
        fakeOpenRouterKey,
        fakeAnthropicKey,
        fakeDialKey,
        fakeCodeMieCookie,
      ]) {
        expect(out, isNot(contains(secret)), reason: 'leaked: $secret');
      }
      // The CodeMie row resolved its cookie from the store but renders only
      // the dark reason.
      expect(
        out,
        matches(RegExp(r'^codemie\s+unknown \(.+\)$', multiLine: true)),
      );
    });
  });

  group('REG-2 /quota shape snapshot', () {
    test('header, row-per-provider, and column alignment are pinned',
        () async {
      final endpoint = FakeOpenRouterQuotaEndpoint();
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = quotaCli(
        env,
        io,
        fake.call,
        quotaHttpClient: endpoint.client(),
        envVarValue: quotaEnvKeys,
      );

      final out = await driveQuotaRepl(cli, io, () async {
        io.sendLine('/quota');
        await waitForIt(
          () => quotaTableCount(io.out.toString()) >= 1,
          reason: 'cold table',
        );
        io.sendLine('/quota');
        await waitForIt(
          () => io.out.toString().contains(r'$48.20/$150'),
          reason: 'warm table',
        );
      });

      final lines = out.split('\n');
      String? lineStartingWith(String prefix) => lines
          .where((l) => l.startsWith(prefix))
          .firstOrNull;

      // Header: exact columns, exact order. The header follows the `fa> `
      // prompt on the same line, so the match is not line-start anchored;
      // the trailing `$` still pins the exact column sequence.
      final headerMatch = RegExp(
        r'provider\s+used/limit\s+unit\s+reset\s+updated$',
        multiLine: true,
      ).firstMatch(out);
      expect(headerMatch, isNotNull, reason: 'missing table header');

      // One measured row per configured provider, cells in column order.
      // (The cold render's `…` row may precede it; pick the measured one.)
      final measured = lines
          .where((l) => l.contains(r'$48.20/$150'))
          .firstOrNull;
      expect(
        measured,
        matches(
          RegExp(r'^openrouter\s+\$48\.20/\$150\s+usd\s+\S*\s*\S+$'),
        ),
        reason: 'measured row: used/limit, unit, reset, updated',
      );

      // Unmetered row: a single cell.
      expect(
        lineStartingWith('dial'),
        matches(RegExp(r'^dial\s+unmetered$')),
      );

      // Unknown row: the one-line reason inline.
      expect(
        lineStartingWith('anthropic'),
        matches(RegExp(r'^anthropic\s+unknown \(.+\)$')),
      );

      // Column alignment: the used/limit cell starts at the header's
      // used/limit column — the fixed-width (12) name column — in both
      // lines. The `fa> ` prompt prefixes the header line only, so the
      // offsets are compared WITHIN each line.
      final headerLine = headerMatch!.group(0)!;
      expect(
        measured!.indexOf(r'$48.20/$150'),
        headerLine.indexOf('used/limit'),
        reason: 'measured row aligns with the header used/limit column',
      );

      // Cold row shape (first render, before the fetch landed).
      expect(
        lines.any((l) => RegExp(r'^openrouter\s+…$').hasMatch(l)),
        isTrue,
        reason: 'cold render shows the ellipsis row',
      );
    });
  });
}
