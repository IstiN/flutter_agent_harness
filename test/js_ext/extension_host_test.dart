// Unit tests for the JS extension host (contract section 8), driven entirely
// through FakeJsrRuntime — no real JS engine involved.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/agent/agent.dart';
import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/env/execution_env.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_manifest.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_protocol.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_host.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:flutter_agent_harness/src/js_ext/trust.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

AssistantMessage _assistant() => AssistantMessage(
  content: const [],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

Agent _agent() => Agent(
  streamFunction: (model, context, {cancelToken}) =>
      throw UnimplementedError('not used in host tests'),
  toolExecutor: (toolCall, cancelToken, onUpdate) async =>
      ToolExecutionResult.text(''),
);

Future<void> _seedExt(
  ExecutionEnv env,
  String name, {
  Map<String, dynamic> capabilities = const {},
  List<String>? platforms,
  bool trusted = true,
  String scope = 'project',
}) async {
  final dir = scope == 'project'
      ? '/proj/.fah/js-ext/$name'
      : '/home/.fah/js-ext/$name';
  final manifest = <String, dynamic>{
    'name': name,
    'version': '1.0.0',
    'platforms': ?platforms,
    'capabilities': capabilities,
  };
  (await env.writeFile(
    '$dir/manifest.json',
    jsonEncode(manifest),
  )).getOrThrow();
  (await env.writeFile('$dir/main.js', '// main: $name')).getOrThrow();
  if (trusted) {
    (await env.writeFile(
      '$dir/trust.json',
      jsonEncode(
        TrustRecord(
          source: ExtTrustSource.local,
          sourceRef: dir,
          contentSha256: 'f' * 64,
          capabilities: const {},
          grantedAt: DateTime.utc(2026),
        ).toJson(),
      ),
    )).getOrThrow();
  }
}

Map<String, dynamic> _tool(int handle, String name, {String tier = 'exec'}) => {
  'name': name,
  'description': 'd',
  'parameters': <String, dynamic>{},
  'tier': tier,
  'handle': handle,
};

Map<String, dynamic> _hook(String event, int handle) => {
  'event': event,
  'handle': handle,
};

Map<String, dynamic> _slash(String name, int handle) => {
  'name': name,
  'description': 'd',
  'handle': handle,
};

Map<String, dynamic> _flow(String id, int handle) => {
  'id': id,
  'title': id,
  'description': 'd',
  'fields': [
    {'name': 'apiKey', 'label': 'Key', 'secret': true},
  ],
  'handle': handle,
};

Map<String, dynamic> _commit({
  List<Map<String, dynamic>> tools = const [],
  List<Map<String, dynamic>> hooks = const [],
  List<Map<String, dynamic>> slash = const [],
  List<Map<String, dynamic>> flows = const [],
}) => {'tools': tools, 'hooks': hooks, 'slash': slash, 'flows': flows};

/// Per-extension fake engines with a scripted commit payload and a test
/// provided `__extInvoke` dispatcher.
final class _Engines {
  _Engines(this.commits, {this.onInvoke});

  final Map<String, Map<String, dynamic>> commits;
  final Object? Function(String ext, int handle, Object? payload)? onInvoke;
  final Map<String, FakeJsrRuntime> byExt = {};

  JsrRuntime factory(StoredExtension ext) {
    final runtime = FakeJsrRuntime('fake');
    byExt[ext.name] = runtime;
    runtime.onGlobal(
      ExtJsGlobals.commit,
      (_) async => commits[ext.name] ?? const <String, dynamic>{},
    );
    runtime.onGlobal(ExtJsGlobals.invoke, (args) async {
      return onInvoke!(ext.name, args[0]! as int, args[1]);
    });
    return runtime;
  }
}

final class _RecordingShell implements Shell {
  final List<String> commands = [];

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    return Ok(ShellExecResult(stdout: 'shell-out', stderr: '', exitCode: 0));
  }
}

/// [MemoryExecutionEnv] cannot take a custom shell (private ctor param), so
/// the tests delegate to it behind [ExecutionEnv] with an injected [Shell].
final class _ShellEnv implements ExecutionEnv {
  _ShellEnv({this.cwd = '/proj', this.shell = const UnavailableShell()})
    : _fs = MemoryFileSystem(cwd: cwd);

