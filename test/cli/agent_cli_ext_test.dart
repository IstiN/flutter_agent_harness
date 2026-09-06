/// REPL-wiring tests for the JS extension surface (issue #32): the
/// background load (registry + state.tools + prompt section), reserved-name
/// collisions, the `/ext` command family, the host sinks (notes,
/// follow-ups, session end), and the hook/redaction ordering.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Monotonic handle counter for the fake commit payloads.
var _handles = 0;

Map<String, Object?> _commit({
  List<Map<String, Object?>> tools = const [],
  List<String> hooks = const [],
  List<String> slash = const [],
}) => {
  'tools': [
    for (final tool in tools) {...tool, 'handle': _handles++},
  ],
  'hooks': [
    for (final event in hooks) {'event': event, 'handle': _handles++},
  ],
  'slash': [
    for (final name in slash)
      {'name': name, 'description': 'ext command', 'handle': _handles++},
  ],
  'flows': const <Map<String, Object?>>[],
};

Future<void> _install(
  MemoryExecutionEnv env,
  String name, {
  Map<String, Object?> capabilities = const {'tools': true},
}) async {
  final store = ExtensionStore(env: env, projectDir: '/work', userDir: '/home');
  await store.write(
    name,
    files: {
      'manifest.json': jsonEncode({
        'name': name,
        'kind': 'cli-extension',
        'version': '1.0.0',
        'capabilities': capabilities,
      }),
      'main.js': '// test extension',
    },
    trust: TrustRecord(
      source: ExtTrustSource.local,
      sourceRef: '/work/.fah/js-ext/$name',
      contentSha256: 'deadbeef',
      capabilities: capabilities,
      grantedAt: DateTime.utc(2026, 1, 1),
    ),
  );
}

/// Installs an extension directory WITHOUT trust.json (tombstone state).
Future<void> _installUntrusted(MemoryExecutionEnv env, String name) async {
  await env.writeFile(
    '/work/.fah/js-ext/$name/manifest.json',
    jsonEncode({
      'name': name,
      'kind': 'cli-extension',
      'version': '1.0.0',
      'capabilities': {'tools': true},
    }),
  );
  await env.writeFile('/work/.fah/js-ext/$name/main.js', '// test extension');
}

AgentCli _cli(
  MemoryExecutionEnv env,
  FakeCliIO io, {
  JsrRuntime Function(StoredExtension ext)? runtimeFactory,
  RedactionPipeline? redactionPipeline,
}) {
  return AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      homeDir: '/home',
      extRuntimeFactory: runtimeFactory,
      redactionPipeline: redactionPipeline,
    ),
    io: io,
    streamFunction: FakeStreamFunction([textTurn('ok')]).call,
  );
}

