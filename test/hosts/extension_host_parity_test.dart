/// Issue #1079 slice 6 — IT-5: record-level runtime parity for a
/// registered extension host (the YoClip scenario, AC9's runtime half).
///
/// Slice 4 pinned the STATIC half of AC9 (`host_extension_api_test.dart`):
/// the extension is the only delta on the wired core, the builder exposes
/// no core-behavior override point. THIS suite pins the RUNTIME half: a
/// test host wiring a CUSTOM profile and registering its own `yoclip.*`
/// tool through `HostExtensionApi` drives the same scripted session as the
/// plain CLI-profile host and the session JSONL record streams come out
/// RECORD-LEVEL IDENTICAL — same kinds, same order, same payloads (modulo
/// volatile identity: record ids, parent links, timestamps). Compaction
/// resolves through the shared host wiring (`resolveCompactionHostWiring`)
/// and fires identically on both hosts; long-term memory produces the same
/// tool outputs, the same store listing and the same store tree.
///
/// Scope note: the record stream here is what the SDK-side persistence
/// owns — `message` records appended by the host persist loop
/// (`AgentSessionManager.persistAll`, the shared plumbing every host uses)
/// plus the compaction records the shared engine appends. Host-shell
/// extras (the CLI's `model_request_summary` snapshots) are shell
/// persistence choices, not core behavior.
///
/// The parity guard is deliberately reusable and proven able to fail (the
/// final group drives a one-token divergence and watches the diff go red)
/// — a guard that cannot fail pins nothing.
///
/// Pure Dart: no `dart:io`, no network — the provider leg is a scripted
/// in-memory stream, the filesystem is [MemoryExecutionEnv].
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'openai-completions',
  provider: 'test',
  baseUrl: 'http://localhost',
  contextWindow: 8192,
  maxTokens: 1024,
);

const _systemPrompt = 'You are the shared core under parity test.';
const _compactionSettings = CompactionSettings(
  enabled: true,
  reserveTokens: 100,
  keepRecentTokens: 150,
);

/// The custom host's profile: the YoClip scenario constructs its own
/// profile (component 1 of the issue: "custom hosts construct their own")
/// with the same declared states as the CLI — same config, same ceiling.
/// A different profile NAME exercises the wire-time E6 path for custom
/// profiles (the extension must declare a state for it too).
final _yoclipProfile = HostCapabilityProfile(
  name: 'yoclip-host',
  states: cliProfile.states,
);

/// The host extension under test: the YoClip app registers its own tool.
/// `on` ONLY for the profile the yoclip host wires; `off(reason)` for
/// every built-in profile (E6 at birth, E8 elsewhere).
HostExtension _yoclipExtension() => HostExtension(
  name: 'yoclip',
  tools: [
    AgentTool(
      name: 'yoclip_cut',
      label: 'yoclip_cut',
      description: 'YoClip clip tool (the host extension scenario).',
      parameters: {
        'type': 'object',
        'properties': {
          'shape': {'type': 'string', 'description': 'The clip shape.'},
        },
        'required': ['shape'],
      },
      execute: (arguments, cancelToken, onUpdate) async =>
          ToolExecutionResult.text('cut ok: ${arguments['shape']}'),
    ),
  ],
  profileStates: {
    for (final profile in builtInProfiles.keys)
      profile: const CapabilityOffState(
        'the yoclip toolset ships with the yoclip host only',
      ),
    'yoclip-host': const CapabilityOnState(),
  },
);

// ---------------------------------------------------------------------------
// scripted provider
// ---------------------------------------------------------------------------