  @override
  final String cwd;
  final MemoryFileSystem _fs;
  final Shell shell;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _fs.absolutePath(path);
  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _fs.joinPath(parts);
  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _fs.readTextFile(path);
  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _fs.readBinaryFile(path);
  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _fs.readTextLines(path, maxLines: maxLines);
  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _fs.writeBinaryFile(path, content);
  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _fs.writeFile(path, content);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _fs.appendFile(path, content);
  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _fs.fileInfo(path);
  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _fs.listDir(path);
  @override
  Future<Result<bool, FileError>> exists(String path) => _fs.exists(path);
  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _fs.createDir(path, recursive: recursive);
  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _fs.remove(path, recursive: recursive, force: force);
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => shell.exec(command, options: options);
}

Future<ExecutionEnv> _env({Shell? shell}) async {
  return _ShellEnv(shell: shell ?? const UnavailableShell());
}

JsExtensionHost _host(
  ExecutionEnv env,
  _Engines engines, {
  ExtHostConfig config = const ExtHostConfig(),
}) {
  return JsExtensionHost(
    env: env,
    store: ExtensionStore(env: env, projectDir: '/proj', userDir: '/home'),
    runtimeFactory: engines.factory,
    bootstrapJs: '// bootstrap',
    config: config,
  );
}

