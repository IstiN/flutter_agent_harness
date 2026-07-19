/// The TTSR controller: watches an [Agent]'s stream for rule matches and
/// drives the abort → inject → retry cycle (omp's `AgentSession` TTSR path).
///
/// Ported from oh-my-pi (`docs/ttsr-injection-lifecycle.md` +
/// `session/agent-session.ts`), reduced to regex conditions and the
/// interrupting path: on a match the controller aborts the current
/// generation mid-stream via [Agent.abort], drops (or keeps, per
/// [TtsrSettings.contextMode]) the partial assistant output, injects the
/// rule bodies as a hidden `<system-interrupt>` reminder user message, and
/// retries the turn with [Agent.continueRun]. omp's non-interrupting
/// `interruptMode: never` paths (deferred prose injections, in-band tool
/// reminders) and ast-grep conditions are deliberately not ported.
///
/// Persistence model mirrors the checkpoint/rewind controller: hosts persist
/// the in-memory transcript on their own schedule (the CLI batches at run
/// end), so the controller flushes what it relies on through the
/// [TtsrSessionSink] — pending messages before the injection point, then the
/// injection itself as a `ttsr-injection` custom message (projects into
/// context as a user message, survives compaction) plus a `ttsr_injection`
/// custom record (the injected rule names, for session restore).
library;

// The public named parameters map to private fields; initializing formals
// would make the parameter names private and unusable outside this library.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../prompts/prompts.g.dart';
import '../session/session_record.dart';
import '../session/session_tree.dart';
import '../types.dart';
import 'ttsr_manager.dart';
import 'ttsr_rule.dart';

/// The `custom_message` type carrying the injected reminder in the session
/// tree (omp's `ttsr-injection` custom message).
const ttsrInjectionCustomType = 'ttsr-injection';

/// The `custom` record type persisting injected rule names (omp's
/// `ttsr_injection` entry).
const ttsrInjectionRecordType = 'ttsr_injection';

/// Reads the persisted injected-rule names along the session's active branch
/// (omp's `getInjectedTtsrRules`), for [TtsrManager.restoreInjected] on
/// session resume.
Future<List<String>> readPersistedTtsrInjections(Session session) async {
  final names = <String>{};
  for (final record in await session.getBranch()) {
    if (record is CustomRecord &&
        record.customType == ttsrInjectionRecordType) {
      final data = record.data;
      if (data is! Map) continue;
      final rules = data['rules'];
      if (rules is List) names.addAll(rules.whereType<String>());
    }
  }
  return List.unmodifiable(names);
}

/// The host seam for session persistence the controller drives.
///
/// [persistMessage] mirrors the checkpoint sink (appends one in-memory
/// message and bumps the host's persisted counter); [persistInjection]
/// appends the `ttsr-injection` custom message plus the `ttsr_injection`
/// record at the session leaf and bumps the counter by one (the in-memory
/// injection message then counts as persisted).
final class TtsrSessionSink {
  /// Creates a sink.
  const TtsrSessionSink({
    required this.session,
    required this.persistedMessageCount,
    required this.persistMessage,
    required this.persistInjection,
  });

  /// The current session, or `null` when the host has none (the controller
  /// then degrades to in-memory injection only).
  final Session? Function() session;

  /// How many leading in-memory messages the host has already persisted.
  final int Function() persistedMessageCount;

  /// Persists one in-memory [message] at the session leaf and bumps the
  /// host's persisted counter.
  final Future<void> Function(Message message) persistMessage;

  /// Persists the injection at the session leaf (custom message + record)
  /// and bumps the host's persisted counter by one.
  final Future<void> Function(String content, List<String> ruleNames)
  persistInjection;
}

/// Orchestrates TTSR for one [Agent].
///
/// Created once per agent (the CLI creates one next to the checkpoint
/// controller); the manager carries the rules. Detection rides the agent's
/// event stream: text/thinking/tool-call deltas feed [TtsrManager.checkDelta];
/// a match aborts the stream immediately and schedules the inject+retry task
/// after [TtsrSettings.retryDelay] (omp's 50ms post-abort scheduling), so the
/// aborted run settles first. The retry is best-effort (omp semantics):
/// failures are swallowed and reported via [onWarning].
final class TtsrController {
  /// Creates a controller and attaches it to [agent] via [Agent.subscribe].
  TtsrController({
    required Agent agent,
    required TtsrManager manager,
    TtsrSessionSink? sink,
    void Function(List<TtsrRule> rules)? onTriggered,
    void Function(String message)? onWarning,
  }) : _agent = agent,
       _manager = manager,
       _sink = sink,
       _onTriggered = onTriggered,
       _onWarning = onWarning {
    _unsubscribe = _agent.subscribe(_onAgentEvent);
  }

