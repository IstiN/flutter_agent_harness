/// Extension host (section 8 of the js-extension design): loads installed JS
/// extensions from the [ExtensionStore], drives their registration commit, and
/// wires the resulting tools, hooks, slash commands, and provider flows into a
/// running [Agent] — plus the session bridges (`session.*`, `fs.readFile`,
/// `exec.run`, `io.*`, `keys.request`, `has`) the extension calls back into.
///
/// Structured-error invariant: no exception raised by extension code ever
/// escapes to the agent loop. The only intentional escapes are throws from
/// [AgentTool.execute] (tool `{error}` results), which the loop converts into
/// error tool results by contract; every hook call, bridge call, and
/// lifecycle call is wrapped and reduced to a log line.
library;

import 'dart:async';
import 'dart:convert';

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../agent/agent_tool.dart';
import '../approval/approval.dart';
import '../env/execution_env.dart';
import '../plugins/plugin.dart';
import '../types.dart';
import 'ext_bridge.dart';
import 'ext_manifest.dart';
import 'ext_protocol.dart';
import 'extension_store.dart';
import 'jsr_runtime.dart';
import 'trust.dart';

/// A bridge call was refused by the host: the capability was never declared
/// in the manifest (fs/keys), the exec allowlist rejected the command, or the
/// host cannot serve the method here (unknown method, fs path escape).
///
/// Adapters report this to JS as an error result (`{error: message}`).
class ExtBridgeUnavailableException implements Exception {
  /// Human-readable refusal reason.
  final String message;

  /// Creates a bridge refusal.
  ExtBridgeUnavailableException(this.message);

  @override
  String toString() => message;
}

/// Tunables of [JsExtensionHost].
final class ExtHostConfig {
  /// Per-hook-call budget (all hook events). Adapters enforce it.
  final Duration hookTimeout;

  /// Per tool/slash/flow invocation budget. Adapters enforce it.
  final Duration toolTimeout;

  /// Budget for one extension's `start()` + commit fetch during [JsExtensionHost.loadAll].
  final Duration loadTimeout;

  /// Follow-ups an extension may keep pending between deliveries; overflow
  /// collapses into one aggregated entry (E14).
  final int maxPendingFollowUps;

  /// Second-pass redaction applied to text an after-hook appends to a tool
  /// result. `null` means no redaction (host without a pipeline); the agent's
  /// own `afterToolCall` hook remains the first pass for the base content.
  final String Function(String text)? redact;

  /// Creates a host config.
  const ExtHostConfig({
    this.hookTimeout = const Duration(seconds: 10),
    this.toolTimeout = const Duration(seconds: 120),
    this.loadTimeout = const Duration(seconds: 30),
    this.maxPendingFollowUps = 1,
    this.redact,
  });
}

/// Outcome of [JsExtensionHost.loadAll]: what loaded, why entries were
/// skipped (untrusted, platform, invalid manifest, engine unavailable), and
/// which extensions failed to load with a clear error.
final class ExtLoadReport {
  /// Extensions that loaded and registered.
  final List<String> loaded;

  /// Extension (or directory) name -> skip reason.
  final Map<String, String> skipped;

  /// Extension name -> load error (invalid commit, capability violation,
  /// collision, start failure).
  final Map<String, String> errors;

  /// Creates a load report.
  ExtLoadReport({
    required this.loaded,
    this.skipped = const {},
    this.errors = const {},
  });
}

/// One provider flow (menu) an extension registered, keyed
/// `'ext:<extension>:<flow.id>'` in [JsExtensionHost.providerFlows].
///
/// The host prompts [ExtFlowDef.fields] sequentially, then calls [submit]
/// with the collected `fieldName -> value` map (secrets included — the host
/// persists them, JS never sees them stored).
final class ExtFlowEntry {
  /// Extension that registered the flow.
  final String extension;

  /// The validated flow declaration.
  final ExtFlowDef flow;

  /// Runs the JS `onSubmit(values)` callback. May throw: the caller (CLI
  /// wiring) renders the failure, this is not the agent loop.
  final Future<Object?> Function(Map<String, String> values) submit;

  /// Creates a flow entry.
  ExtFlowEntry({
    required this.extension,
    required this.flow,
    required this.submit,
  });
}

/// One loaded extension: its stored form, running engine, validated commit,
/// and the registrations derived from the commit.
final class _LoadedExt {
  final StoredExtension ext;
  final JsrRuntime runtime;
  final ExtCommit commit;
  final List<AgentTool> tools;
  final Map<String, SlashCommand> slash;
  final Map<String, ExtFlowEntry> flows;
  final _FollowUps followUps = _FollowUps();
  bool enabled = true;

  _LoadedExt({
    required this.ext,
    required this.runtime,
    required this.commit,
    required this.tools,
    required this.slash,
    required this.flows,
  });
}

