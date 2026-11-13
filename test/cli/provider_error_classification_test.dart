import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/provider_error_text.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A bare renderer over identity styling: the classification branches are
/// under test, not the ANSI faces.
KeyStatusRenderer _renderer() => KeyStatusRenderer(
  rolesDriven: false,
  providerKind: 'openai-completions',
  explicitToken: false,
  activeCustomName: null,
  red: (s) => s,
);

void main() {
  group('classifyProviderFailure (issue #2119 AC2)', () {
    test('content_filter finish_reason renders category, endpoint and ONE '
        'recovery', () {
      final c = classifyProviderFailure(
        'Provider finish_reason: content_filter',
        provider: 'openai',
        model: 'gpt-4o-mini',
      );
      expect(c.category, ProviderErrorCategory.contentFilter);
      expect(c.consoleLine, startsWith('error: content filter:'));
      expect(
        c.consoleLine,
        contains('(openai/gpt-4o-mini)'),
        reason: 'the line names the provider/model',
      );
      expect(
        c.consoleLine,
        contains('rephrase the request or switch models'),
        reason: 'exactly one matching recovery action',
      );
      // The raw dump is demoted out of the console line.
      expect(c.consoleLine, isNot(contains('finish_reason')));
    });

    test('the whole terminal finish_reason family classifies as content '
        'filter', () {
      for (final reason in [
        'content_policy_violation',
        'moderation_blocked',
        'refusal',
      ]) {
        final c = classifyProviderFailure('Provider finish_reason: $reason');
        expect(c.category, ProviderErrorCategory.contentFilter, reason: reason);
      }
    });

    test('rate limit renders the quota category with a Retry-After hint '
        'when the text carries one', () {
      final c = classifyProviderFailure(
        '429: rate limit exceeded, please try again later — retry after 12 seconds',
      );
      expect(c.category, ProviderErrorCategory.rateLimit);
      expect(c.consoleLine, startsWith('error: rate limit:'));
      expect(c.consoleLine, contains('retry after ~12s'));
    });

    test('rate limit without a Retry-After hint claims no time', () {
      final c = classifyProviderFailure('429: too many requests');
      expect(c.category, ProviderErrorCategory.rateLimit);
      expect(c.consoleLine, isNot(contains('retry after ~')));
    });

    test('transient finish_reason network_error classifies as network', () {
      final c = classifyProviderFailure(
        'Provider finish_reason: network_error',
        provider: 'openai',
        model: 'gpt-4o-mini',
      );
      expect(c.category, ProviderErrorCategory.network);
      expect(c.consoleLine, startsWith('error: network:'));
    });

    test('transport wordings classify as network', () {
      final c = classifyProviderFailure('502: gateway time-out');
      expect(c.category, ProviderErrorCategory.network);
    });

    test('idle-watchdog stall wording classifies as stall (the gh-1395 '
        'taxonomy, reused)', () {
      final c = classifyProviderFailure(
        'provider stream idle: no events for 300s (stream idle timeout)',
      );
      expect(c.category, ProviderErrorCategory.stall);
      // No eventsSeen at the render site: an idle-watchdog wording lands
      // as the first-byte class of the gh-1395 taxonomy.
      expect(c.consoleLine, contains('first-byte stall'));
      expect(
        c.consoleLine,
        contains('/restart starts a fresh run, esc aborts'),
      );
    });

    test('UNKNOWN finish_reason words stay unclassified passthrough — '
        'never a wrong category (issue #2119 border case)', () {
      final c = classifyProviderFailure(
        'Provider finish_reason: vendor_gibberish',
      );
      expect(c.category, ProviderErrorCategory.unclassified);
      expect(c.consoleLine, 'error: Provider finish_reason: vendor_gibberish');
    });

    test('every classified line keeps the `error: ` headless grammar '
        '(issue #2119 AC5)', () {
      final lines = [
        classifyProviderFailure('Provider finish_reason: content_filter'),
        classifyProviderFailure('429: quota exhausted'),
        classifyProviderFailure('connection reset by peer'),
        classifyProviderFailure('stalled: no bytes (stream idle timeout)'),
      ].map((c) => c.consoleLine);
      for (final line in lines) {
        expect(line, startsWith('error: '), reason: line);
        expect(line.split('\n').length, 1, reason: line);
      }
    });

    test('the dedup key is the category + compacted message: the same '
        'failure shares one key, a distinct failure gets another (AC1)', () {
      final a1 = classifyProviderFailure(
        'Provider finish_reason: content_filter',
      );
      final a2 = classifyProviderFailure(
        'Provider finish_reason: content_filter',
        provider: 'openai',
      );
      expect(a1.key, a2.key, reason: 'endpoint naming must not split the key');
      final b = classifyProviderFailure('429: quota exhausted');
      expect(a1.key, isNot(b.key));
    });

    test('auth and connection-refused keep their hints byte-identical '
        '(REG): the classifier runs AFTER those branches', () {
      // Via the renderer: an auth-shaped message that also carries
      // rate-limit wording must keep the auth hint, not classify.
      final renderer = _renderer();
      final authLine = renderer.errorLine(
        '401: rate limit exceeded — invalid api key',
        'https://api.example.test',
      );
      expect(
        authLine,
        contains('invalid api key'),
        reason: 'the auth hint branch wins over the rate-limit wording',
      );
      final refusedLine = renderer.errorLine(
        'Connection refused (os error 61)',
        'https://api.example.test:8443',
      );
      expect(refusedLine, contains('check the endpoint in ~/.fah/config.yaml'));
      expect(refusedLine, contains('--base-url'));
    });

    test('errorLine renders the classified line for a content_filter '
        'message', () {
      final renderer = _renderer();
      final line = renderer.errorLine(
        'Provider finish_reason: content_filter',
        'https://api.example.test',
        provider: 'openai',
        model: 'gpt-4o-mini',
      );
      expect(line, startsWith('error: content filter:'));
      expect(line, contains('rephrase the request or switch models'));
    });
  });

  group('context-aware stall banner (issue #2119 AC3)', () {
    late AgentCli cli;
    late MemoryExecutionEnv env;
    late FakeCliIO io;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      io = FakeCliIO();
      cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 128000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
        streamFunction: (model, context, {cancelToken}) {
          final s = AssistantMessageEventStream();
          s.end();
          return s;
        },
      );
    });

    tearDown(() async {
      await io.close();
    });

    test('without images the banner offers wait/abort/restart — no image '
        'levers', () {
      final plain = cli.stallBannerLineForTest(hasImages: false);
      expect(plain, startsWith('info: agent stalled'));
      expect(plain, contains('still waiting on the provider'));
      expect(plain, contains('/restart starts a fresh run, esc aborts'));
      expect(plain, isNot(contains('/compact')));
      expect(plain, isNot(contains('images.maxBytesPerRequest')));

      final queued = cli.stallBannerLineForTest(queued: 2, hasImages: false);
      expect(queued, startsWith('⚠ agent stalled'));
      expect(queued, contains('2 steering messages saved to the session'));
      expect(queued, contains('still waiting on the provider'));
      expect(
        queued,
        contains('/restart delivers it into a fresh run, esc aborts'),
      );
      expect(queued, isNot(contains('/compact')));
    });

    test('with images the banner keeps the historical levers byte-identical '
        '(the #1786 REG-3 shape, budgetOffer=false)', () {
      const windowNote = '';
      final plain = cli.stallBannerLineForTest(hasImages: true);
      expect(
        plain,
        'info: agent stalled — no response for 1m$windowNote. '
        '/compact (drops image data) or a lower images.maxBytesPerRequest '
        'may unstick it; /restart starts a fresh run, esc aborts',
      );
      final queued = cli.stallBannerLineForTest(
        queued: 1,
        hasImages: true,
        budgetOffer: true,
      );
      expect(
        queued,
        '⚠ agent stalled — no response for 1m. '
        '1 steering message saved to the session: /compact (drops image '
        'data) or a lower images.maxBytesPerRequest may unstick it; '
        '/restart delivers it into a fresh run, esc aborts; press b to '
        'background the running call & deliver steering now',
      );
    });
  });
}