AssistantMessage _bare() => AssistantMessage(
  content: const [],
  api: _model.api,
  provider: _model.provider,
  model: _model.id,
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

AssistantMessage _assistant(String text, {int tokens = 0}) => AssistantMessage(
  content: [TextContent(text: text)],
  api: _model.api,
  provider: _model.provider,
  model: _model.id,
  usage: _usage(tokens),
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

Usage _usage(int totalTokens) => totalTokens == 0
    ? Usage.zero
    : Usage(
        input: totalTokens,
        output: 10,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: totalTokens,
        cost: const UsageCost(
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          total: 0,
        ),
      );

/// A scripted turn ending in tool calls (the loop executes them, then
/// issues the next request).
List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _bare();
  final partial = _assistant('').copyWith(
    content: calls,
    stopReason: StopReason.toolUse,
  );
  return [
    StartEvent(partial: empty),
    for (var i = 0; i < calls.length; i++) ...[
      ToolCallStartEvent(contentIndex: i, partial: empty),
      ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
    ],
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

/// A scripted final turn. [tokens] (when non-zero) anchors the compaction
/// estimator exactly like a provider usage report.
List<AssistantMessageEvent> _textTurn(String text, {int tokens = 0}) {
  final message = _assistant(text, tokens: tokens);
  final empty = _bare();
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: message),
    DoneEvent(reason: StopReason.stop, message: message),
  ];
}

/// Fake [StreamFunction]: replays scripted turns.
final class _ScriptedProvider {
  _ScriptedProvider(this._turns);

  final List<List<AssistantMessageEvent>> _turns;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    for (final event in _turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// The scripted session both hosts drive: identical bytes on every request.
///
/// Turn 1 writes a file through the CORE `write` tool (the JSONL tool
/// session rides the wired registry) and anchors the estimator high; turn
/// 2 re-anchors; the shared compaction wiring then fires over the
/// window-1000 wiring; turn 3 rides the compacted history.
_ScriptedProvider _coreScript({String? turn2Text}) => _ScriptedProvider([
  _toolTurn([
    ToolCall(
      id: 'call-w1',
      name: 'write',
      arguments: {
        'path': '/w/notes/runbook.md',
        'content': 'deploy checklist: step 1\n',
      },
    ),
  ]),
  _textTurn('b' * 400, tokens: 5000),
  _textTurn(turn2Text ?? 'c' * 400, tokens: 5000),
  _textTurn('Continuing after compaction.', tokens: 100),
]);

// ---------------------------------------------------------------------------
// host boot + scripted drive (the shared persistence plumbing)
// ---------------------------------------------------------------------------

final class _HostRun {
  final MemoryExecutionEnv env;
  final WiredAgentCore core;
  final AgentSessionManager manager;
  final ManagedSession managed;
  final Session session;
  final Agent agent;
  final MemoryController memory;

  _HostRun({
    required this.env,
    required this.core,
    required this.manager,
    required this.managed,
    required this.session,
    required this.agent,
    required this.memory,
  });
}

Future<_HostRun> _bootHost({
  required HostCapabilityProfile profile,
  required List<HostExtension> extensions,
  required _ScriptedProvider provider,
}) async {
  final env = MemoryExecutionEnv(cwd: '/w');
  final memory = MemoryController(
    env: env,
    userRoot: '/home/u/.fah/memory',
    onDegrade: (_) {},
  );
  final core = wireAgentCore(
    profile: profile,
    services: AgentCoreServices(
      baseEnv: env,
      sessionEnvVars: () => {},
      sandbox: const SandboxServices(),
      sessionRoot: '/sessions',
      memory: memory,
      extensions: extensions,
    ),
  );
  final stack = core.buildAgentStack(
    spec: AgentWiringSpec(model: _model, systemPrompt: _systemPrompt),
    streamFunction: provider.call,
  );
  final manager = AgentSessionManager(env: env, sessionsRoot: '/sessions');
  final managed = await manager.createSession(agentFactory: () => stack.agent);
  return _HostRun(
    env: env,
    core: core,
    manager: manager,
    managed: managed,
    session: managed.session,
    agent: stack.agent,
    memory: memory,
  );
}

/// Drives the scripted session on [host] EXACTLY like a host shell: prompt
/// → persist the new messages (`persistAll`) → prompt → persist → resolve
/// the compaction wiring through the shared host path → run the shared
/// auto-compactor → prompt → persist.
Future<void> _driveScriptedSession(_HostRun host) async {
  await host.agent.promptMessage(UserMessage.text('u1${'a' * 400}'));
  await host.manager.persistAll();
  await host.agent.promptMessage(UserMessage.text('u2${'a' * 400}'));
  await host.manager.persistAll();

  final wiring = resolveCompactionHostWiring(
    mainModel: _model,
    contextWindowCap: 1000,
    settingsOverride: _compactionSettings,
  );
  expect(wiring.window, 1000);
  final ok = await AutoCompactor(
    session: host.session,
    state: host.agent.state,
    window: wiring.window,
    settings: wiring.settings,
    summary: _fakeSummary,
    mainSummary: _fakeSummary,
    smolModel: null,
    hooks: _SilentHooks(),
  ).run();
  expect(ok, isTrue);

  // Compaction rewrote the in-memory transcript to the projected form
  // (summary + kept tail) — the session file already owns those records
  // (the summary rides its own compaction record), so the persist cursor
  // re-syncs to the compacted transcript before the next turn. A real
  // host does the same; re-appending would duplicate history.
  host.managed.persistedCount = host.agent.state.messages.length;

  await host.agent.promptMessage(UserMessage.text('Continue.'));
  await host.manager.persistAll();
}

Future<SummarizationResult> _fakeSummary(SummarizationRequest request) async =>
    SummarizationResult.success('SUMMARY: the compacted span.');

final class _SilentHooks implements AutoCompactorHooks {
  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onPass(AutoCompactorPass pass) {}

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens) {}

  @override
  void onBothRolesFailed(Object lastError) {}
}

// ---------------------------------------------------------------------------
// the record-level diff (stable across hosts; volatile identity normalized)
// ---------------------------------------------------------------------------

/// Projects a record stream into a comparable shape: kind + payload with
/// every volatile identity stripped (record ids, parent links, timestamps)
/// and every id REFERENCE translated into its file-order ordinal — two
/// structurally identical sessions compare equal no matter which short
/// random ids their storages minted.
List<Object?> _normalize(List<SessionRecord> records) {
  final ordinals = <String, int>{
    for (var i = 0; i < records.length; i++) records[i].id: i,
  };
  return [
    for (var i = 0; i < records.length; i++) _project(records[i], ordinals),
  ];
}

Object? _project(SessionRecord record, Map<String, int> ordinals) =>
    switch (record) {
      MessageRecord(:final message) => {
        'type': 'message',
        'message': _stripVolatile(message.toJson()),
      },
      CompactionRecord(
        :final summary,
        :final firstKeptEntryId,
        :final tokensBefore,
        :final details,
        :final fromHook,
      ) => {
        'type': 'compaction',
        'summary': summary,
        'firstKept': ordinals[firstKeptEntryId],
        'tokensBefore': tokensBefore,
        if (details != null) 'details': details,
        if (fromHook != null) 'fromHook': fromHook,
      },
      _ => {
        'type': record.type,
        'json': _remapIds(_stripVolatile(record.toJson()), ordinals),
      },
    };

Map<String, Object?> _stripVolatile(Map<String, Object?> json) {
  final stripped = Map<String, Object?>.of(json);
  stripped
    ..remove('timestamp')
    ..remove('id')
    ..remove('parentId');
  return stripped;
}

Map<String, Object?> _remapIds(
  Map<String, Object?> json,
  Map<String, int> ordinals,
) => {
  for (final MapEntry(key: key, value: value) in json.entries)
    key: switch (value) {
      final String id when ordinals.containsKey(id) => ordinals[id],
      final List<Object?> ids when ids.every(ordinals.containsKey) => [
        for (final id in ids) ordinals[id],
      ],
      _ => value,
    },
};

bool _recordsEqual(List<SessionRecord> a, List<SessionRecord> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].type != b[i].type) return false;
  }
  // Map literals iterate in insertion order on every Dart platform, and
  // both sides are built by the same projection — toString equality is a
  // faithful structural diff here.
  return _normalize(a).toString() == _normalize(b).toString();
}

