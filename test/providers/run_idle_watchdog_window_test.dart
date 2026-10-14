// gh-1617: the run-idle watchdog obeys providerTimeouts — the pure
// resolution layer. The watchdog's patience derives from the SAME
// gh-1554 precedence the provider adapters already honor (entry
// override > global section > floor), the replay budget is bounded by
// an explicitly configured connect timeout (I2/AC4), and the stall
// notice threshold composes with the window (open question 1).
//
// The agent-level behavior lives in
// test/agent/run_idle_watchdog_provider_window_test.dart.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _plainModel = Model(
  id: 'm',
  api: 'openai-completions',
  provider: 'kimi',
  baseUrl: 'https://plain.test/v1',
  contextWindow: 100000,
  maxTokens: 4096,
);

Model _model(String baseUrl, {Duration? idle, Duration? connect, String? label}) =>
    Model(
      id: 'm',
      api: 'openai-completions',
      provider: 'kimi',
      baseUrl: baseUrl,
      contextWindow: 100000,
      maxTokens: 4096,
      streamIdleTimeout: idle,
      connectTimeout: connect,
      timeoutScopeLabel: label,
    );

void main() {
  late ProviderTimeoutsOverride? savedGlobal;
  late List<ProviderTuningEntry> savedEntries;

  setUp(() {
    savedGlobal = providerTimeoutsOverride;
    savedEntries = providerTuningRegistry.entries;
    providerTimeoutsOverride = null;
    providerTuningRegistry.clear();
  });

  tearDown(() {
    providerTimeoutsOverride = savedGlobal;
    providerTuningRegistry.clear();
    providerTuningRegistry.registerAll(savedEntries);
  });

  group('gh-1617 I1 — runIdleWatchdogWindow', () {
    test('AC3: nothing configured keeps the floor untouched', () {
      final window = runIdleWatchdogWindow(
        floor: defaultRunIdleTimeout,
        explicitIdle: null,
      );
      expect(window, defaultRunIdleTimeout);
    });

    test('AC1: an explicit idle above the floor raises the window', () {
      final window = runIdleWatchdogWindow(
        floor: const Duration(minutes: 8),
        explicitIdle: const Duration(seconds: 2000),
      );
      expect(window, const Duration(seconds: 2000));
    });

    test('I1 max(): an explicit idle below the floor never lowers it', () {
      final window = runIdleWatchdogWindow(
        floor: const Duration(minutes: 8),
        explicitIdle: const Duration(seconds: 30),
      );
      expect(window, const Duration(minutes: 8));
    });
  });

  group('gh-1617 I1/AC2 — explicitStreamIdleForModel precedence', () {
    test('nothing configured → null (the floor governs untouched)', () {
      expect(explicitStreamIdleForModel(_plainModel), isNull);
    });

    test('the model-scoped window (roles-chain entry) is the top layer', () {
      final resolved = explicitStreamIdleForModel(
        _model(
          'https://plain.test/v1',
          idle: const Duration(seconds: 33),
          label: 'role smol override',
        ),
      );
      expect(resolved, isNotNull);
      expect(resolved!.$1, const Duration(seconds: 33));
      expect(resolved.$2, 'role smol override');
    });

    test('a registry entry beats the global section for its URL', () {
      providerTimeoutsOverride = ProviderTimeoutsOverride(
        streamIdle: const Duration(seconds: 10),
      );
      providerTuningRegistry.register(
        name: 'llama-local',
        baseUrl: 'https://llama.test/v1',
        streamIdle: const Duration(seconds: 20),
      );
      final resolved = explicitStreamIdleForModel(
        _model('https://llama.test/v1/chat/completions'),
      );
      expect(resolved, isNotNull);
      expect(resolved!.$1, const Duration(seconds: 20));
      expect(resolved.$2, 'provider:llama-local');
    });

    test('AC2: another URL falls through to the global section', () {
      providerTimeoutsOverride = ProviderTimeoutsOverride(
        streamIdle: const Duration(seconds: 10),
      );
      providerTuningRegistry.register(
        name: 'llama-local',
        baseUrl: 'https://llama.test/v1',
        streamIdle: const Duration(seconds: 20),
      );
      final resolved = explicitStreamIdleForModel(
        _model('https://other.test/v1'),
      );
      expect(resolved, isNotNull);
      expect(resolved!.$1, const Duration(seconds: 10));
      expect(resolved.$2, 'global');
    });

    test('AC2: the entry override wins ONLY for its own entry — two '
        'models on two endpoints resolve different windows', () {
      providerTimeoutsOverride = ProviderTimeoutsOverride(
        streamIdle: const Duration(seconds: 10),
      );
      providerTuningRegistry
        ..register(
          name: 'llama-local',
          baseUrl: 'https://llama.test/v1',
          streamIdle: const Duration(seconds: 20),
        )
        ..register(
          name: 'glm-relay',
          baseUrl: 'https://glm.test/v1',
          streamIdle: const Duration(seconds: 40),
        );
      expect(
        explicitStreamIdleForModel(_model('https://llama.test/v1'))!.$1,
        const Duration(seconds: 20),
      );
      expect(
        explicitStreamIdleForModel(_model('https://glm.test/v1'))!.$1,
        const Duration(seconds: 40),
      );
      expect(
        explicitStreamIdleForModel(_model('https://other.test/v1'))!.$1,
        const Duration(seconds: 10),
      );
    });

    test('the built-in default is NOT an explicit idle — null, so the '
        'watchdog floor stays byte-for-byte (AC3)', () {
      // Even with a registry entry that declares only the connect leg:
      // the idle leg falls through every layer and stays unset.
      providerTuningRegistry.register(
        name: 'connect-only',
        baseUrl: 'https://plain.test/v1',
        connect: const Duration(seconds: 5),
      );
      expect(explicitStreamIdleForModel(_plainModel), isNull);
    });
  });

  group('gh-1617 I2/AC4 — explicitConnectForModel', () {
    test('nothing configured → null (no budget bound, AC3)', () {
      expect(explicitConnectForModel(_plainModel), isNull);
    });

    test('the model-scoped connect is the top layer', () {
      final resolved = explicitConnectForModel(
        _model(
          'https://plain.test/v1',
          connect: const Duration(seconds: 90),
          label: 'role smol override',
        ),
      );
      expect(resolved, isNotNull);
      expect(resolved!.$1, const Duration(seconds: 90));
      expect(resolved.$2, 'role smol override');
    });

    test('a registry entry supplies the budget for its URL', () {
      providerTuningRegistry.register(
        name: 'llama-local',
        baseUrl: 'https://llama.test/v1',
        connect: const Duration(seconds: 70),
      );
      final resolved = explicitConnectForModel(
        _model('https://llama.test/v1'),
      );
      expect(resolved, isNotNull);
      expect(resolved!.$1, const Duration(seconds: 70));
      expect(resolved.$2, 'provider:llama-local');
    });

    test('the 180s built-in default is never reported as a budget', () {
      // The default would bind every run (it is below most idle
      // windows) — only an EXPLICITLY configured connectTimeoutMs
      // bounds the replay budget (AC3).
      expect(explicitConnectForModel(_plainModel), isNull);
    });
  });

  group('gh-1617 AC4 — zeroByteAttemptBudget (replay budget math)', () {
    test('no connect budget → the ladder bound stands (AC3)', () {
      expect(
        zeroByteAttemptBudget(
          ladderBound: maxZeroByteWatchdogAttempts,
          idleWindow: const Duration(seconds: 2000),
          connectBudget: null,
        ),
        2,
      );
    });

    test('budget == window → the full ladder bound (AC1: one replay '
        'survives a warmup just past the window)', () {
      expect(
        zeroByteAttemptBudget(
          ladderBound: maxZeroByteWatchdogAttempts,
          idleWindow: const Duration(seconds: 2000),
          connectBudget: const Duration(seconds: 2000),
        ),
        2,
      );
    });

    test('budget < window → a single attempt (AC4: stop at the connect '
        'budget, no replay)', () {
      expect(
        zeroByteAttemptBudget(
          ladderBound: maxZeroByteWatchdogAttempts,
          idleWindow: const Duration(seconds: 2000),
          connectBudget: const Duration(seconds: 180),
        ),
        1,
      );
    });

    test('a generous budget clamps at the ladder bound (no infinite '
        'replay loop either way, I2)', () {
      expect(
        zeroByteAttemptBudget(
          ladderBound: maxZeroByteWatchdogAttempts,
          idleWindow: const Duration(seconds: 60),
          connectBudget: const Duration(hours: 1),
        ),
        2,
      );
    });

    test('the budget never drops below one attempt', () {
      expect(
        zeroByteAttemptBudget(
          ladderBound: maxZeroByteWatchdogAttempts,
          idleWindow: const Duration(hours: 1),
          connectBudget: const Duration(milliseconds: 1),
        ),
        1,
      );
    });

    test('multi-window sweep: the bound is monotone in the budget', () {
      var previous = 0;
      for (final budgetSeconds in [10, 100, 500, 1000, 2000, 4000, 8000]) {
        final bound = zeroByteAttemptBudget(
          ladderBound: maxZeroByteWatchdogAttempts,
          idleWindow: const Duration(seconds: 2000),
          connectBudget: Duration(seconds: budgetSeconds),
        );
        expect(bound, greaterThanOrEqualTo(previous));
        expect(bound, lessThanOrEqualTo(maxZeroByteWatchdogAttempts));
        previous = bound;
      }
    });
  });

  group('gh-1617 open question 1 — stallNoticeThreshold', () {
    test('a wide configured window keeps the 2m UX notice ceiling', () {
      expect(
        stallNoticeThreshold(
          noticeCeiling: const Duration(minutes: 2),
          window: const Duration(seconds: 2000),
        ),
        const Duration(minutes: 2),
      );
    });

    test('a tight window fires the notice at the window itself', () {
      expect(
        stallNoticeThreshold(
          noticeCeiling: const Duration(minutes: 2),
          window: const Duration(seconds: 45),
        ),
        const Duration(seconds: 45),
      );
    });
  });

  group('gh-1617 AC5 — describeRunIdleWindow', () {
    test('names the value and its source', () {
      expect(
        describeRunIdleWindow(const Duration(seconds: 2000), 'provider:llama'),
        contains('2000s'),
      );
      expect(
        describeRunIdleWindow(const Duration(seconds: 2000), 'provider:llama'),
        contains('provider:llama'),
      );
      expect(
        describeRunIdleWindow(const Duration(minutes: 33), 'global'),
        contains('global'),
      );
    });

    test('sub-second windows render as milliseconds — a mis-keyed window '
        'is recognizable verbatim (AC4 names config values)', () {
      expect(
        formatProviderTimeout(const Duration(milliseconds: 150)),
        '150ms',
      );
      expect(
        describeRunIdleWindow(
          const Duration(milliseconds: 150),
          'model override',
        ),
        'idle window 150ms (model override)',
      );
      expect(formatProviderTimeout(const Duration(minutes: 33)), '1980s');
    });
  });
}