/// Per-extension follow-up queue with the E14 collapse: at [ExtHostConfig.maxPendingFollowUps]
/// capacity, every overflow folds the whole queue plus the new text into one
/// aggregated entry (`<n> follow-ups collapsed: <first> …`).
final class _FollowUps {
  final List<String> _pending = [];
  int _collapsed = 0;
  String? _first;

  void enqueue(String text, int cap) {
    if (_pending.length < cap) {
      _pending.add(text);
      return;
    }
    if (_collapsed == 0) {
      _collapsed = _pending.length + 1;
      _first = _pending.first;
    } else {
      _collapsed += 1;
    }
    _pending
      ..clear()
      ..add('$_collapsed follow-ups collapsed: $_first …');
  }

  List<String> drain() {
    final out = List<String>.of(_pending);
    _pending.clear();
    _collapsed = 0;
    _first = null;
    return out;
  }
}

/// The manager wiring JS extensions into the agent. Load with [loadAll],
/// expose [tools]/[slashCommands]/[providerFlows] to the wiring, attach
/// [attachHooks] to the agent, and provide the sink callbacks
/// ([onAppendNote], [onFollowUp], [onIoWrite], [onIoWriteln]).
final class JsExtensionHost {
  /// Environment backing the session bridges (cwd confinement, fs reads,
  /// exec runs).
  final ExecutionEnv env;

  /// Store the extensions are loaded from.
  final ExtensionStore store;

  /// Creates one engine per extension. Factories should report a missing
  /// engine by throwing [ExtEngineUnavailableException] (skip, not error).
  final JsrRuntime Function(StoredExtension ext) runtimeFactory;

  /// Host tunables.
  final ExtHostConfig config;

  /// Engine bootstrap source (transport + core, concatenated by the caller
  /// from `ext_bootstrap_js.dart`); passed to every [JsrRuntime.start].
  final String bootstrapJs;

  /// Diagnostic sink (hook failures, rejected results, ignored shapes).
  /// `null` drops log lines.
  void Function(String line)? onLog;

  /// `session.appendNote` sink; the host CLI persists it as a note record.
  void Function(String note)? onAppendNote;

  /// Follow-up delivery sink; text arrives prefixed `[ext:<name>] `. Fired at
  /// [sessionEnd] (and it is the wiring's job to feed these back as queued
  /// follow-up messages next turn).
  void Function(String text)? onFollowUp;

  /// `io.write` sink (no newline appended).
  void Function(String line)? onIoWrite;

  /// `io.writeln` sink (host appends the newline).
  void Function(String line)? onIoWriteln;

  void Function(List<AgentTool> add, List<String> remove)? _syncTools;
  void Function()? _rebuildPrompt;
  Set<String> _reservedNames = const {};
  final List<_LoadedExt> _loaded = [];
  final Map<String, String> _toolOwners = {};
  final Map<String, String> _slashOwners = {};

  /// Creates a host. [bootstrapJs] is the concatenated transport + core
  /// bootstrap the engines evaluate before the extension's `main.js`.
  JsExtensionHost({
    required this.env,
    required this.store,
    required this.runtimeFactory,
    required this.bootstrapJs,
    this.config = const ExtHostConfig(),
  });

  /// Loads every trusted, platform-compatible extension from the store.
  ///
  /// Untrusted extensions (no `trust.json`) go to [trustPrompt] when given —
  /// granted loads for this session only (grant persistence belongs to the
  /// installer); a `null` prompt or a denial tombstone-skips with reason
  /// `untrusted`. Platform-incompatible extensions are skipped with
  /// `unsupported here` (E7; the store pre-filters as well, this is the
  /// host-side guard). Engine failures ([ExtEngineUnavailableException]) are
  /// skips, not errors (E1); every other start/commit failure lands in
  /// [ExtLoadReport.errors].
  ///
  /// [reservedNames] are the builtin + plugin + MCP tool/slash names the
  /// wiring already owns; a collision fails the LATER extension with an
  /// error naming both sides (E4). Nothing ever shadows.
  ///
  /// E2: safe to call again while a run is in flight — new registrations
  /// reach the agent at the next turn boundary (the wiring re-syncs the
  /// registry and prompt after this returns).
  Future<ExtLoadReport> loadAll({
    ExtPlatformTag platform = ExtPlatformTag.cli,
    ExtTrustPrompt? trustPrompt,
    Set<String> reservedNames = const {},
  }) async {
    _reservedNames = Set.of(reservedNames);
    final listed = await store.list(forPlatform: platform);
    final loaded = <String>[];
    final skipped = Map<String, String>.of(listed.problems);
    final errors = <String, String>{};

    for (final ext in listed.extensions) {
      await _loadExtension(ext, platform, trustPrompt, skipped, errors, loaded);
    }
    return ExtLoadReport(
      loaded: List.unmodifiable(loaded),
      skipped: Map.unmodifiable(skipped),
      errors: Map.unmodifiable(errors),
    );
  }

