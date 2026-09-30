// IT-1..3 for issue #823: the `/quota` slash surface and the status-line
// quota badge, driven through the real REPL line loop (FakeCliIO +
// FakeStreamFunction). Quota endpoints ride MockClient through
// AgentCliConfig.quotaHttpClient — zero real network anywhere.
//
// AC4  /quota renders configured providers × used/limit/unit/reset/updated
// AC5  status badge only with `quota.badge: true` (default off)
// AC9  credential bytes never render anywhere
// E1   cold cache renders `…`/`[OR …]` without blocking
// E6   /quota refresh coalesces with an in-flight background fetch
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
// QuotaSection/saveCliConfig ride the full io.dart export (the main barrel
// shows only a subset of cli_config.dart).
import 'package:flutter_agent_harness/io.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'agent_cli_test_support.dart';

// Credential material for the AC9 byte-scan: must NEVER appear in any
// rendered output.
const fakeOpenRouterKey = 'sk-or-v1-fake9f2c7a41deadbeefcafe0123456789';
const fakeAnthropicKey = 'sk-ant-fake31337beefcafe';
const fakeDialKey = 'dial-fake-77c0ffee';
const fakeCodeMieCookie = 'codemie_access_token=fake.dead.beef;sessionid=fake';

/// The catalog openrouter model: the active provider under test.
const openRouterQuotaModel = Model(
  id: 'openai/gpt-4o-mini',
  api: 'openai-completions',
  provider: 'openrouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  contextWindow: 200000,
  maxTokens: 16384,
);

/// The scripted OpenRouter `GET /auth/key` endpoint: counts hits, can delay
/// and gate responses (E1/E6) — never touches the network.
final class FakeOpenRouterQuotaEndpoint {
  Duration delay = Duration.zero;
  Completer<void>? gate;
  int requests = 0; // received (gated or not)
  int served = 0; // responses handed out

  http.Client client() => http_testing.MockClient((request) async {
    requests++;
    final g = gate;
    if (g != null) await g.future;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    served++;
    return http.Response(
      '{"data":{"usage":48.2,"limit":150,"limit_remaining":101.8}}',
      200,
      headers: const {'content-type': 'application/json'},
    );
  });
}

/// Resolves catalog quota-interest keys: openrouter + anthropic (unknown
/// row) + dial (unmetered row); everything else unconfigured.
String? quotaEnvKeys(String name) => switch (name) {
  'OPENROUTER_API_KEY' => fakeOpenRouterKey,
  'ANTHROPIC_API_KEY' => fakeAnthropicKey,
  'DIAL_API_KEY' => fakeDialKey,
  _ => null,
};

/// The `/quota` table header count — one per rendered table. The header
/// follows the `fa> ` prompt on the same line, so the match is not
/// line-start anchored (only the exact column sequence is).
final _quotaHeader = RegExp(r'provider\s+used/limit\s+unit\s+reset\s+updated');

int quotaTableCount(String out) => _quotaHeader.allMatches(out).length;

AgentCli quotaCli(
  MemoryExecutionEnv env,
  FakeCliIO io,
  StreamFunction streamFunction, {
  http.Client? quotaHttpClient,
  String? Function(String name)? envVarValue,
  Model model = openRouterQuotaModel,
  bool quotaBadge = false,
  Duration? quotaTtl,
  SecureKeyCache? secureKeys,
  CustomProviderRegistry? customProviders,
}) => AgentCli(
  config: AgentCliConfig(
    model: model,
    apiKey: 'test-key',
    env: env,
    sessionRoot: '/sessions',
    providerKind: 'openai-completions',
    skillsAccess: SkillsAccess.granted,
    envVarValue: envVarValue,
    quotaHttpClient: quotaHttpClient,
    quotaBadge: quotaBadge,
    quotaTtl: quotaTtl,
    secureKeys: secureKeys,
    customProviders: customProviders,
  ),
  io: io,
  streamFunction: streamFunction,
);

