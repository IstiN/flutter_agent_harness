/// gh-2427 regression: the second DIRECT call to a tool the default
/// partition keeps out of the manifest must proceed natively after the
/// first call mounted it live.
///
/// The flake shape (issue #2427, RT1 "a second, shorter sheet fully
/// replaces the first"): two scripted `request_secret` calls in one run.
/// The tool is outside the keep-13 essential set (#2416), so the startup
/// availability apply unregisters it. The first direct call resolves
/// through the deferred-mount path (#2416 round 2) and mounts it — which
/// REMOVES it from the discoverable set — while the run's in-flight
/// context snapshot still misses it. The second direct call then died as
/// plain "Tool request_secret not found" on the round-2 resolver, the
/// second sheet never opened, and the residual test failed with no frame
/// on screen. The round-3 live-registry lookup in
/// `resolveDeferredToolForCall` (registry membership = mounted and
/// enabled) is the fix this test pins: both calls must reach the real
/// executor — two `[secret]` prompts, two grants, no not-found result —
/// exactly like the sheet flow over the PTY (see
/// `test/integration/secret_sheet_residual_test.dart` RT1).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  late FakeStreamFunction stream;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  ToolCall secretCall(String id, String name) => ToolCall(
    id: id,
    name: 'request_secret',
    arguments: {'name': name, 'reason': 'for the integration test'},
  );

  test(
    'a second direct call to a tool mounted earlier in the run executes',
    () async {
      stream = FakeStreamFunction([
        toolTurn([secretCall('tc-1', 'MY_SERVICE_TOKEN')]),
        toolTurn([secretCall('tc-2', 'OTHER_API_KEY')]),
        textTurn('settled'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      // The startup availability apply must land BEFORE the run starts:
      // request_secret is outside the keep-13 essential set, so the
      // partition unregisters it — the precondition that makes both direct
      // calls below route through the deferred resolver.
      await io.out.waitUntilContains('fa>', reason: 'boot prompt');
      await waitForIt(
        () => !cli.agent.state.tools.any((t) => t.name == 'request_secret'),
        reason: 'request_secret demoted out of the manifest',
      );
      io.sendLine('need the key');

      // Call 1: the resolver mounts request_secret live; the host asks for
      // the value in line mode and the scripted grant lets the turn proceed.
      await io.out.waitUntilContains(
        '[secret] MY_SERVICE_TOKEN needed',
        reason: 'first request_secret prompt',
      );
      io.sendLine('token-1');

      // Call 2: the flake under test. The tool left the discoverable set
      // when call 1 mounted it, and this run's context snapshot still
      // misses it — the resolver must answer from the LIVE registry, not
      // the discoverable listing, or the call dies as plain not-found and
      // this second prompt never appears.
      await io.out.waitUntilContains(
        '[secret] OTHER_API_KEY needed',
        reason: 'second request_secret prompt (remount path)',
      );
      io.sendLine('token-2');

      await io.out.waitUntilContains('settled', reason: 'final text turn');
      expect(stream.calls, 3);
      final results = stream.contexts[2].messages
          .whereType<ToolResultMessage>();
      final second = results.last.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join();
      expect(
        second,
        contains('Secret OTHER_API_KEY is available as'),
        reason: 'the second direct call must execute natively after the mount',
      );
      expect(second, isNot(contains('not found')));

      io.sendLine('/exit');
      await run;
    },
  );
}
