// Protocol-contract parity suite for the `parity-fixture` extension (issue
// #32): drives the fixture through FakeJsrRuntime (the Dart mirror of
// main.js, see fixtures/parity_ext/parity_contract.dart) over the REAL
// JsExtensionHost bridge machinery, and asserts the exact commit payload +
// tool results + hook/slash/flow/session behavior that the real-engine
// suites (test/js_ext/integration/) must reproduce structurally.
library;

import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_host.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import 'fixtures/parity_ext/parity_contract.dart';
import 'helpers/parity_harness.dart';
import 'helpers/scripted_env.dart';

void main() {
  final notes = <String>[];
  final ioLines = <String>[];

  tearDown(() {
    notes.clear();
    ioLines.clear();
  });

  /// Loads the fixture through a FakeJsrRuntime running the Dart mirror.
  Future<JsExtensionHost> fakeHost({ScriptedShell? shell}) async {
    final runtime = FakeJsrRuntime('fake');
    installParityGlobals(runtime);
    final (_, _, host) = await installParityHost(
      runtimeFactory: () => runtime,
      shell: shell,
      notes: notes,
      ioLines: ioLines,
    );
    return host;
  }

  test(
    'commit payload matches the fixture contract exactly (plus bootstrap)',
    () async {
      final runtime = FakeJsrRuntime('fake');
      installParityGlobals(runtime);
      final (_, _, host) = await installParityHost(
        runtimeFactory: () => runtime,
      );
      // The host evaluated exactly the fixture source over the shared core.
      expect(runtime.lastMainJs, kParityMainJs);
      expect(runtime.lastBootstrapJs, parityBootstrapJs);
      // `__extCommit()` returns the pinned registration payload byte-for-byte.
      final payload = await runtime.invoke('__extCommit', const []);
      expect(payload, parityCommitPayload());
      await host.dispose();
    },
  );

  test('parity_echo bridges has+fs and echoes, host-normalized text', () async {
    final host = await fakeHost();
    final tool = host.tools.singleWhere((t) => t.name == 'parity_echo');
    expect(tool.tier, ApprovalTier.read);
    expect(tool.parameters, {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
    });
    final result = await tool.execute({'text': 'hello'}, null, null);
    expect(resultText(result), parityEchoText(engineId: 'fake', text: 'hello'));
    await host.dispose();
  });

  test(
    'parity_exec runs `echo ok` through the exec bridge allowlist',
    () async {
      final shell = ScriptedShell([
        const ShellExecResult(
          stdout: kParityExecStdout,
          stderr: '',
          exitCode: 0,
        ),
      ]);
      final host = await fakeHost(shell: shell);
      final tool = host.tools.singleWhere((t) => t.name == 'parity_exec');
      expect(tool.tier, ApprovalTier.exec);
      final result = await tool.execute(const {}, null, null);
      expect(resultText(result), kParityExecResultText);
      expect(shell.commands, [kParityExecCommand]);
      await host.dispose();
    },
  );

  group('hooks (all six registered, three wired by the host)', () {
    test('beforeToolCall blocks only on args.block=yes', () async {
      final host = await fakeHost();
      final agent = testAgent();
      host.attachHooks(agent);

      final blocking = await agent.beforeToolCall!(
        beforeContext('parity_echo', {'block': 'yes', 'text': 'x'}),
        null,
      );
      expect(blocking?.block, isTrue);
      expect(blocking?.reason, '[ext:parity-fixture] $kParityBlockReason');

      final passing = await agent.beforeToolCall!(
        beforeContext('parity_echo', {'text': 'x'}),
        null,
      );
      expect(passing, isNull);
      await host.dispose();
    });

    test('afterToolCall appends to parity_echo results only', () async {
      final host = await fakeHost();
      final agent = testAgent();
      host.attachHooks(agent);

      final appended = await agent.afterToolCall!(
        afterContext('parity_echo', 'echo-body'),
        null,
      );
      expect(appended?.content?.whereType<TextContent>().map((b) => b.text), [
        'echo-body',
        kParityAppend,
      ]);

      final untouched = await agent.afterToolCall!(
        afterContext('other_tool', 'raw'),
        null,
      );
      expect(untouched, isNull);
      await host.dispose();
    });

    test(
      'prepareNextTurn returns undefined (transparent pass-through)',
      () async {
        final host = await fakeHost();
        final agent = testAgent();
        host.attachHooks(agent);
        final verdict = await agent.prepareNextTurn!(
          NextTurnContext(
            message: assistant(),
            toolResults: const [],
            context: const Context(messages: []),
            newMessages: const [],
          ),
        );
        expect(verdict, isNull);
        await host.dispose();
      },
    );
  });

  test('slash parity-slash writes its args through io.writeln', () async {
    final host = await fakeHost();
    final slash = host.slashCommands['parity-slash'];
    expect(slash, isNotNull);
    await slash!(['a', 'b']);
    expect(ioLines, [
      paritySlashLine(['a', 'b']),
    ]);
    await host.dispose();
  });

  test(
    'flow parity-flow submits the provider object (secret field kept)',
    () async {
      final host = await fakeHost();
      final entry = host.providerFlows['ext:parity-fixture:parity-flow'];
      expect(entry, isNotNull);
      expect(entry!.extension, 'parity-fixture');
      expect(entry.flow.title, 'Parity Provider');
      expect(entry.flow.fields.single.name, 'token');
      expect(entry.flow.fields.single.label, 'Token');
      expect(entry.flow.fields.single.secret, isTrue);
      final result = await entry.submit({'token': 'sk-test'});
      expect(result, parityFlowResult('sk-test'));
      await host.dispose();
    },
  );

  test('sessionStart/sessionEnd append their notes', () async {
    final host = await fakeHost();
    await host.sessionStart();
    expect(notes, [parityNote('onSessionStart')]);
    await host.sessionEnd();
    expect(notes, [parityNote('onSessionStart'), parityNote('onSessionEnd')]);
    await host.dispose();
  });
}