/// Runs the REPL, lets [body] drive lines, exits cleanly, returns ALL
/// captured output for byte-scans.
Future<String> driveQuotaRepl(
  AgentCli cli,
  FakeCliIO io,
  Future<void> Function() body,
) async {
  final run = cli.run();
  await body();
  io.sendLine('/exit');
  await run;
  return io.out.toString();
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  group('quota: config section (issue #823)', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('fah-quota-config-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('parses badge + ttl and round-trips through save', () async {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('quota:\n  badge: true\n  ttl_minutes: 30\n');
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.quota, const QuotaSection(badge: true, ttlMinutes: 30));

      await saveCliConfig(tmp.path, loaded);
      final reloaded = loadCliConfig(tmp.path);
      expect(reloaded.quota.badge, isTrue);
      expect(reloaded.quota.ttlMinutes, 30);
      expect(reloaded.quota, const QuotaSection(badge: true, ttlMinutes: 30));
    });

    test('absent section means defaults; defaults are never written', () {
      expect(loadCliConfig(tmp.path).quota, const QuotaSection());
      expect(CliConfig().toYaml(), isNot(contains('quota:')));
      // An explicit ttl == default is dropped from the written file too.
      final yaml = CliConfig(quota: QuotaSection(badge: true)).toYaml();
      expect(yaml, contains('badge: true'));
      expect(yaml, isNot(contains('ttl_minutes')));
    });

    test('is strict: unknown keys and bad scalars throw', () {
      ConfigException parse(String yaml) {
        try {
          CliConfig.fromYaml(loadYaml(yaml) as YamlMap);
        } on ConfigException catch (error) {
          return error;
        }
        fail('expected ConfigException for: $yaml');
      }

      expect(parse('quota:\n  unknown: true\n').message, contains('unknown'));
      expect(parse('quota: nope\n').message, contains('must be a map'));
      expect(
        parse('quota:\n  badge: sure\n').message,
        contains('must be a boolean'),
      );
      expect(
        parse('quota:\n  ttl_minutes: 0\n').message,
        contains('positive integer'),
      );
      expect(
        parse('quota:\n  ttl_minutes: soon\n').message,
        contains('positive integer'),
      );
    });

    test('QuotaSection equality and hashCode', () {
      expect(const QuotaSection(), const QuotaSection(badge: false));
      expect(
        const QuotaSection(badge: true, ttlMinutes: 5).hashCode,
        const QuotaSection(badge: true, ttlMinutes: 5).hashCode,
      );
      expect(
        const QuotaSection(badge: true),
        isNot(const QuotaSection(badge: true, ttlMinutes: 5)),
      );
      expect(
        const QuotaSection(badge: true).toString(),
        'QuotaSection(badge: true, ttlMinutes: 15)',
      );
    });
  });

  group('IT-1 /quota table (AC4, AC9)', () {
    test(
      'renders metered/unmetered/unknown rows, cold first then fresh',
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
            reason: 'first (cold) table',
          );
          // The cold render kicked the background fetch; wait for it to land.
          await waitForIt(
            () => endpoint.served == 1,
            reason: 'peek kick fetch',
          );
          io.sendLine('/quota');
          await waitForIt(
            () => io.out.toString().contains(r'$48.20/$150'),
            reason: 'warm table',
          );
        });

        expect(quotaTableCount(out), 2, reason: 'one table per /quota');
        // Columns (AC4).
        expect(out, contains('used/limit'));
        expect(out, contains('unit'));
        expect(out, contains('reset'));
        expect(out, contains('updated'));
        // Measured row.
        expect(out, contains(r'$48.20/$150'));
        // Unmetered row (dial) and unknown row (anthropic, no adapter).
        expect(out, matches(RegExp(r'^dial\s+unmetered$', multiLine: true)));
        expect(
          out,
          matches(RegExp(r'^anthropic\s+unknown \(.+\)$', multiLine: true)),
        );
        // Cold render happened before the fetch landed (E1).
        expect(out, matches(RegExp(r'^openrouter\s+…$', multiLine: true)));
        // AC9: credential bytes never render.
        expect(out, isNot(contains(fakeOpenRouterKey)));
        expect(out, isNot(contains(fakeAnthropicKey)));
        expect(out, isNot(contains(fakeDialKey)));
      },
    );
  });

  group('IT-2 /quota refresh (AC4, E6)', () {
    test(
      'coalesces with the in-flight peek kick, re-renders per call',
      () async {
        final endpoint = FakeOpenRouterQuotaEndpoint()
          ..delay = const Duration(milliseconds: 80);
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = quotaCli(
          env,
          io,
          fake.call,
          quotaHttpClient: endpoint.client(),
          envVarValue: quotaEnvKeys,
        );

        final out = await driveQuotaRepl(cli, io, () async {
          // Cold render starts fetch A (80 ms). The refresh below coalesces
          // with A instead of hammering a second endpoint hit (E6).
          io.sendLine('/quota');
          io.sendLine('/quota refresh');
          await waitForIt(
            () =>
                endpoint.served == 1 && quotaTableCount(io.out.toString()) >= 2,
            reason: 'refresh re-render after coalesced fetch',
          );
          // Fetch A settled: this refresh fetches once more.
          io.sendLine('/quota refresh');
          await waitForIt(() => endpoint.served == 2, reason: 'second refresh');
        });

        expect(
          endpoint.requests,
          2,
          reason: 'kick+refresh coalesce to ONE hit; 3 renders, 2 hits',
        );
        expect(quotaTableCount(out), 3, reason: 'one table per command');
        expect(out, contains(r'$48.20/$150'));
      },
    );
  });

  group('IT-3 status badge (AC5, E1)', () {
    test('badge off by default — no [OR tag anywhere (AC5 negative)', () async {
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
        await waitForIt(
          () => io.out.toString().contains('/work · ctx'),
          reason: 'idle prompt with status line',
        );
      });

      expect(out, isNot(contains('[OR')));
      expect(out, isNot(contains(fakeOpenRouterKey)));
    });

    test(
      'badge on: cold [OR …] renders non-blocking, then data (AC5, E1)',
      () async {
        final endpoint = FakeOpenRouterQuotaEndpoint()
          ..gate = Completer<void>();
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = quotaCli(
          env,
          io,
          fake.call,
          quotaHttpClient: endpoint.client(),
          envVarValue: quotaEnvKeys,
          quotaBadge: true,
        );

        final out = await driveQuotaRepl(cli, io, () async {
          // The gated endpoint never answers here; the badge must still
          // render its cold form without blocking (E1).
          await waitForIt(
            () => io.out.toString().contains('[OR …]'),
            reason: 'cold badge rendered while the fetch hangs',
          );
          endpoint.gate!.complete();
          await waitForIt(
            () => endpoint.served == 1,
            reason: 'gated response delivered',
          );
          // Any next line re-renders the idle prompt with fresh cache.
          io.sendLine('/stats');
          await waitForIt(
            () => io.out.toString().contains('[OR \$48/\$150]'),
            reason: 'warm badge after re-render',
          );
        });

        expect(out, contains('[OR …]'));
        expect(out, contains('[OR \$48/\$150]'));
        expect(out, isNot(contains(fakeOpenRouterKey)));
      },
    );

    test('badge on: provider without a quota source renders no badge '
        '(review round 1)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = quotaCli(
        env,
        io,
        fake.call,
        quotaHttpClient: FakeOpenRouterQuotaEndpoint().client(),
        envVarValue: quotaEnvKeys,
        quotaBadge: true,
        model: const Model(
          id: 'claude-sonnet',
          api: 'anthropic-messages',
          provider: 'anthropic',
          baseUrl: 'https://api.anthropic.com',
          contextWindow: 200000,
          maxTokens: 8192,
        ),
      );

      final out = await driveQuotaRepl(cli, io, () async {
        await waitForIt(
          () => io.out.toString().contains('ctx '),
          reason: 'status line rendered',
        );
      });

      // No quota adapter for `anthropic`: a permanent `[AN …]` would be
      // failure noise — the badge stays silent entirely.
      expect(out, isNot(contains('[AN')));
    });
  });
}