  /// Loads one stored extension: platform gate, trust gate (prompt or
  /// tombstone skip), engine start, commit fetch, capability + name-collision
  /// checks, then registration. Failures land in [skipped]/[errors].
  Future<void> _loadExtension(
    StoredExtension ext,
    ExtPlatformTag platform,
    ExtTrustPrompt? trustPrompt,
    Map<String, String> skipped,
    Map<String, String> errors,
    List<String> loaded,
  ) async {
    if (_loaded.any((record) => record.ext.name == ext.name)) {
      return; // already loaded this session
    }
    if (!ext.manifest.supportsPlatform(platform)) {
      skipped[ext.name] = 'unsupported here';
      return;
    }
    if (!await _ensureTrusted(ext, trustPrompt, skipped)) return;

    final runtime = await _startRuntime(ext, skipped, errors);
    if (runtime == null) return;

    final commit = await _fetchCommit(ext.name, runtime, errors);
    if (commit == null) {
      await _disposeQuietly(runtime);
      return;
    }

    final problem =
        _capabilityViolations(ext, commit) ?? _findCollision(commit, ext.name);
    if (problem != null) {
      errors[ext.name] = problem;
      await _disposeQuietly(runtime);
      return;
    }
    _register(ext, runtime, commit, loaded);
  }

  /// The trust gate: already-granted passes; otherwise prompts when a
  /// [trustPrompt] exists (denial recorded) and reports a tombstone skip
  /// otherwise. Returns whether loading may proceed.
  Future<bool> _ensureTrusted(
    StoredExtension ext,
    ExtTrustPrompt? trustPrompt,
    Map<String, String> skipped,
  ) async {
    if (ext.trust != null) return true;
    if (trustPrompt == null) {
      skipped[ext.name] = 'untrusted';
      return false;
    }
    final granted = await trustPrompt(_trustRequestFor(ext));
    if (!granted) {
      skipped[ext.name] = 'untrusted (prompt denied)';
      return false;
    }
    return true;
  }

  /// Builds the loaded record from a validated commit and publishes its
  /// tools, slash commands, flows, and ownership.
  void _register(
    StoredExtension ext,
    JsrRuntime runtime,
    ExtCommit commit,
    List<String> loaded,
  ) {
    final record = _LoadedExt(
      ext: ext,
      runtime: runtime,
      commit: commit,
      tools: [for (final tool in commit.tools) _buildTool(runtime, tool)],
      slash: {
        for (final slash in commit.slash)
          slash.name: _buildSlash(runtime, slash),
      },
      flows: {
        for (final flow in commit.flows)
          'ext:${ext.name}:${flow.id}': _buildFlow(ext.name, runtime, flow),
      },
    );
    for (final tool in commit.tools) {
      _toolOwners[tool.name] = ext.name;
    }
    for (final slash in commit.slash) {
      _slashOwners[slash.name] = ext.name;
    }
    _loaded.add(record);
    loaded.add(ext.name);
  }

  /// Whether at least one loaded extension is currently enabled.
  bool get hasExtensions => _loaded.any((record) => record.enabled);

  /// Tools of every enabled extension, ready for the registry sync.
  List<AgentTool> get tools => [
    for (final record in _loaded)
      if (record.enabled) ...record.tools,
  ];

  /// Registered tool names per enabled extension (load order).
  Map<String, List<String>> get toolsByExtension => {
    for (final record in _loaded)
      if (record.enabled)
        record.ext.name: [for (final tool in record.tools) tool.name],
  };

  /// Engine id of every enabled extension (for wiring diagnostics).
  Map<String, String> get enginesByExtension => {
    for (final record in _loaded)
      if (record.enabled) record.ext.name: record.runtime.engineId,
  };

  /// Names of every loaded extension (enabled or disabled), load order.
  List<String> get loadedNames => [
    for (final record in _loaded) record.ext.name,
  ];

  /// Hook events each enabled extension registered.
  Map<String, Set<ExtHookEvent>> get hooksByExtension => {
    for (final record in _loaded)
      if (record.enabled)
        record.ext.name: {for (final hook in record.commit.hooks) hook.event},
  };

  /// Slash commands of every enabled extension (names stored without the
  /// leading `/`).
  Map<String, SlashCommand> get slashCommands => {
    for (final record in _loaded)
      if (record.enabled) ...record.slash,
  };

  /// Provider flows of every enabled extension, keyed `'ext:<name>:<id>'`.
  Map<String, ExtFlowEntry> get providerFlows => {
    for (final record in _loaded)
      if (record.enabled) ...record.flows,
  };

