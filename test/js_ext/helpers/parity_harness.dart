/// Shared harness for the parity suites (issue #32): installs the
/// `parity-fixture` extension into an in-memory store and hands back a
/// running [JsExtensionHost], plus the small agent/context builders both the
/// fake-protocol suite and the real-engine suites use.
///
/// The runtime is injected: parity_fake_test drives a [FakeJsrRuntime]
/// (Dart mirror of main.js), integration/parity_engine_test drives a real
/// qjs subprocess evaluating the actual fixture JS. Env, store, and
/// assertions are shared, so any drift between the mirror and main.js fails
/// the engine suites.
library;

import 'package:flutter_agent_harness/src/agent/agent.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_bootstrap_js.dart';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_host.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

import '../fixtures/parity_ext/parity_contract.dart';
import 'scripted_env.dart';

/// Adapter bootstrap = transport + core (the qjs adapter's pinned
/// composition; the engine suites must run exactly what production runs).
const String parityBootstrapJs =
    '$kExtTransportStdioJs\n;\n$kExtBootstrapCoreJs';

/// Installs the fixture under [name] and loads it through a fresh
/// [JsExtensionHost] built over [runtimeFactory]. Wires the note/io sinks to
/// the optional [notes]/[ioLines] lists when given.
Future<(ScriptedShellEnv, ExtensionStore, JsExtensionHost)> installParityHost({
  required JsrRuntime Function() runtimeFactory,
  String name = 'parity-fixture',
  ScriptedShell? shell,
  String projectDir = '/proj',
  List<String>? notes,
  List<String>? ioLines,
}) async {
  final env = ScriptedShellEnv(cwd: projectDir, shell: shell);
  (await env.writeFile(
    '$projectDir/parity_data.txt',
    kParityDataContent,
  )).getOrThrow();
  final store = ExtensionStore(
    env: env,
    projectDir: projectDir,
    userDir: '/home',
  );
  final files = parityFixtureFiles(name: name);
  await store.write(name, files: files, trust: parityTrustRecord(files));
  final host =
      JsExtensionHost(
          env: env,
          store: store,
          runtimeFactory: (_) => runtimeFactory(),
          bootstrapJs: parityBootstrapJs,
        )
        ..onAppendNote = notes?.add
        ..onIoWriteln = ioLines?.add;
  final report = await host.loadAll();
  expect(report.loaded, [name], reason: 'fixture must load');
  expect(report.errors, isEmpty, reason: 'no load errors expected');
  expect(report.skipped, isEmpty);
  return (env, store, host);
}

/// Joined text of a tool result's text blocks (the host's normalized shape).
String resultText(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join('\n');

/// An [Agent] whose provider is never called (hook/hand-roll tests).
Agent testAgent() => Agent(
  streamFunction: (model, context, {cancelToken}) =>
      throw UnimplementedError('not used in this suite'),
  toolExecutor: (toolCall, cancelToken, onUpdate) async =>
      ToolExecutionResult.text(''),
);

/// A [BeforeToolCallContext] for [tool] with [args].
BeforeToolCallContext beforeContext(String tool, Map<String, dynamic> args) =>
    BeforeToolCallContext(
      assistantMessage: _assistant(),
      toolCall: ToolCall(id: 'c1', name: tool, arguments: args),
      context: const Context(messages: []),
    );

/// An [AfterToolCallContext] whose executed result is plain [resultTextValue]
/// and whose tool call carries [args] (what afterToolCall hooks receive).
AfterToolCallContext afterContext(
  String tool,
  String resultTextValue, {
  Map<String, dynamic> args = const {},
}) => AfterToolCallContext(
  assistantMessage: _assistant(),
  toolCall: ToolCall(id: 'c1', name: tool, arguments: args),
  result: ToolExecutionResult.text(resultTextValue),
  isError: false,
  context: const Context(messages: []),
);

AssistantMessage _assistant() => AssistantMessage(
  content: const [],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

/// A minimal settled [AssistantMessage] for hook contexts.
AssistantMessage assistant() => _assistant();
