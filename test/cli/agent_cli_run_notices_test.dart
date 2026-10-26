import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The run-notice wiring (`[net]` retry / `[images]` drop lines) lives in
/// the `agent_cli_io.dart` size-gate split, out of reach of the full
/// `AgentCli.run` — [AgentCli.wireRunNoticesForTesting] reaches in instead.
/// Issue #312: the CI coverage ratchet counts those moved lines; these
/// tests keep them covered.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() {
    io.close();
    transientRetryNotice = null;
    operativePinNotice = null;
    imageDropReportNotice = null;
    deliverySloSink = null;
  });

  test('the transient retry notice prints a dim transcript line', () {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
    );
    cli.wireRunNoticesForTesting();

    transientRetryNotice?.call(
      1,
      3,
      const Duration(seconds: 5),
      'Connection reset by peer',
    );

    expect(
      io.out.toString(),
      contains('[net] connection lost (Connection reset by peer)'),
    );
    expect(io.out.toString(), contains('retrying in 5s (attempt 2/3)'));
  });

  test(
    'the rate-limit face classifies the FULL notice reason — wording '
    'past the 120-char display cap still reads as rate limited (gh-1602)',
    () {
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
      );
      cli.wireRunNoticesForTesting();

      // A structured JSON-ish provider render that places the rate-limit
      // wording past the display truncation point — the ladder retries it
      // under the rate-limit policy, so the face must say so.
      final longReason =
          '${'structured error payload detail; ' * 10}'
          '429 rate limit exceeded, back off and retry';
      transientRetryNotice?.call(
        1,
        1 + maxRateLimitRetries,
        const Duration(seconds: 2),
        longReason,
      );

      expect(io.out.toString(), contains('[net] rate limited'));
      expect(io.out.toString(), isNot(contains('connection lost')));
      // Truncation stays display-only: the transcript line keeps the
      // bounded first line of the reason.
      expect(io.out.toString(), contains('(structured error payload detail; '));
    },
  );

  test('the image drop report aggregates into ONE latched notice (#1889)', () {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
    );
    cli.wireRunNoticesForTesting();
    ImageDropEvent drop(int index) => ImageDropEvent(
      index: index,
      key: 'content0000$index',
      fromCurrentMessage: false,
    );
    ImageDropReport report(int count) => ImageDropReport(
      drops: [for (var i = 0; i < count; i++) drop(i)],
      cap: 20,
      modelId: testModel.id,
      currentImageCount: 0,
      registryCount: 20 + count,
      ridingCount: 20,
    );

    // 5 identical requests — the flood case: exactly ONE notice total.
    for (var i = 0; i < 5; i++) {
      imageDropReportNotice?.call(report(17));
    }
    final lines = io.out
        .toString()
        .split('\n')
        .where((l) => l.contains('[images]'))
        .toList();
    expect(lines, hasLength(1));
    expect(lines.single, contains('17 older images not sent this turn'));
    expect(lines.single, contains('(cap 20)'));
    expect(lines.single, contains('/images for details'));
    // Detail lives on the debug surface, per image per request: fa.log
    // got 5 × 17 drop events (never silent there).
    expect(cli.imageDropUx.lastReport, isNotNull);

    // A changed set → exactly one updated notice.
    io.out.clear();
    imageDropReportNotice?.call(report(18));
    expect(
      io.out.toString().split('\n').where((l) => l.contains('[images]')),
      hasLength(1),
    );

    // Same set again → silence.
    io.out.clear();
    imageDropReportNotice?.call(report(18));
    expect(io.out.toString(), isEmpty);

    // Recovery → one all-clear transition, then silence.
    io.out.clear();
    imageDropReportNotice?.call(report(0));
    expect(io.out.toString(), contains('[images] caught up'));
    io.out.clear();
    imageDropReportNotice?.call(report(0));
    expect(io.out.toString(), isEmpty);
  });

  test('a current-message drop prints the prominent warning (#1889 AC3)', () {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
    );
    cli.wireRunNoticesForTesting();

    imageDropReportNotice?.call(
      ImageDropReport(
        drops: [
          for (var i = 0; i < 5; i++)
            ImageDropEvent(
              index: i,
              key: 'attach000$i',
              fromCurrentMessage: true,
            ),
        ],
        cap: 20,
        modelId: testModel.id,
        currentImageCount: 25,
        registryCount: 25,
        ridingCount: 20,
      ),
    );
    // Prominent (not dim) and naming counts + remedy.
    expect(io.out.toString(), contains('5 of 25 attached images'));
    expect(io.out.toString(), contains('cap is 20/request'));
    expect(io.out.toString(), contains('images.maxPerRequest'));
  });

  test(
    'the text-only image drop notice prints a visible line (issue #638)',
    () {
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: io,
      );
      cli.wireRunNoticesForTesting();

      textOnlyImageDropNotice?.call(2);

      expect(io.out.toString(), contains('[images] 2 image(s) dropped'));
      expect(io.out.toString(), contains('model declared text-only'));
    },
  );

  test('the delivery SLO sink logs stages and surfaces BREACH visibly '
      '(issue #647 AC6)', () {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
    );
    cli.wireRunNoticesForTesting();
    expect(deliverySloSink, isNotNull, reason: 'the boot wires the sink');

    const breach =
        '[slo BREACH] task_send child=c1 stage=consumed elapsed=3400ms '
        '(slo 2000ms)';
    deliverySloSink?.call(breach);
    const healthy = '[slo] task_send child=c1 stage=enqueued';
    deliverySloSink?.call(healthy);

    // A breach is visible on the transcript channel (stderr in headless
    // mode); a healthy stage stays log-only — no per-send noise.
    expect(io.out.toString(), contains('[slo BREACH]'));
    expect(io.out.toString(), contains('stage=consumed elapsed=3400ms'));
    expect(io.out.toString(), isNot(contains('stage=enqueued')));
  });

  test('the skill-pin notice prints a dim transcript line (gh-1409 '
      'P4/P5/P6, review round 2)', () {
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
    );
    cli.wireRunNoticesForTesting();
    expect(
      operativePinNotice,
      isNotNull,
      reason:
          'the boot wires the pin '
          'notices',
    );

    operativePinNotice?.call(
      'skill pin restored from registry (missing from checkpoint summary): '
      '"rule one" — pinned from skill `fleet`',
    );

    expect(io.out.toString(), contains('[skills] skill pin restored'));
    expect(io.out.toString(), contains('"rule one"'));
  });
}