Future<void> _waitFor(FutureOr<bool> Function() condition) async {
  for (var i = 0; i < 2000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting for condition');
}

Future<List<SessionRecord>> _sessionEntries(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  if (sessions.isEmpty) return const [];
  final session = await repo.open(sessions.first);
  return session.getEntries();
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    _handles = 0;
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test(
    'no factory: nothing loads, prompt untouched, no /ext output noise',
    () async {
      await _install(env, 'hello-ext');
      final cli = _cli(env, io);
      final run = cli.run();
      await _waitFor(() => io.out.toString().contains('fa>'));
      expect(cli.agent.state.tools.any((t) => t.name == 'ext_tool'), isFalse);
      io.sendLine('/exit');
      await run;
      expect(io.out.toString(), isNot(contains('ext:')));
    },
  );

  test(
    'initJsExtensions registers tools and composes the prompt section',
    () async {
      await _install(
        env,
        'hello-ext',
        capabilities: {
          'tools': true,
          'hooks': ['afterToolCall'],
        },
      );
      final cli = _cli(
        env,
        io,
        runtimeFactory: (ext) => FakeJsrRuntime('fake')
          ..onGlobal(
            '__extCommit',
            (args) async => _commit(
              tools: [
                {
                  'name': 'ext_tool',
                  'description': 'does a thing',
                  'tier': 'read',
                },
              ],
              hooks: ['afterToolCall'],
            ),
          ),
      );
      await _waitFor(
        () => cli.agent.state.tools.any((tool) => tool.name == 'ext_tool'),
      );
      expect(cli.systemPrompt, contains('## JS extensions'));
      expect(
        cli.systemPrompt,
        contains('- hello-ext: tools [ext_tool], hooks [afterToolCall]'),
      );
    },
  );

  test('reserved tool name collision fails the extension load', () async {
    await _install(env, 'collider');
    final cli = _cli(
      env,
      io,
      runtimeFactory: (ext) => FakeJsrRuntime('fake')
        ..onGlobal(
          '__extCommit',
          (args) async => _commit(
            tools: [
              {'name': 'read', 'description': 'shadow the builtin'},
            ],
          ),
        ),
    );
    await _waitFor(
      () => io.out.toString().contains('conflicts with reserved name'),
    );
    expect(cli.systemPrompt, isNot(contains('## JS extensions')));
  });

  test('engine unavailable prints the one-time hint line', () async {
    await _install(env, 'wants-engine');
    final cli = _cli(
      env,
      io,
      runtimeFactory: (ext) => throw ExtEngineUnavailableException(
        'install quickjs-ng (qjs) or set FA_QJS_BIN',
      ),
    );
    await _waitFor(
      () => io.out.toString().contains('js extensions: engine unavailable'),
    );
    expect(cli.systemPrompt, isNot(contains('## JS extensions')));
  });

  test('/ext list prints name, state, kind, tools, engine', () async {
    await _install(
      env,
      'hello-ext',
      capabilities: {
        'tools': true,
        'hooks': ['afterToolCall'],
      },
    );
    await _installUntrusted(env, 'ghost-ext');
    // Non-interactive: the untrusted ghost tombstone-skips, no prompt.
    io.isInteractive = false;
    final cli = _cli(
      env,
      io,
      runtimeFactory: (ext) => FakeJsrRuntime('fake')
        ..onGlobal(
          '__extCommit',
          (args) async => ext.name == 'hello-ext'
              ? _commit(
                  tools: [
                    {'name': 'ext_tool', 'description': 'x'},
                  ],
                  hooks: ['afterToolCall'],
                )
              : _commit(),
        ),
    );
    final run = cli.run();
    await _waitFor(
      () => cli.agent.state.tools.any((tool) => tool.name == 'ext_tool'),
    );
    io.sendLine('/ext list');
    await _waitFor(() => io.out.toString().contains('engine: fake'));
    io.sendLine('/exit');
    await run;
    final out = io.out.toString();
    expect(out, contains('hello-ext'));
    expect(out, contains('enabled'));
    expect(out, contains('untrusted')); // ghost-ext has no trust.json
    expect(out, contains('cli-extension'));
    expect(out, contains('tools: 1'));
    expect(out, contains('fake'));
  });

  test('disable live-removes tools + section; enable restores both', () async {
    await _install(env, 'hello-ext');
    final cli = _cli(
      env,
      io,
      runtimeFactory: (ext) => FakeJsrRuntime('fake')
        ..onGlobal(
          '__extCommit',
          (args) async => _commit(
            tools: [
              {'name': 'ext_tool', 'description': 'x'},
            ],
          ),
        ),
    );
    final run = cli.run();
    await _waitFor(
      () => cli.agent.state.tools.any((tool) => tool.name == 'ext_tool'),
    );
    io.sendLine('/ext disable hello-ext');
    await _waitFor(
      () => !cli.agent.state.tools.any((tool) => tool.name == 'ext_tool'),
    );
    expect(cli.systemPrompt, isNot(contains('## JS extensions')));
    io.sendLine('/ext enable hello-ext');
    await _waitFor(
      () => cli.agent.state.tools.any((tool) => tool.name == 'ext_tool'),
    );
    expect(cli.systemPrompt, contains('## JS extensions'));
    io.sendLine('/exit');
    await run;
  });

  test('/ext audit prints the trust record', () async {
    await _install(env, 'hello-ext');
    final cli = _cli(
      env,
      io,
      runtimeFactory: (ext) =>
          FakeJsrRuntime('fake')
            ..onGlobal('__extCommit', (args) async => _commit()),
    );
    final run = cli.run();
    await _waitFor(() => io.out.toString().contains('fa>'));
    io.sendLine('/ext audit hello-ext');
    await _waitFor(() => io.out.toString().contains('trust source: local'));
    io.sendLine('/exit');
    await run;
    final out = io.out.toString();
    expect(out, contains('content sha256: deadbeef'));
    expect(out, contains('granted at: 2026-01-01'));
  });

  test('appendNote bridge lands an ext_note custom message record', () async {
    await _install(env, 'hello-ext');
    FakeJsrRuntime? runtime;
    final cli = _cli(
      env,
      io,
      runtimeFactory: (ext) {
        runtime = FakeJsrRuntime('fake')
          ..onGlobal('__extCommit', (args) async => _commit(slash: ['note-me']))
          ..onGlobal('__extInvoke', (args) async {
            await runtime!.bridges!('session.appendNote', {
              'text': 'hello from ext',
            });
            return null;
          });
        return runtime!;
      },
    );
    final run = cli.run();
    await _waitFor(() => runtime != null && runtime!.bridges != null);
    io.sendLine('/note-me');
    await _waitFor(() async {
      final entries = await _sessionEntries(env);
      return entries.whereType<CustomMessageRecord>().any(
        (record) =>
            record.customType == 'ext_note' &&
            record.content == 'hello from ext',
      );
    });
    io.sendLine('/exit');
    await run;
  });

  test('follow-up bridge enqueues an agent follow-up at session end', () async {
    await _install(env, 'hello-ext');
    FakeJsrRuntime? runtime;
    final cli = _cli(
      env,
      io,
      runtimeFactory: (ext) {
        runtime = FakeJsrRuntime('fake')
          ..onGlobal('__extCommit', (args) async => _commit(slash: ['wake-me']))
          ..onGlobal('__extInvoke', (args) async {
            await runtime!.bridges!('session.enqueueFollowUp', {
              'text': 'run me again',
            });
            return null;
          });
        return runtime!;
      },
    );
    final run = cli.run();
    await _waitFor(() => runtime != null && runtime!.bridges != null);
    io.sendLine('/wake-me');
    // Delivery happens at sessionEnd: the host drains its queue through
    // onFollowUp, which enqueues on the agent for the next run.
    io.sendLine('/exit');
    await run;
    expect(cli.agent.hasQueuedMessages(), isTrue);
  });

  test('sessionEnd fires the onSessionEnd hook at teardown', () async {
    await _install(
      env,
      'hello-ext',
      capabilities: {
        'tools': true,
        'hooks': ['onSessionEnd'],
      },
    );
    var ended = false;
    final cli = _cli(
      env,
      io,
      runtimeFactory: (ext) => FakeJsrRuntime('fake')
        ..onGlobal(
          '__extCommit',
          (args) async => _commit(hooks: ['onSessionEnd']),
        )
        ..onGlobal('__extInvoke', (args) async {
          ended = true;
          return null;
        }),
    );
    final run = cli.run();
    await _waitFor(() => io.out.toString().contains('fa>'));
    io.sendLine('/exit');
    await run;
    expect(ended, isTrue);
  });

  test(
    'JS hooks run after redaction; appends are redacted a second time',
    () async {
      const secret = 'sk-test-secret-123';
      final pipeline = RedactionPipeline(registeredSecrets: [secret]);
      await _install(
        env,
        'hello-ext',
        capabilities: {
          'tools': true,
          'hooks': ['afterToolCall'],
        },
      );
      final toolHandle = _handles;
      final stream = FakeStreamFunction([
        toolTurn([const ToolCall(id: 't1', name: 'ext_tool', arguments: {})]),
        textTurn('done'),
      ]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          homeDir: '/home',
          extRuntimeFactory: (ext) => FakeJsrRuntime('fake')
            ..onGlobal(
              '__extCommit',
              (args) async => _commit(
                tools: [
                  {'name': 'ext_tool', 'description': 'x', 'tier': 'read'},
                ],
                hooks: ['afterToolCall'],
              ),
            )
            ..onGlobal('__extInvoke', (args) async {
              return args[0] == toolHandle
                  ? 'result with $secret'
                  : const {'append': 'appended $secret'};
            }),
          redactionPipeline: pipeline,
        ),
        io: io,
        streamFunction: stream.call,
      );
      final run = cli.run();
      await _waitFor(
        () => cli.agent.state.tools.any((tool) => tool.name == 'ext_tool'),
      );
      io.sendLine('call the tool');
      await _waitFor(() => stream.calls >= 2);
      await cli.waitForIdle();
      io.sendLine('/exit');
      await run;

      // The base result was redacted once by the pipeline and the JS append
      // once through ExtHostConfig.redact — the same pipeline counted both.
      expect(pipeline.stats.total, greaterThanOrEqualTo(2));
      final transcript = cli.agent.state.messages
          .map((message) => jsonEncode(message.toJson()))
          .join('\n');
      expect(transcript, isNot(contains(secret)));
    },
  );
}