  /// Attaches the extension hooks to [agent], preserving any hooks already
  /// installed (approval + redaction). Composition, per call:
  ///
  /// - `beforeToolCall`: the EXISTING hook runs first; if it blocks, the JS
  ///   hooks never run (deny-precedence — JS can only ever add a block).
  ///   Otherwise each enabled extension's `beforeToolCall` hook runs in load
  ///   order with `{tool, args}`; `{block: true, reason}` and
  ///   `{prompt: reason}` both block with an `[ext:<name>]-prefixed reason`.
  /// - `afterToolCall`: the EXISTING hook runs first, so JS sees the
  ///   redacted base result. Hooks receive `{tool, args, result, isError}`;
  ///   `{append: text}` appends one text block (passed through
  ///   [ExtHostConfig.redact]) to the original base content. Append-only:
  ///   rewrites and unknown shapes are logged and ignored, and hooks see the
  ///   original base (appends accumulate).
  /// - `prepareNextTurn`: the existing result is kept; any non-null JS
  ///   result is rejected with a log line (E3).
  ///
  /// `transformContext` is deliberately not extended in v1. `onSteering`
  /// hooks are registered but not invoked by the host in v1.
  ///
  /// Attach once per agent; disable/enable changes take effect immediately
  /// because the wrappers consult live registration state.
  void attachHooks(Agent agent) {
    _attachBeforeToolHook(agent);
    _attachAfterToolHook(agent);
    _attachPrepareTurnHook(agent);
  }

  /// Installs the beforeToolCall wrapper: the existing hook first (a block
  /// wins), then every enabled extension's `beforeToolCall` hook in
  /// registration order; the first verdict wins.
  void _attachBeforeToolHook(Agent agent) {
    final existingBefore = agent.beforeToolCall;
    agent.beforeToolCall = (context, cancelToken) async {
      final existing = await existingBefore?.call(context, cancelToken);
      if (existing != null && existing.block) return existing;
      for (final (record, hook) in _hooksFor(ExtHookEvent.beforeToolCall)) {
        final result = await _invokeHook(record, hook, {
          'tool': context.toolCall.name,
          'args': context.toolCall.arguments,
        });
        final verdict = _beforeVerdict(record.ext.name, result);
        if (verdict != null) return verdict;
      }
      return existing;
    };
  }

  /// Installs the afterToolCall wrapper: the existing hook first — its
  /// redaction masks the base the JS hooks see — then every enabled
  /// extension's append-only `afterToolCall` hook.
  void _attachAfterToolHook(Agent agent) {
    final existingAfter = agent.afterToolCall;
    agent.afterToolCall = (context, cancelToken) async {
      final existing = await existingAfter?.call(context, cancelToken);
      final baseContent = List<ContentBlock>.of(
        existing?.content ?? context.result.content,
      );
      final (content, appended) = await _runAfterHooks(
        context,
        _firstText(baseContent),
        existing?.isError ?? context.isError,
        baseContent,
      );
      if (appended || existing != null) {
        return AfterToolCallResult(
          content: content,
          isError: existing?.isError,
          terminate: existing?.terminate,
        );
      }
      return null;
    };
  }

  /// Installs the prepareNextTurn wrapper: existing hook first, then every
  /// enabled extension's `prepareNextTurn` hook (results rejected — E3).
  void _attachPrepareTurnHook(Agent agent) {
    final existingPrepare = agent.prepareNextTurn;
    agent.prepareNextTurn = (context) async {
      final existing = await existingPrepare?.call(context);
      for (final (record, hook) in _hooksFor(ExtHookEvent.prepareNextTurn)) {
        final result = await _invokeHook(record, hook, const {});
        if (result != null) {
          _log('[ext:${record.ext.name}] prepareNextTurn result rejected');
        }
      }
      return existing;
    };
  }

  /// Every (extension, hook) pair for [event] across enabled extensions,
  /// in registration order.
  Iterable<(_LoadedExt, ExtHookDef)> _hooksFor(ExtHookEvent event) sync* {
    for (final record in _enabledLoaded()) {
      for (final hook in record.commit.hooks) {
        if (hook.event == event) yield (record, hook);
      }
    }
  }