/// Ordered kinds — the readable half of a failure message.
List<String> _kinds(List<SessionRecord> records) =>
    [for (final record in records) record.type];

/// Sorted relative paths under [root] — the structural store diff.
Future<List<String>> _storeTree(MemoryExecutionEnv fs, String root) async {
  final listing = await fs.listDir(root);
  if (listing.isErr) return const <String>[];
  final paths = <String>[];

  Future<void> walk(String dir) async {
    final children = await fs.listDir(dir);
    for (final info in children.valueOrNull ?? const <FileInfo>[]) {
      paths.add(info.path.substring(root.length + 1));
      if (info.kind == FileKind.directory) await walk(info.path);
    }
  }

  await walk(root);
  return paths..sort();
}

// ---------------------------------------------------------------------------
// the suite
// ---------------------------------------------------------------------------

void main() {
  group('IT-5 setup — the YoClip host wires through its custom profile', () {
    test('the extension wires on the custom profile and the plan is '
        'identical to the CLI host\'s', () async {
      final cli = await _bootHost(
        profile: cliProfile,
        extensions: const [],
        provider: _coreScript(),
      );
      final yoclip = await _bootHost(
        profile: _yoclipProfile,
        extensions: [_yoclipExtension()],
        provider: _coreScript(),
      );
      // E8 resolution on a custom profile: wired, not hidden.
      expect(yoclip.core.extensions, hasLength(1));
      expect(yoclip.core.extensions.single.isHidden, isFalse);
      expect(yoclip.core.extensions.single.tools.single.name, 'yoclip_cut');
      // The extension is the ONLY registry delta (slice 4's static pin,
      // re-proved on the custom-profile path).
      expect(yoclip.core.tools.map((t) => t.name).toList(), [
        ...cli.core.tools.map((t) => t.name),
        'yoclip_cut',
      ]);
      // Same per-capability plan shape on both hosts.
      expect(
        yoclip.core.plan.entries
            .map((e) => (e.capability, e.runtimeType))
            .toList(),
        cli.core.plan.entries
            .map((e) => (e.capability, e.runtimeType))
            .toList(),
      );
    });
  });

  group('IT-5 — the registered tool is callable through the wired loop', () {
    test('yoclip_cut executes in-session and its result lands as a '
        'toolResult record', () async {
      final yoclip = await _bootHost(
        profile: _yoclipProfile,
        extensions: [_yoclipExtension()],
        provider: _ScriptedProvider([
          _toolTurn([
            ToolCall(
              id: 'call-y1',
              name: 'yoclip_cut',
              arguments: {'shape': 'rect'},
            ),
          ]),
          _textTurn('Cut.'),
        ]),
      );
      await yoclip.agent.promptMessage(UserMessage.text('cut a rect'));
      await yoclip.manager.persistAll();

      final records = await yoclip.session.getEntries();
      final results = [
        for (final record in records)
          if (record is MessageRecord &&
              record.message is ToolResultMessage &&
              (record.message as ToolResultMessage).toolName == 'yoclip_cut')
            record.message as ToolResultMessage,
      ];
      expect(results, hasLength(1));
      expect(
        results.single.content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join(),
        'cut ok: rect',
      );
    });
  });

  group('IT-5 — record-level session parity (the YoClip scenario)', () {
    test('identical scripted sessions produce identical JSONL record '
        'streams — kinds, order and payloads (modulo volatile identity)',
        () async {
      final cli = await _bootHost(
        profile: cliProfile,
        extensions: const [],
        provider: _coreScript(),
      );
      final yoclip = await _bootHost(
        profile: _yoclipProfile,
        extensions: [_yoclipExtension()],
        provider: _coreScript(),
      );

      await _driveScriptedSession(cli);
      await _driveScriptedSession(yoclip);

      final cliRecords = await cli.session.getEntries();
      final yoclipRecords = await yoclip.session.getEntries();

      // The kinds must agree first — a readable failure beats a payload
      // dump — then the full record-level diff must be equal.
      expect(_kinds(yoclipRecords), _kinds(cliRecords));
      expect(
        _recordsEqual(cliRecords, yoclipRecords),
        isTrue,
        reason: 'the extension host must be record-level identical to the '
            'CLI host on the same scripted session',
      );
    });

    test('compaction fires identically: same resolved wiring, same '
        'threshold crossing, same compaction record payload', () async {
      final cli = await _bootHost(
        profile: cliProfile,
        extensions: const [],
        provider: _coreScript(),
      );
      final yoclip = await _bootHost(
        profile: _yoclipProfile,
        extensions: [_yoclipExtension()],
        provider: _coreScript(),
      );

      // Same config through the shared host wiring — one resolution, so
      // both hosts drive the SAME window and thresholds.
      final cliWiring = resolveCompactionHostWiring(
        mainModel: _model,
        contextWindowCap: 1000,
        settingsOverride: _compactionSettings,
      );
      final yoclipWiring = resolveCompactionHostWiring(
        mainModel: _model,
        contextWindowCap: 1000,
        settingsOverride: _compactionSettings,
      );
      expect(yoclipWiring.window, cliWiring.window);
      expect(yoclipWiring.settings.enabled, cliWiring.settings.enabled);
      expect(
        yoclipWiring.settings.reserveTokens,
        cliWiring.settings.reserveTokens,
      );
      expect(
        yoclipWiring.settings.keepRecentTokens,
        cliWiring.settings.keepRecentTokens,
      );
      expect(yoclipWiring.enabled, cliWiring.enabled);

      await _driveScriptedSession(cli);
      await _driveScriptedSession(yoclip);

      final cliCompactions = [
        for (final record in await cli.session.getEntries())
          if (record is CompactionRecord) record,
      ];
      final yoclipCompactions = [
        for (final record in await yoclip.session.getEntries())
          if (record is CompactionRecord) record,
      ];
      // Both crossed the threshold exactly once, at the same token count,
      // cutting at the same record.
      expect(yoclipCompactions, hasLength(cliCompactions.length));
      expect(cliCompactions, isNotEmpty);
      expect(
        yoclipCompactions.single.tokensBefore,
        cliCompactions.single.tokensBefore,
      );
      expect(yoclipCompactions.single.summary, cliCompactions.single.summary);
    });
  });

  group('IT-5 — long-term memory parity', () {
    test('same memory tool calls produce the same outputs, the same store '
        'listing and the same store tree on both hosts', () async {
      Future<List<String>> driveMemory(_HostRun host) async {
        Future<String> call(
          String name, [
          Map<String, Object?> args = const {},
        ]) async {
          final tool = host.core.tools.singleWhere((t) => t.name == name);
          final result = await tool.execute(args, null, null);
          return result.content
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n');
        }

        return [
          await call(
            'memory_add',
            {
              'text': 'The YoClip fleet deploy checklist lives in runbook.md',
              'tags': ['deploy'],
            },
          ),
          await call('memory_add', {
            'text': 'Owner prefers terse changelogs',
            'scope': 'user',
          }),
          await call('memory_search', {'query': 'deploy checklist'}),
          await call('memory_list'),
        ];
      }

      final cli = await _bootHost(
        profile: cliProfile,
        extensions: const [],
        provider: _coreScript(),
      );
      final yoclip = await _bootHost(
        profile: _yoclipProfile,
        extensions: [_yoclipExtension()],
        provider: _coreScript(),
      );

      final cliOutputs = await driveMemory(cli);
      final yoclipOutputs = await driveMemory(yoclip);
      // Tool outputs identical — including the search answer, whatever the
      // (LLM-less, keyword-degraded) engine makes of the query.
      expect(yoclipOutputs, cliOutputs);

      final cliListing = (await cli.memory.list())
          .map((e) => '${e.scope}: ${e.displayLine}')
          .toList();
      final yoclipListing = (await yoclip.memory.list())
          .map((e) => '${e.scope}: ${e.displayLine}')
          .toList();
      expect(yoclipListing, cliListing);
      expect(cliListing, hasLength(2));

      // The store TREES agree too (paths only — file contents carry minted
      // ids/timestamps, which are the normalizer's business).
      expect(
        await _storeTree(yoclip.env, '/w/.fah/memory'),
        await _storeTree(cli.env, '/w/.fah/memory'),
      );
      expect(await _storeTree(cli.env, '/w/.fah/memory'), isNotEmpty);
      expect(
        await _storeTree(yoclip.env, '/home/u/.fah/memory'),
        await _storeTree(cli.env, '/home/u/.fah/memory'),
      );
    });
  });

  group('IT-5 — the parity guard can go red', () {
    test('a one-token divergence in the core behavior fails the diff', () async {
      final cli = await _bootHost(
        profile: cliProfile,
        extensions: const [],
        provider: _coreScript(),
      );
      // A host whose core leg diverged (here: one altered assistant
      // payload) must NOT pass the guard.
      final diverged = await _bootHost(
        profile: _yoclipProfile,
        extensions: [_yoclipExtension()],
        provider: _coreScript(turn2Text: 'c' * 399),
      );
      await _driveScriptedSession(cli);
      await _driveScriptedSession(diverged);
      expect(
        _recordsEqual(
          await cli.session.getEntries(),
          await diverged.session.getEntries(),
        ),
        isFalse,
      );
    });
  });
}