  final Agent _agent;
  final TtsrManager _manager;
  final TtsrSessionSink? _sink;
  final void Function(List<TtsrRule> rules)? _onTriggered;
  final void Function(String message)? _onWarning;

  final _pendingInjections = <TtsrRule>[];
  var _abortPending = false;
  var _injectionsThisChain = 0;
  Timer? _retryTimer;
  var _retryInFlight = false;
  Completer<void>? _settledCompleter;
  void Function()? _unsubscribe;

  /// The rule manager backing this controller.
  TtsrManager get manager => _manager;

  /// Whether a TTSR abort is pending (the stream was aborted to inject
  /// rules; omp's `isTtsrAbortPending`). UIs suppress the aborted-run error
  /// rendering while this is true.
  bool get isAbortPending => _abortPending;

  /// Injection cycles fired in the current prompt-turn chain (the retry
  /// storm guard counter; reset when a run completes without a TTSR abort).
  int get injectionsThisChain => _injectionsThisChain;

  /// Resolves when no retry is scheduled or in flight and no abort is
  /// pending. Hosts that batch-persist at run end (the CLI) await this
  /// first so the transcript they persist includes the whole retry chain.
  Future<void> get settled => _settledCompleter?.future ?? Future<void>.value();

  /// Clears controller and manager state for a new session (omp builds a
  /// fresh manager per session): cancels a pending retry, drops queued
  /// injections, and clears the manager's injected-rule records so rules may
  /// fire again.
  void reset() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _abortPending = false;
    _pendingInjections.clear();
    _injectionsThisChain = 0;
    _manager.resetBuffer();
    _manager.clearInjected();
    _maybeCompleteSettled();
  }

  /// Detaches from the agent and cancels any pending retry.
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _unsubscribe?.call();
    _unsubscribe = null;
    _maybeCompleteSettled();
  }

  void _onAgentEvent(AgentEvent event, CancelToken cancelToken) {
    // Defensive: a throwing listener would propagate into the loop and fail
    // the run, so the controller never lets its own errors escape.
    try {
      switch (event) {
        case TurnStartEvent():
          // omp resets the stream buffer on every turn start.
          _manager.resetBuffer();
        case TurnEndEvent():
          // omp counts completed turns for the repeat-after-gap policy.
          _manager.incrementMessageCount();
        case MessageUpdateEvent(:final assistantMessageEvent):
          _checkStreamDelta(assistantMessageEvent);
        case AgentEndEvent():
          // A run that ends with no TTSR abort pending breaks the retry
          // chain: reset the storm-guard counter. (The retry's own clean
          // completion lands here while `_retryInFlight` is still true —
          // that flag only gates `settled`, not the chain reset.)
          if (!_abortPending && !(_retryTimer?.isActive ?? false)) {
            _injectionsThisChain = 0;
            _maybeCompleteSettled();
          }
        default:
      }
    } on Object catch (error) {
      _onWarning?.call('TTSR event handling failed: $error');
    }
  }

  void _checkStreamDelta(AssistantMessageEvent event) {
    if (!_manager.hasRules()) return;
    final context = switch (event) {
      TextDeltaEvent() => const TtsrMatchContext(source: TtsrMatchSource.text),
      ThinkingDeltaEvent() => const TtsrMatchContext(
        source: TtsrMatchSource.thinking,
      ),
      ToolCallDeltaEvent(:final contentIndex, :final partial) =>
        _toolMatchContext(contentIndex, partial),
      _ => null,
    };
    if (context == null) return;
    final delta = switch (event) {
      TextDeltaEvent(:final delta) => delta,
      ThinkingDeltaEvent(:final delta) => delta,
      ToolCallDeltaEvent(:final delta) => delta,
      _ => '',
    };
    if (delta.isEmpty) return;
    final matches = _manager.checkDelta(delta, context);
    if (matches.isEmpty) return;
    _handleMatches(matches);
  }

  TtsrMatchContext _toolMatchContext(
    int contentIndex,
    AssistantMessage partial,
  ) {
    String? toolName;
    String? streamKey;
    if (contentIndex >= 0 && contentIndex < partial.content.length) {
      final block = partial.content[contentIndex];
      if (block is ToolCall) {
        toolName = block.name;
        streamKey = 'toolcall:${block.id}';
      }
    }
    return TtsrMatchContext(
      source: TtsrMatchSource.tool,
      toolName: toolName,
      streamKey: streamKey,
    );
  }

  void _handleMatches(List<TtsrRule> matches) {
    // Trailing deltas while the abort propagates join the same injection
    // (omp dedupes pending rules by name).
    if (_abortPending) {
      _addPending(matches);
      return;
    }
    // Retry-storm guard (ours, not omp's): bound the abort/inject/retry
    // cycles of one prompt-turn chain; the match is dropped, not injected.
    if (_injectionsThisChain >= _manager.settings.maxInjectionsPerTurn) {
      _onWarning?.call(
        'TTSR injection cap reached '
        '(${_manager.settings.maxInjectionsPerTurn} per turn); ignoring '
        'match: ${matches.map((rule) => rule.name).join(', ')}',
      );
      return;
    }
    _addPending(matches);
    if (_pendingInjections.isEmpty) return;
    // Abort immediately (omp: never gated on extension callbacks), then
    // schedule the inject+retry so the aborted run settles first.
    _abortPending = true;
    _settledCompleter ??= Completer<void>();
    _agent.abort();
    _onTriggered?.call(List.unmodifiable(matches));
    _retryTimer?.cancel();
    _retryTimer = Timer(_manager.settings.retryDelay, _runRetry);
  }

  void _addPending(List<TtsrRule> rules) {
    for (final rule in rules) {
      if (_pendingInjections.every((pending) => pending.name != rule.name)) {
        _pendingInjections.add(rule);
      }
    }
  }

  /// The inject+retry task (omp's scheduled post-prompt task).
  Future<void> _runRetry() async {
    _retryTimer = null;
    if (!_abortPending) {
      _pendingInjections.clear();
      _maybeCompleteSettled();
      return;
    }
    _abortPending = false;
    _retryInFlight = true;
    try {
      // omp's contextMode: discard drops the partial/aborted assistant
      // message before the retry; keep leaves it and appends the reminder
      // after it.
      var messages = _agent.state.messages;
      if (_manager.settings.contextMode == TtsrContextMode.discard &&
          messages.isNotEmpty &&
          messages.last is AssistantMessage &&
          _isFailedGeneration(messages.last as AssistantMessage)) {
        _agent.state.messages = messages.sublist(0, messages.length - 1);
        messages = _agent.state.messages;
      }

      final content = _buildInjectionContent();
      if (content == null) {
        _maybeCompleteSettled();
        return;
      }
      final ruleNames = [for (final rule in _pendingInjections) rule.name];
      _pendingInjections.clear();
      // Mark injected BEFORE the retry so a rule that fired cannot re-fire
      // on the retry (omp's once-per-session repeat gate).
      _manager.markInjectedByNames(ruleNames);

      final sink = _sink;
      final session = sink?.session();
      if (session != null && sink != null) {
        try {
          // Flush the host-pending messages (in discard mode the dropped
          // partial is already gone, so it never reaches the tree; the tree
          // then mirrors the pruned transcript).
          for (var i = sink.persistedMessageCount(); i < messages.length; i++) {
            await sink.persistMessage(messages[i]);
          }
          await sink.persistInjection(content, ruleNames);
        } on Object catch (error) {
          _onWarning?.call('TTSR injection persistence failed: $error');
        }
      }

      _injectionsThisChain++;
      _agent.state.messages = [...messages, UserMessage.text(content)];
      try {
        await _agent.continueRun();
      } on Object catch (error) {
        // Best-effort retry (omp): state may have changed between abort and
        // retry (user interrupt, reset, a fresh prompt).
        _onWarning?.call('TTSR retry failed: $error');
      }
    } finally {
      _retryInFlight = false;
      _maybeCompleteSettled();
    }
  }

  bool _isFailedGeneration(AssistantMessage message) {
    return message.stopReason == StopReason.aborted ||
        message.stopReason == StopReason.error;
  }

  /// Renders the pending rules into the reminder envelope (omp's
  /// `getTtsrInjectionContent`: one rendered template per rule, joined by a
  /// blank line). Returns null when nothing is pending.
  String? _buildInjectionContent() {
    if (_pendingInjections.isEmpty) return null;
    return [
      for (final rule in _pendingInjections)
        ttsrInterruptPrompt
            .replaceAll('{{name}}', rule.name)
            .replaceAll('{{path}}', rule.path ?? 'config')
            .replaceAll('{{content}}', rule.body),
    ].join('\n\n');
  }

  void _maybeCompleteSettled() {
    if (_abortPending || _retryInFlight || (_retryTimer?.isActive ?? false)) {
      return;
    }
    final completer = _settledCompleter;
    _settledCompleter = null;
    completer?.complete();
  }
}