  /// Fires every enabled extension's `afterToolCall` hook in order,
  /// appending each returned `append` text (redacted) onto [content];
  /// anything else a hook returns is ignored with a log line. Returns the
  /// final content and whether anything was appended.
  Future<(List<ContentBlock>, bool)> _runAfterHooks(
    AfterToolCallContext context,
    String baseText,
    bool isError,
    List<ContentBlock> content,
  ) async {
    var result = content;
    var appended = false;
    for (final (record, hook) in _hooksFor(ExtHookEvent.afterToolCall)) {
      final hookResult = await _invokeHook(record, hook, {
        'tool': context.toolCall.name,
        'args': context.toolCall.arguments,
        'result': baseText,
        'isError': isError,
      });
      final append = _afterAppend(record.ext.name, hookResult);
      if (append == null) continue;
      result = [...result, TextContent(text: _redacted(append))];
      appended = true;
    }
    return (result, appended);
  }

  /// The `append` string an afterToolCall hook returned, or null.
  String? _afterAppend(String name, Object? result) {
    if (result is Map && result['append'] is String) {
      return result['append'] as String;
    }
    if (result != null) {
      _log(
        '[ext:$name] hook afterToolCall result ignored '
        '(append-only): ${_describe(result)}',
      );
    }
    return null;
  }

  String _redacted(String text) => config.redact?.call(text) ?? text;

  /// Fires every enabled extension's `onSessionStart` hook. Hook errors are
  /// logged, never thrown.
  Future<void> sessionStart() => _fireLifecycle(ExtHookEvent.sessionStart);

  /// Delivers pending follow-ups through [onFollowUp] (`[ext:<name>] `
  /// prefixed), then fires the `onSessionEnd` hooks. Follow-ups enqueued
  /// during the hooks stay pending and land next turn.
  Future<void> sessionEnd() async {
    _deliverFollowUps();
    await _fireLifecycle(ExtHookEvent.sessionEnd);
  }

  /// Live-unregisters [name] (E9): its tools leave [tools] (the wiring
  /// removes them via the [setToolSyncCallbacks] callback), hooks, slash
  /// commands, and flows detach synchronously (the wrappers consult live
  /// state); in-flight engine calls run to completion. Throws
  /// [ArgumentError] for a name that never loaded.
  Future<void> disable(String name) async {
    final record = _require(name);
    if (!record.enabled) return;
    record.enabled = false;
    _syncTools?.call(const [], [for (final tool in record.tools) tool.name]);
    _rebuildPrompt?.call();
  }

  /// Re-registers a previously disabled extension (E9): tools return to
  /// [tools] (the wiring adds them back via [setToolSyncCallbacks]), hooks,
  /// slash commands, and flows attach again. Throws [ArgumentError] for a
  /// name that never loaded.
  Future<void> enable(String name) async {
    final record = _require(name);
    if (record.enabled) return;
    record.enabled = true;
    _syncTools?.call(List.unmodifiable(record.tools), const []);
    _rebuildPrompt?.call();
  }

  /// Registers the callbacks the wiring uses to keep the live tool registry
  /// and prompt in sync across enable/disable.
  void setToolSyncCallbacks({
    required void Function(List<AgentTool> add, List<String> remove) syncTools,
    required void Function() rebuildPrompt,
  }) {
    _syncTools = syncTools;
    _rebuildPrompt = rebuildPrompt;
  }

  /// Disposes every engine and clears all registration state. Idempotent.
  Future<void> dispose() async {
    final runtimes = [for (final record in _loaded) record.runtime];
    _loaded.clear();
    _toolOwners.clear();
    _slashOwners.clear();
    for (final runtime in runtimes) {
      await _disposeQuietly(runtime);
    }
  }

  // --- load pipeline helpers -----------------------------------------------

  /// Trust prompt payload for an extension without `trust.json`: display-only
  /// synthesis from the store entry (the authoritative grant path is the
  /// installer writing the trust record, not this session grant).
  ExtTrustRequest _trustRequestFor(StoredExtension ext) {
    return ExtTrustRequest(
      name: ext.name,
      source: ExtTrustSource.local,
      sourceRef: ext.dir,
      contentSha256: extContentHash({ExtensionStore.kMainFile: ext.mainJs}),
      capabilities: ext.manifest.capabilities.toJson(),
    );
  }

  /// Creates and starts the extension's engine. `null` (with a skip/error
  /// entry recorded) on any failure; a factory throwing
  /// [ExtEngineUnavailableException] is a skip, not an error (E1).
  Future<JsrRuntime?> _startRuntime(
    StoredExtension ext,
    Map<String, String> skipped,
    Map<String, String> errors,
  ) async {
    JsrRuntime? runtime;
    try {
      runtime = runtimeFactory(ext);
      await runtime
          .start(
            bootstrapJs: bootstrapJs,
            mainJs: ext.mainJs,
            bridges: _bridgeHandler(ext),
          )
          .timeout(config.loadTimeout);
      return runtime;
    } on ExtEngineUnavailableException catch (error) {
      skipped[ext.name] = 'engine unavailable: ${error.reason}';
    } on TimeoutException {
      errors[ext.name] = 'load timed out after ${config.loadTimeout}';
    } catch (error) {
      errors[ext.name] = 'start failed: $error';
    }
    if (runtime != null) await _disposeQuietly(runtime);
    return null;
  }