void main() {
  group('loadAll', () {
    test('load + commit happy path wires tools, hooks, slash, flows', () async {
      final env = await _env();
      await _seedExt(
        env,
        'greeter',
        capabilities: {
          'tools': true,
          'menus': true,
          'hooks': ['onSessionStart', 'beforeToolCall'],
        },
      );
      final engines = _Engines({
        'greeter': _commit(
          tools: [_tool(11, 'greet', tier: 'read')],
          hooks: [_hook('onSessionStart', 12), _hook('beforeToolCall', 13)],
          slash: [_slash('greet-ext', 14)],
          flows: [_flow('pick', 15)],
        ),
      });
      final host = _host(env, engines);
      final report = await host.loadAll();

      expect(report.loaded, ['greeter']);
      expect(report.skipped, isEmpty);
      expect(report.errors, isEmpty);
      expect(host.hasExtensions, isTrue);

      final runtime = engines.byExt['greeter']!;
      expect(runtime.lastBootstrapJs, '// bootstrap');
      expect(runtime.lastMainJs, '// main: greeter');

      final tools = host.tools;
      expect(tools, hasLength(1));
      expect(tools.single.name, 'greet');
      expect(tools.single.tier, ApprovalTier.read);
      expect(host.hooksByExtension, {
        'greeter': {ExtHookEvent.sessionStart, ExtHookEvent.beforeToolCall},
      });
      expect(host.slashCommands.keys, ['greet-ext']);
      expect(host.providerFlows.keys, ['ext:greeter:pick']);

      // Tool execute routes through __extInvoke with the commit handle.
      final invoked = <Object?>[];
      // (re-dispatch: the engine was created with the static onInvoke; use a
      // fresh global to observe the call)
      runtime.onGlobal(ExtJsGlobals.invoke, (args) async {
        invoked.add(args[1]);
        return 'pong';
      });
      final result = await tools.single.execute({'who': 'world'}, null, null);
      expect((result.content.single as TextContent).text, 'pong');
      expect(invoked.single, {'who': 'world'});
    });

    test(
      'untrusted: tombstone skip without prompt, prompt denial, grant',
      () async {
        final env = await _env();
        await _seedExt(env, 'no-trust', trusted: false);
        final engines = _Engines({'no-trust': _commit()});
        final host = _host(env, engines);

        final silent = await host.loadAll();
        expect(silent.loaded, isEmpty);
        expect(silent.skipped['no-trust'], 'untrusted');

        final denied = await host.loadAll(
          trustPrompt: (request) async {
            expect(request.name, 'no-trust');
            return false;
          },
        );
        expect(denied.skipped['no-trust'], 'untrusted (prompt denied)');

        ExtTrustRequest? seen;
        final granted = await host.loadAll(
          trustPrompt: (request) async {
            seen = request;
            return true;
          },
        );
        expect(granted.loaded, ['no-trust']);
        expect(seen, isNotNull);
        expect(seen!.sourceRef, '/proj/.fah/js-ext/no-trust');
        // Session grant only: the store stays tombstoned.
        final stored = await host.store.find('no-trust');
        expect(stored!.trust, isNull);
      },
    );

    test('platform-incompatible extension never loads (E7)', () async {
      final env = await _env();
      await _seedExt(env, 'web-only', platforms: ['web']);
      final engines = _Engines({'web-only': _commit()});
      final host = _host(env, engines);

      final report = await host.loadAll(platform: ExtPlatformTag.cli);
      expect(report.loaded, isEmpty);
      expect(report.errors, isEmpty);
    });

    test('engine unavailable is a skip, not an error (E1)', () async {
      final env = await _env();
      await _seedExt(env, 'needs-engine');
      final engines = _Engines({'needs-engine': _commit()});
      final host = JsExtensionHost(
        env: env,
        store: ExtensionStore(env: env, projectDir: '/proj', userDir: '/home'),
        runtimeFactory: (ext) =>
            throw ExtEngineUnavailableException('install quickjs-ng (qjs)'),
        bootstrapJs: '// bootstrap',
      );

      final report = await host.loadAll();
      expect(report.loaded, isEmpty);
      expect(
        report.skipped['needs-engine'],
        'engine unavailable: install quickjs-ng (qjs)',
      );
      expect(report.errors, isEmpty);
      expect(engines.byExt, isEmpty);
    });

    test(
      'start failure other than engine-unavailable lands in errors',
      () async {
        final env = await _env();
        await _seedExt(env, 'boom');
        final host = JsExtensionHost(
          env: env,
          store: ExtensionStore(
            env: env,
            projectDir: '/proj',
            userDir: '/home',
          ),
          runtimeFactory: (ext) =>
              FakeJsrRuntime('fake', defaultTimeoutBehavior: 'timeout'),
          bootstrapJs: '// bootstrap',
        );

        final report = await host.loadAll();
        expect(report.loaded, isEmpty);
        expect(report.errors['boom'], contains('timed out'));
      },
    );

    test(
      'capability violations fail the extension, never register (E-cap)',
      () async {
        final env = await _env();
        await _seedExt(env, 'toolnocap');
        await _seedExt(env, 'hooknocap');
        await _seedExt(env, 'flownocap');
        final engines = _Engines({
          'toolnocap': _commit(tools: [_tool(1, 'tool1')]),
          'hooknocap': _commit(hooks: [_hook('beforeToolCall', 2)]),
          'flownocap': _commit(flows: [_flow('f', 3)]),
        });
        final host = _host(env, engines);

        final report = await host.loadAll();
        expect(report.loaded, isEmpty);
        expect(
          report.errors['toolnocap'],
          contains('capability tools not declared'),
        );
        expect(
          report.errors['hooknocap'],
          contains('not declared in capabilities'),
        );
        expect(
          report.errors['flownocap'],
          contains('capability menus not declared'),
        );
        expect(host.tools, isEmpty);
        // Failed loads release their engine.
        expect(engines.byExt.values.every((r) => r.disposed), isTrue);
      },
    );

    test('cross-extension collision fails the later extension (E4)', () async {
      final env = await _env();
      await _seedExt(env, 'first', capabilities: {'tools': true});
      await _seedExt(env, 'second', capabilities: {'tools': true});
      final engines = _Engines({
        'first': _commit(tools: [_tool(1, 'dup')]),
        'second': _commit(tools: [_tool(2, 'dup')]),
      });
      final host = _host(env, engines);

      final report = await host.loadAll();
      expect(report.loaded, ['first']);
      expect(
        report.errors['second'],
        allOf(
          contains("'dup'"),
          contains("extension 'second'"),
          contains("extension 'first'"),
        ),
      );
      expect(host.tools.single.name, 'dup');
    });

    test(
      'reserved names collide and slash namespaces collide likewise',
      () async {
        final env = await _env();
        await _seedExt(env, 'reserved', capabilities: {'tools': true});
        await _seedExt(env, 'slash-a');
        await _seedExt(env, 'slash-b');
        final engines = _Engines({
          'reserved': _commit(tools: [_tool(1, 'read')]),
          'slash-a': _commit(slash: [_slash('hello', 2)]),
          'slash-b': _commit(slash: [_slash('hello', 3)]),
        });
        final host = _host(env, engines);

        final report = await host.loadAll(reservedNames: {'read', 'compact'});
        expect(report.errors['reserved'], contains('reserved name'));
        expect(report.errors['reserved'], contains("extension 'reserved'"));
        expect(report.errors['slash-b'], contains("extension 'slash-a'"));
        expect(report.errors['slash-b'], contains("'hello'"));
        expect(host.slashCommands.keys, ['hello']);
      },
    );

    test(
      'second loadAll does not duplicate already loaded extensions',
      () async {
        final env = await _env();
        await _seedExt(env, 'once', capabilities: {'tools': true});
        final engines = _Engines({
          'once': _commit(tools: [_tool(1, 'tool')]),
        });
        // second commit registers the same tool name; without the loaded guard
        // this would self-collide.
        final host = _host(env, engines);
        expect((await host.loadAll()).loaded, ['once']);
        expect((await host.loadAll()).loaded, isEmpty);
        expect(host.tools, hasLength(1));
      },
    );
  });

  group('tool execution result shapes', () {
    test('String, {text}, {content:[...]} normalize; {error} throws', () async {
      final env = await _env();
      await _seedExt(env, 'shaper', capabilities: {'tools': true});
      final responses = <Object?>[
        'plain',
        {'text': 'shaped'},
        {'error': 'boom'},
        {
          'content': [
            {'type': 'text', 'text': 'a'},
            {'type': 'text', 'text': 'b'},
          ],
        },
      ];
      final engines = _Engines({
        'shaper': _commit(tools: [_tool(7, 'shape')]),
      }, onInvoke: (ext, handle, payload) async => responses.removeAt(0));
      final host = _host(env, engines);
      await host.loadAll();
      final tool = host.tools.single;

      final plain = await tool.execute(const {}, null, null);
      expect((plain.content.single as TextContent).text, 'plain');

      final shaped = await tool.execute(const {}, null, null);
      expect((shaped.content.single as TextContent).text, 'shaped');

      await expectLater(
        tool.execute(const {}, null, null),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'boom')),
      );

      final blocks = await tool.execute(const {}, null, null);
      expect((blocks.content.single as TextContent).text, 'a\nb');
    });

    test('tier maps read/write/exec with exec default', () async {
      final env = await _env();
      await _seedExt(env, 'tiered', capabilities: {'tools': true});
      final engines = _Engines({
        'tiered': _commit(
          tools: [
            _tool(1, 'tool_read', tier: 'read'),
            _tool(2, 'tool_write', tier: 'write'),
            _tool(3, 'tool_exec', tier: 'exec'),
            _tool(4, 'tool_default'),
          ],
        ),
      });
      final host = _host(env, engines);
      await host.loadAll();
      final tiers = {for (final t in host.tools) t.name: t.tier};
      expect(tiers, {
        'tool_read': ApprovalTier.read,
        'tool_write': ApprovalTier.write,
        'tool_exec': ApprovalTier.exec,
        'tool_default': ApprovalTier.exec,
      });
    });
  });

  group('attachHooks beforeToolCall', () {
    test('block and prompt verdicts are prefixed and block', () async {
      final env = await _env();
      await _seedExt(
        env,
        'guard',
        capabilities: {
          'hooks': ['beforeToolCall'],
        },
      );
      var verdict = <String, dynamic>{'block': true, 'reason': 'nope'};
      final engines = _Engines(
        {
          'guard': _commit(hooks: [_hook('beforeToolCall', 5)]),
        },
        onInvoke: (ext, handle, payload) async {
          expect(payload, {
            'tool': 'weather',
            'args': {'city': 'Oslo'},
          });
          return verdict;
        },
      );
      final host = _host(env, engines);
      await host.loadAll();
      final agent = _agent();
      host.attachHooks(agent);

      final hook = agent.beforeToolCall!;
      BeforeToolCallContext context() => BeforeToolCallContext(
        assistantMessage: _assistant(),
        toolCall: ToolCall(
          id: 'c1',
          name: 'weather',
          arguments: {'city': 'Oslo'},
        ),
        context: const Context(messages: []),
      );

      final blocked = await hook(context(), null);
      expect(blocked!.block, isTrue);
      expect(blocked.reason, '[ext:guard] nope');

      verdict = {'prompt': 'allow weather?'};
      final prompted = await hook(context(), null);
      expect(prompted!.block, isTrue);
      expect(
        prompted.reason,
        '[ext:guard] confirmation required: allow weather?',
      );
    });

    test('existing hook blocking denies first; JS hook never runs', () async {
      final env = await _env();
      await _seedExt(
        env,
        'guard',
        capabilities: {
          'hooks': ['beforeToolCall'],
        },
      );
      var jsCalls = 0;
      final engines = _Engines(
        {
          'guard': _commit(hooks: [_hook('beforeToolCall', 5)]),
        },
        onInvoke: (ext, handle, payload) async {
          jsCalls += 1;
          return null;
        },
      );
      final host = _host(env, engines);
      await host.loadAll();
      final agent = _agent();
      agent.beforeToolCall = (context, cancelToken) async =>
          const BeforeToolCallResult(block: true, reason: 'denied by approval');
      host.attachHooks(agent);

      final result = await agent.beforeToolCall!(
        BeforeToolCallContext(
          assistantMessage: _assistant(),
          toolCall: ToolCall(id: 'c1', name: 'weather', arguments: const {}),
          context: const Context(messages: []),
        ),
        null,
      );
      expect(result!.reason, 'denied by approval');
      expect(jsCalls, 0);
    });

    test('hook throw is logged and ignored', () async {
      final env = await _env();
      await _seedExt(
        env,
        'crasher',
        capabilities: {
          'hooks': ['beforeToolCall'],
        },
      );
      final engines = _Engines(
        {
          'crasher': _commit(hooks: [_hook('beforeToolCall', 5)]),
        },
        onInvoke: (ext, handle, payload) async {
          throw StateError('js exploded');
        },
      );
      final host = _host(env, engines);
      final logs = <String>[];
      host.onLog = logs.add;
      await host.loadAll();
      final agent = _agent();
      host.attachHooks(agent);

      final result = await agent.beforeToolCall!(
        BeforeToolCallContext(
          assistantMessage: _assistant(),
          toolCall: ToolCall(id: 'c1', name: 'weather', arguments: const {}),
          context: const Context(messages: []),
        ),
        null,
      );
      expect(result, isNull);
      expect(logs.single, contains('[ext:crasher] hook beforeToolCall failed'));
    });
  });

  group('attachHooks afterToolCall', () {
    AfterToolCallContext afterContext() => AfterToolCallContext(
      assistantMessage: _assistant(),
      toolCall: ToolCall(id: 'c1', name: 'weather', arguments: const {}),
      result: ToolExecutionResult.text('raw out'),
      isError: false,
      context: const Context(messages: []),
    );

    test('append lands redacted after the redacted base (double pass)', () async {
      final env = await _env();
      await _seedExt(
        env,
        'annotator',
        capabilities: {
          'hooks': ['afterToolCall'],
        },
      );
      final engines = _Engines(
        {
          'annotator': _commit(hooks: [_hook('afterToolCall', 6)]),
        },
        onInvoke: (ext, handle, payload) async {
          // JS sees the base the existing hook produced (first redaction pass).
          expect((payload as Map)['result'], 'BASE-MASKED');
          return {'append': 'e=sk-123'};
        },
      );
      final host = _host(
        env,
        engines,
        config: ExtHostConfig(redact: (text) => 'R[$text]'),
      );
      await host.loadAll();
      final agent = _agent();
      agent.afterToolCall = (context, cancelToken) async =>
          AfterToolCallResult(content: [TextContent(text: 'BASE-MASKED')]);
      host.attachHooks(agent);

      final result = await agent.afterToolCall!(afterContext(), null);
      expect(result!.content!.map((b) => (b as TextContent).text), [
        'BASE-MASKED',
        'R[e=sk-123]',
      ]);
      // Appending preserves the existing hook's other fields.
      expect(result.isError, isNull);
    });

    test(
      'append-only: rewrite and unknown shapes ignored, base unchanged',
      () async {
        final env = await _env();
        await _seedExt(
          env,
          'annotator',
          capabilities: {
            'hooks': ['afterToolCall'],
          },
        );
        final engines = _Engines({
          'annotator': _commit(hooks: [_hook('afterToolCall', 6)]),
        }, onInvoke: (ext, handle, payload) async => {'rewrite': 'hijack'});
        final host = _host(env, engines);
        final logs = <String>[];
        host.onLog = logs.add;
        await host.loadAll();
        final agent = _agent();
        host.attachHooks(agent);

        final result = await agent.afterToolCall!(afterContext(), null);
        expect(result, isNull); // nothing changed, loop default preserved
        expect(logs.single, contains('ignored'));
      },
    );

    test(
      'chained hooks each see the original base; appends accumulate',
      () async {
        final env = await _env();
        await _seedExt(
          env,
          'a1',
          capabilities: {
            'hooks': ['afterToolCall'],
          },
        );
        await _seedExt(
          env,
          'a2',
          capabilities: {
            'hooks': ['afterToolCall'],
          },
        );
        final seen = <Object?>[];
        final engines = _Engines(
          {
            'a1': _commit(hooks: [_hook('afterToolCall', 1)]),
            'a2': _commit(hooks: [_hook('afterToolCall', 2)]),
          },
          onInvoke: (ext, handle, payload) async {
            seen.add((payload as Map)['result']);
            return {'append': '[$ext]'};
          },
        );
        final host = _host(env, engines);
        await host.loadAll();
        final agent = _agent();
        host.attachHooks(agent);

        final result = await agent.afterToolCall!(afterContext(), null);
        expect(seen, ['raw out', 'raw out']);
        expect(result!.content!.map((b) => (b as TextContent).text), [
          'raw out',
          '[a1]',
          '[a2]',
        ]);
      },
    );
  });

  group('prepareNextTurn', () {
    test(
      'non-null JS result rejected and logged; existing result kept (E3)',
      () async {
        final env = await _env();
        await _seedExt(
          env,
          'pnt',
          capabilities: {
            'hooks': ['prepareNextTurn'],
          },
        );
        final engines = _Engines({
          'pnt': _commit(hooks: [_hook('prepareNextTurn', 8)]),
        }, onInvoke: (ext, handle, payload) async => {'context': 'hijack'});
        final host = _host(env, engines);
        final logs = <String>[];
        host.onLog = logs.add;
        await host.loadAll();
        final agent = _agent();
        host.attachHooks(agent);

        final context = NextTurnContext(
          message: _assistant(),
          toolResults: const [],
          context: const Context(messages: []),
          newMessages: const [],
        );
        final result = await agent.prepareNextTurn!(context);
        expect(result, isNull);
        expect(
          logs.single,
          contains('[ext:pnt] prepareNextTurn result rejected'),
        );

        // Last valid result (from the existing hook) is kept.
        agent.prepareNextTurn = (context) async =>
            const AgentLoopTurnUpdate(model: null);
        final kept = await agent.prepareNextTurn!(context);
        expect(kept, isA<AgentLoopTurnUpdate>());
      },
    );
  });

  group('session bridges', () {
    test('follow-up cap collapses overflow into one aggregate (E14)', () async {
      final env = await _env();
      await _seedExt(env, 'fu');
      final engines = _Engines({'fu': _commit()});
      final host = _host(
        env,
        engines,
        config: const ExtHostConfig(maxPendingFollowUps: 1),
      );
      final delivered = <String>[];
      host.onFollowUp = delivered.add;
      await host.loadAll();
      final bridges = engines.byExt['fu']!.bridges!;

      await bridges(ExtBridgeMethods.sessionEnqueueFollowUp, {'text': 'one'});
      await bridges(ExtBridgeMethods.sessionEnqueueFollowUp, {'text': 'two'});
      await host.sessionEnd();
      expect(delivered, ['[ext:fu] 2 follow-ups collapsed: one …']);
    });

    test('sessionEnd delivers pending, hook enqueues land next turn', () async {
      final env = await _env();
      await _seedExt(
        env,
        'fu',
        capabilities: {
          'hooks': ['onSessionEnd'],
        },
      );
      late final _Engines engines;
      engines = _Engines(
        {
          'fu': _commit(hooks: [_hook('onSessionEnd', 9)]),
        },
        onInvoke: (ext, handle, payload) async {
          await engines.byExt[ext]!.bridges!(
            ExtBridgeMethods.sessionEnqueueFollowUp,
            {'text': 'during-end'},
          );
          return null;
        },
      );
      final host = _host(env, engines);
      final delivered = <String>[];
      host.onFollowUp = delivered.add;
      await host.loadAll();
      final bridges = engines.byExt['fu']!.bridges!;
      await bridges(ExtBridgeMethods.sessionEnqueueFollowUp, {'text': 'early'});

      await host.sessionEnd();
      expect(delivered, ['[ext:fu] early']);

      await host.sessionEnd();
      expect(delivered, ['[ext:fu] early', '[ext:fu] during-end']);
    });

    test('appendNote and io sinks wired', () async {
      final env = await _env();
      await _seedExt(env, 'sinker');
      final engines = _Engines({'sinker': _commit()});
      final notes = <String>[];
      final writes = <String>[];
      final writeln = <String>[];
      final host = _host(env, engines);
      host
        ..onAppendNote = notes.add
        ..onIoWrite = writes.add
        ..onIoWriteln = writeln.add;
      await host.loadAll();
      final bridges = engines.byExt['sinker']!.bridges!;

      await bridges(ExtBridgeMethods.sessionAppendNote, {'text': 'noted'});
      await bridges(ExtBridgeMethods.ioWrite, {'text': 'half'});
      await bridges(ExtBridgeMethods.ioWriteln, {'text': 'line'});
      expect(notes, ['noted']);
      expect(writes, ['half']);
      expect(writeln, ['line']);
    });

    test('fs.readFile confined to cwd; escapes refused', () async {
      final env = await _env();
      await _seedExt(env, 'reader', capabilities: {'fs': true});
      await _seedExt(env, 'nocap');
      final engines = _Engines({'reader': _commit(), 'nocap': _commit()});
      final host = _host(env, engines);
      await host.loadAll();
      (await env.writeFile('/proj/notes.txt', 'hello')).getOrThrow();
      final bridges = engines.byExt['reader']!.bridges!;
      final noCapBridges = engines.byExt['nocap']!.bridges!;

      expect(
        await bridges(ExtBridgeMethods.fsReadFile, {'path': 'notes.txt'}),
        'hello',
      );
      expect(
        await bridges(ExtBridgeMethods.fsReadFile, {
          'path': '/proj/sub/../notes.txt',
        }),
        'hello',
      );
      await expectLater(
        bridges(ExtBridgeMethods.fsReadFile, {'path': '/etc/passwd'}),
        throwsA(isA<ExtBridgeUnavailableException>()),
      );
      await expectLater(
        bridges(ExtBridgeMethods.fsReadFile, {'path': '../../etc/passwd'}),
        throwsA(isA<ExtBridgeUnavailableException>()),
      );
      await expectLater(
        noCapBridges(ExtBridgeMethods.fsReadFile, {'path': 'notes.txt'}),
        throwsA(isA<ExtBridgeUnavailableException>()),
      );
    });

    test('exec.run gated by allowedCommands prefix match', () async {
      final shell = _RecordingShell();
      final env = await _env(shell: shell);
      await _seedExt(
        env,
        'runner',
        capabilities: {
          'exec': {
            'allowedCommands': ['dart'],
          },
        },
      );
      final engines = _Engines({'runner': _commit()});
      final host = _host(env, engines);
      await host.loadAll();
      final bridges = engines.byExt['runner']!.bridges!;

      await expectLater(
        bridges(ExtBridgeMethods.execRun, {
          'command': 'rm',
          'args': ['-rf'],
        }),
        throwsA(
          isA<ExtBridgeUnavailableException>().having(
            (e) => e.message,
            'message',
            'exec not allowed: rm',
          ),
        ),
      );
      expect(shell.commands, isEmpty);

      final ok = await bridges(ExtBridgeMethods.execRun, {
        'command': 'dart',
        'args': ['--version'],
      });
      expect(ok, {
        'exitCode': 0,
        'stdout': 'shell-out',
        'stderr': '',
        'timedOut': false,
      });
      expect(shell.commands.single, 'dart --version');
    });

    test(
      'keys.request never returns a value (AC10); has() reads manifest',
      () async {
        final env = await _env();
        await _seedExt(env, 'keyed', capabilities: {'keys': true, 'fs': true});
        await _seedExt(env, 'unkeyed');
        final engines = _Engines({'keyed': _commit(), 'unkeyed': _commit()});
        final host = _host(env, engines);
        await host.loadAll();
        final bridges = engines.byExt['keyed']!.bridges!;
        final unkeyed = engines.byExt['unkeyed']!.bridges!;

        expect(
          await bridges(ExtBridgeMethods.keysRequest, {'name': 'openai'}),
          {'granted': false, 'name': 'openai'},
        );
        await expectLater(
          unkeyed(ExtBridgeMethods.keysRequest, {'name': 'openai'}),
          throwsA(isA<ExtBridgeUnavailableException>()),
        );

        expect(
          await bridges(ExtBridgeMethods.has, {'capability': 'fs'}),
          isTrue,
        );
        expect(
          await bridges(ExtBridgeMethods.has, {'capability': 'network'}),
          isFalse,
        );
        expect(
          await bridges(ExtBridgeMethods.has, {'capability': 'wat'}),
          isFalse,
        );
      },
    );

    test('lifecycle hooks fire in load order; errors never escape', () async {
      final env = await _env();
      await _seedExt(
        env,
        'l1',
        capabilities: {
          'hooks': ['onSessionStart', 'onSessionEnd'],
        },
      );
      await _seedExt(
        env,
        'l2',
        capabilities: {
          'hooks': ['onSessionStart'],
        },
      );
      final fired = <String>[];
      final engines = _Engines(
        {
          'l1': _commit(
            hooks: [_hook('onSessionStart', 1), _hook('onSessionEnd', 2)],
          ),
          'l2': _commit(hooks: [_hook('onSessionStart', 3)]),
        },
        onInvoke: (ext, handle, payload) async {
          fired.add('$ext:$handle');
          throw StateError('$ext exploded');
        },
      );
      final host = _host(env, engines);
      final logs = <String>[];
      host.onLog = logs.add;
      await host.loadAll();

      await host.sessionStart();
      expect(fired, hasLength(2));
      await host.sessionEnd();
      expect(fired, hasLength(3));
      expect(
        logs.where((l) => l.contains('hook sessionStart failed')),
        isNotEmpty,
      );
      expect(
        logs.where((l) => l.contains('hook sessionEnd failed')),
        isNotEmpty,
      );
    });
  });

  group('enable/disable (E9)', () {
    test(
      'disable detaches registrations synchronously, enable restores',
      () async {
        final env = await _env();
        await _seedExt(
          env,
          'switchable',
          capabilities: {
            'tools': true,
            'hooks': ['beforeToolCall'],
          },
        );
        var jsCalls = 0;
        final engines = _Engines(
          {
            'switchable': _commit(
              tools: [_tool(1, 'ping')],
              hooks: [_hook('beforeToolCall', 2)],
              slash: [_slash('p', 3)],
            ),
          },
          onInvoke: (ext, handle, payload) async {
            jsCalls += 1;
            return null;
          },
        );
        final host = _host(env, engines);
        final syncs = <(List<String>, List<String>)>[];
        host.setToolSyncCallbacks(
          syncTools: (add, remove) =>
              syncs.add(([for (final t in add) t.name], remove)),
          rebuildPrompt: () {},
        );
        await host.loadAll();
        final agent = _agent();
        host.attachHooks(agent);

        await host.disable('switchable');
        expect(syncs.single.$1, isEmpty);
        expect(syncs.single.$2, ['ping']);
        expect(host.tools, isEmpty);
        expect(host.slashCommands, isEmpty);
        expect(host.hooksByExtension, isEmpty);
        expect(host.hasExtensions, isFalse);

        final before = await agent.beforeToolCall!(
          BeforeToolCallContext(
            assistantMessage: _assistant(),
            toolCall: ToolCall(id: 'c1', name: 'ping', arguments: const {}),
            context: const Context(messages: []),
          ),
          null,
        );
        expect(before, isNull);
        expect(jsCalls, 0);

        await host.enable('switchable');
        expect(syncs.last.$1, ['ping']);
        expect(syncs.last.$2, isEmpty);
        expect(host.tools.single.name, 'ping');
        expect(host.hasExtensions, isTrue);
      },
    );

    test('unknown names throw', () async {
      final env = await _env();
      final host = _host(env, _Engines(const {}));
      await expectLater(host.disable('ghost'), throwsArgumentError);
      await expectLater(host.enable('ghost'), throwsArgumentError);
    });
  });

  test('dispose releases every engine', () async {
    final env = await _env();
    await _seedExt(env, 'd1');
    await _seedExt(env, 'd2');
    final engines = _Engines({'d1': _commit(), 'd2': _commit()});
    final host = _host(env, engines);
    await host.loadAll();
    await host.dispose();
    expect(engines.byExt.values.every((r) => r.disposed), isTrue);
    expect(host.hasExtensions, isFalse);
    expect(host.tools, isEmpty);
  });
}