  Future<ExtCommit?> _fetchCommit(
    String name,
    JsrRuntime runtime,
    Map<String, String> errors,
  ) async {
    try {
      final payload = await runtime
          .invoke(ExtJsGlobals.commit, const [])
          .timeout(config.loadTimeout);
      return parseExtCommit(payload);
    } on ExtProtocolException catch (error) {
      errors[name] = 'invalid commit: ${error.message}';
    } on TimeoutException {
      errors[name] = 'load timed out after ${config.loadTimeout}';
    } catch (error) {
      errors[name] = 'commit failed: $error';
    }
    return null;
  }

  /// Capability enforcement at commit: tools need `capabilities.tools`,
  /// every hook event must be listed in `capabilities.hooks`, flows need
  /// `capabilities.menus`. Any violation fails the whole extension.
  String? _capabilityViolations(StoredExtension ext, ExtCommit commit) {
    final caps = ext.manifest.capabilities;
    final problems = <String>[];
    for (final tool in commit.tools) {
      if (!caps.tools) {
        problems.add("tool '${tool.name}': capability tools not declared");
      }
    }
    for (final hook in commit.hooks) {
      if (!caps.hooks.contains(hook.event)) {
        problems.add(
          "hook '${extHookEventJson(hook.event)}': not declared in "
          'capabilities',
        );
      }
    }
    for (final flow in commit.flows) {
      if (!caps.menus) {
        problems.add("flow '${flow.id}': capability menus not declared");
      }
    }
    return problems.isEmpty ? null : problems.join('; ');
  }

  /// First cross-extension or vs-reserved name collision (E4), naming both
  /// sides; `null` when clear. Tools and slash commands are separate
  /// namespaces, each also guarded by the reserved set.
  String? _findCollision(ExtCommit commit, String name) {
    for (final tool in commit.tools) {
      final owner = _toolOwners[tool.name];
      if (owner != null) {
        return "tool '${tool.name}': extension '$name' conflicts with "
            "extension '$owner'";
      }
      if (_reservedNames.contains(tool.name)) {
        return "tool '${tool.name}': extension '$name' conflicts with "
            'reserved name';
      }
    }
    for (final slash in commit.slash) {
      final owner = _slashOwners[slash.name];
      if (owner != null) {
        return "slash command '${slash.name}': extension '$name' conflicts "
            "with extension '$owner'";
      }
      if (_reservedNames.contains(slash.name)) {
        return "slash command '${slash.name}': extension '$name' conflicts "
            'with reserved name';
      }
    }
    return null;
  }

  AgentTool _buildTool(JsrRuntime runtime, ExtToolDef def) {
    return AgentTool(
      name: def.name,
      description: def.description,
      parameters: def.parameters,
      tier: switch (def.tier) {
        ExtTiers.read => ApprovalTier.read,
        ExtTiers.write => ApprovalTier.write,
        _ => ApprovalTier.exec,
      },
      execute: (arguments, cancelToken, onUpdate) async {
        // v1 ignores cancelToken: JsrRuntime.invoke has no token parameter,
        // so the engine adapters' toolTimeout is the bound. A cancelled run
        // simply outlives the invoke until the timeout fires.
        final result = await runtime.invoke(ExtJsGlobals.invoke, [
          def.handle,
          arguments,
        ], timeout: config.toolTimeout);
        return _toolResult(result);
      },
    );
  }

  /// Normalizes the JS tool-call result: `String` | `{text}` |
  /// `{content: [{type: 'text', text}, ...]}` become text results;
  /// `{error}` throws [StateError] (the loop converts it into an error tool
  /// result); anything else degrades to its JSON encoding.
  ToolExecutionResult _toolResult(Object? result) {
    if (result is String) return ToolExecutionResult.text(result);
    if (result is Map) return _mapToolResult(result);
    return _fallbackToolResult(result);
  }

  /// The Map shapes of a JS tool result: `{error}` throws, `{text}` and
  /// `{content: [...]}` become text, anything else falls back.
  ToolExecutionResult _mapToolResult(Map result) {
    final error = result['error'];
    if (error is String) throw StateError(error);
    final text = result['text'];
    if (text is String) return ToolExecutionResult.text(text);
    final content = result['content'];
    if (content is List) return ToolExecutionResult.text(_joinContent(content));
    return _fallbackToolResult(result);
  }

  /// Joins `{type: 'text', text: ...}` content blocks with newlines;
  /// non-text blocks are skipped.
  String _joinContent(List content) {
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is Map && block['type'] == 'text' && block['text'] is String) {
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.write(block['text'] as String);
      }
    }
    return buffer.toString();
  }

  ToolExecutionResult _fallbackToolResult(Object? result) =>
      ToolExecutionResult.text(result == null ? '' : jsonEncode(result));

  SlashCommand _buildSlash(JsrRuntime runtime, ExtSlashDef def) {
    return (args) async {
      await runtime.invoke(ExtJsGlobals.invoke, [
        def.handle,
        args,
      ], timeout: config.toolTimeout);
    };
  }

  ExtFlowEntry _buildFlow(
    String extension,
    JsrRuntime runtime,
    ExtFlowDef flow,
  ) {
    return ExtFlowEntry(
      extension: extension,
      flow: flow,
      submit: (values) => runtime.invoke(ExtJsGlobals.invoke, [
        flow.handle,
        values,
      ], timeout: config.toolTimeout),
    );
  }

  // --- hook helpers ----------------------------------------------------------

  List<_LoadedExt> _enabledLoaded() => [
    for (final record in _loaded)
      if (record.enabled) record,
  ];

  /// One hook invocation with the per-hook budget; ANY failure (throw or
  /// timeout) degrades to a log line and `null`.
  Future<Object?> _invokeHook(
    _LoadedExt record,
    ExtHookDef hook,
    Map<String, dynamic> payload,
  ) async {
    try {
      return await record.runtime.invoke(ExtJsGlobals.invoke, [
        hook.handle,
        payload,
      ], timeout: config.hookTimeout);
    } catch (error) {
      _log('[ext:${record.ext.name}] hook ${hook.event.name} failed: $error');
      return null;
    }
  }

  BeforeToolCallResult? _beforeVerdict(String name, Object? result) {
    if (result == null) return null;
    if (result is Map) {
      if (result['block'] == true) {
        final reason = result['reason'];
        return BeforeToolCallResult(
          block: true,
          reason:
              '[ext:$name] '
              '${reason is String && reason.isNotEmpty ? reason : 'blocked'}',
        );
      }
      final prompt = result['prompt'];
      if (prompt is String) {
        return BeforeToolCallResult(
          block: true,
          reason: '[ext:$name] confirmation required: $prompt',
        );
      }
    }
    _log(
      '[ext:$name] hook beforeToolCall returned unsupported result: '
      '${_describe(result)}',
    );
    return null;
  }

  String _firstText(List<ContentBlock> content) {
    for (final block in content) {
      if (block is TextContent) return block.text;
    }
    return '';
  }

  Future<void> _fireLifecycle(ExtHookEvent event) async {
    for (final record in _enabledLoaded()) {
      for (final hook in record.commit.hooks) {
        if (hook.event != event) continue;
        await _invokeHook(record, hook, const {});
      }
    }
  }

  void _deliverFollowUps() {
    for (final record in _loaded) {
      for (final text in record.followUps.drain()) {
        onFollowUp?.call('[ext:${record.ext.name}] $text');
      }
    }
  }

  // --- session bridges -------------------------------------------------------

  /// Host-side dispatch of the extension's `jsr.ext.*` calls. Registration
  /// methods are buffered JS-side (validated at commit) and answered `null`
  /// here; capability-gated methods throw [ExtBridgeUnavailableException];
  /// any other throw is an extension error reported to JS as an error result.
  ExtBridgeHandler _bridgeHandler(StoredExtension ext) {
    final caps = ext.manifest.capabilities;
    return (method, args) => switch (method) {
      // Registration methods are buffered JS-side (validated at commit).
      ExtBridgeMethods.registerTool ||
      ExtBridgeMethods.registerHook ||
      ExtBridgeMethods.registerSlash ||
      ExtBridgeMethods.registerFlow => Future<Object?>.value(null),
      ExtBridgeMethods.sessionAppendNote => _noteSink(args),
      ExtBridgeMethods.sessionEnqueueFollowUp => _followUpSink(ext, args),
      ExtBridgeMethods.fsReadFile => _fsReadFile(caps, args),
      ExtBridgeMethods.execRun => _execRun(caps, args),
      ExtBridgeMethods.ioWrite => _ioSink(onIoWrite, args),
      ExtBridgeMethods.ioWriteln => _ioSink(onIoWriteln, args),
      ExtBridgeMethods.keysRequest => _keysReply(caps, args),
      ExtBridgeMethods.has => Future<Object?>.value(
        _hasCapability(caps, '${args['capability']}'),
      ),
      _ => Future<Object?>.error(
        ExtBridgeUnavailableException('unknown bridge method: $method'),
      ),
    };
  }

  Future<Object?> _noteSink(Map<String, dynamic> args) async {
    onAppendNote?.call(_requireText(args));
    return null;
  }

  Future<Object?> _followUpSink(
    StoredExtension ext,
    Map<String, dynamic> args,
  ) async {
    _require(
      ext.name,
    ).followUps.enqueue(_requireText(args), config.maxPendingFollowUps);
    return null;
  }

  Future<Object?> _fsReadFile(
    ExtCapabilities caps,
    Map<String, dynamic> args,
  ) async {
    if (!caps.fs) {
      throw ExtBridgeUnavailableException('fs capability not declared');
    }
    return _readConfined(_requireText(args, field: 'path'));
  }

  Future<Object?> _ioSink(
    void Function(String text)? sink,
    Map<String, dynamic> args,
  ) async {
    sink?.call(_requireText(args));
    return null;
  }

  Future<Object?> _keysReply(
    ExtCapabilities caps,
    Map<String, dynamic> args,
  ) async {
    if (!caps.keys) {
      throw ExtBridgeUnavailableException('keys capability not declared');
    }
    // v1 CLI never reveals key values (AC10).
    return {'granted': false, 'name': '${args['name']}'};
  }

  String _requireText(Map<String, dynamic> args, {String field = 'text'}) {
    final value = args[field];
    if (value is! String) {
      throw ArgumentError('bridge requires string $field');
    }
    return value;
  }

  /// Reads [path] lexically confined under [env.cwd]: relative paths join
  /// against the cwd, `.`/`..` normalize, and any escape (including `..`
  /// climbing above the root) is refused. Symlinks are not resolved.
  Future<String> _readConfined(String path) async {
    final root = _normalizeLexical(env.cwd);
    final candidate = _normalizeLexical(
      path.startsWith('/') ? path : '${env.cwd}/$path',
    );
    if (candidate != root && !candidate.startsWith('$root/')) {
      throw ExtBridgeUnavailableException(
        'fs.readFile path escapes project root: $path',
      );
    }
    final result = await env.readTextFile(candidate);
    if (result.isErr) {
      throw StateError('fs.readFile failed: ${result.errorOrNull}');
    }
    return result.valueOrNull!;
  }

  Future<Map<String, Object?>> _execRun(
    ExtCapabilities caps,
    Map<String, dynamic> args,
  ) async {
    final command = args['command'];
    if (command is! String || command.isEmpty) {
      throw ArgumentError('exec.run requires string command');
    }
    final allowed = caps.allowedCommands.any(
      (entry) => command == entry || command.startsWith('$entry '),
    );
    if (!allowed) {
      throw ExtBridgeUnavailableException('exec not allowed: $command');
    }
    final extra = [
      for (final argument in (args['args'] as List? ?? const []))
        if (argument != null) '$argument',
    ];
    final full = extra.isEmpty ? command : '$command ${extra.join(' ')}';
    final timeoutMs = args['timeoutMs'];
    final timeout = timeoutMs is int && timeoutMs > 0
        ? Duration(milliseconds: timeoutMs)
        : null;
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final result = await env.exec(
      full,
      options: ShellExecOptions(
        timeout: timeout,
        onStdout: stdout.write,
        onStderr: stderr.write,
      ),
    );
    return switch (result) {
      Ok(:final value) => {
        'exitCode': value.exitCode,
        'stdout': value.stdout,
        'stderr': value.stderr,
        'timedOut': false,
      },
      Err(:final error) when error.code == ExecutionErrorCode.timeout => {
        'exitCode': -1,
        'stdout': stdout.toString(),
        'stderr': stderr.toString(),
        'timedOut': true,
      },
      Err(:final error) => throw StateError('exec.run failed: $error'),
    };
  }

  bool _hasCapability(ExtCapabilities caps, String name) => switch (name) {
    'network' => caps.network,
    'exec' => caps.allowedCommands.isNotEmpty,
    'keys' => caps.keys,
    'fs' => caps.fs,
    'tools' => caps.tools,
    'menus' => caps.menus,
    _ => false,
  };

  // --- misc ------------------------------------------------------------------

  _LoadedExt _require(String name) {
    for (final record in _loaded) {
      if (record.ext.name == name) return record;
    }
    throw ArgumentError.value(name, 'name', 'extension not loaded');
  }

  void _log(String line) => onLog?.call(line);

  Future<void> _disposeQuietly(JsrRuntime runtime) async {
    try {
      await runtime.dispose();
    } catch (_) {
      // disposal of a half-started engine is best-effort
    }
  }

  String _describe(Object? value) {
    final text = value is Map ? jsonEncode(value) : '$value';
    return text.length <= 200 ? text : '${text.substring(0, 200)}…';
  }
}

/// POSIX-lexical path normalization (`.`/`..`/duplicate slashes resolved
/// against `/`); no symlink resolution.
String _normalizeLexical(String path) {
  final segments = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return segments.isEmpty ? '/' : '/${segments.join('/')}';
}
