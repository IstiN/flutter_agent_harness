// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: the agent-event handling member of
// [AgentService] lives here so the main file stays under the 2800-line
// guard. Same library, so private members resolve; notifications go
// through `_notify()` (`notifyListeners` is @protected, callable only
// inside the class).
//
// The full agent-event switch: streaming deltas, transcript tiles
// (assistant/thinking/tool/system/widget), the dynamic-message marker
// splice, Live Activity status, idle watchdog rearming, end-of-run
// persistence + auto-compaction + queued-run continuation.

part of 'agent_service.dart';

extension AgentServiceEvents on AgentService {
  Future<void> _onAgentEvent(AgentEvent event, CancelToken cancelToken) async {
    // Any event proves the run is alive — rearm the idle watchdog.
    if (event is! AgentEndEvent) _armIdleWatchdog();
    _trajectory.applyEvent(event);
    switch (event) {
      case AgentStartEvent():
        isStreaming = true;
        _currentAssistantMessage = null;
        _turnStartCount = 0;
        pendingSteerTexts.clear();
        // A fresh run gets a fresh dynamic-message budget (the cap is per
        // agent turn, host-enforced).
        dynamicMessages.onRunStart();
        _notify();
      case TurnStartEvent():
        // Continuation turns (steering injected mid-run) start with a second
        // TurnStartEvent; clear the pending banner now so it doesn't outlive
        // the injected user messages.
        if (_turnStartCount > 0 && pendingSteerTexts.isNotEmpty) {
          pendingSteerTexts.clear();
          _notify();
        }
        _turnStartCount++;
      case MessageUpdateEvent(:final assistantMessageEvent):
        if (assistantMessageEvent is TextDeltaEvent) {
          _appendAssistantDelta(assistantMessageEvent.delta);
        } else if (assistantMessageEvent is ThinkingDeltaEvent) {
          _appendThinkingDelta(assistantMessageEvent.delta);
        }
      case MessageEndEvent(:final message):
        if (message is UserMessage) {
          // User messages (initial prompts and injected steering) reach the
          // transcript through the agent loop so ordering matches the context.
          messages.add(AgentService._toChatMessage(message));
          // If this text was shown as pending while the agent was busy, drop
          // it from the banner now that it is in the live transcript.
          final text = _userMessageText(message);
          if (text != null) pendingSteerTexts.remove(text);
          _notify();
        } else if (message is AssistantMessage) {
          _finalizeAssistant(message);
        }
        _persistSoon();
      case ToolExecutionStartEvent(:final toolName, :final args):
        // Tool calls can run long (builds, installs) without producing agent
        // events — the idle watchdog must not fire during them.
        _activeToolCalls++;
        messages.add(
          FahChatMessage(
            role: 'system',
            content: '[$toolName] ${_shortArgs(args)}',
          ),
        );
        _pushLiveActivityStatus();
        _notify();
      case ToolExecutionEndEvent(
        :final toolName,
        :final result,
        :final isError,
      ):
        _activeToolCalls--;
        _armIdleWatchdog();
        if (AgentService._kMutatingToolNames.contains(toolName)) {
          // "Hook" for file-watching UI: the agent may have changed files.
          fsRevision.value++;
        }
        _persistSoon();
        final text = result.content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join('\n');
        messages.add(
          FahChatMessage(
            role: 'tool',
            content: text,
            toolName: toolName,
            isError: isError,
          ),
        );
        // A dynamic message presented by this tool call renders directly
        // under its result tile (presentation order = call order).
        if (toolName == 'dynamic_message') {
          final presented = dynamicMessages.takePendingMarker();
          if (presented != null) {
            messages.add(
              FahChatMessage(
                role: DynamicMessagesService.markerRole,
                content: presented.title,
                data: presented.id,
              ),
            );
          }
        }
        _pushLiveActivityStatus();
        _notify();
      case ModelRequestEvent(:final detail):
        _persistModelRequest(detail);
      case AgentEndEvent():
        _idleWatchdog?.cancel();
        isStreaming = false;
        _currentAssistantMessage = null;
        _notify();
        // Session persistence is best effort: a failed append must not
        // propagate back into the agent's event plumbing (a throwing
        // listener re-enters the loop's failure path, duplicates the
        // failure events, and escapes the run as an unhandled error).
        //
        // Through the SAME `_persistChain` as `_persistSoon` — a direct
        // call races the queued passes: both read `_persistedCount == 0`
        // before either finishes, and every message is appended twice
        // (duplicate JSONL records, duplicated transcripts on reload).
        // Session persistence is best effort: a failed append must not
        // propagate back into the agent's event plumbing (a throwing
        // listener re-enters the loop's failure path, duplicates the
        // failure events, and escapes the run as an unhandled error).
        try {
          await _persist();
        } on Object {
          // The transcript stays in memory; the next run retries the
          // missed appends (see _persistedCount).
        }
        final compacted = await _maybeAutoCompact();
        // The loop's over-window guard stopped the run: once the
        // post-run compaction freed the window, continue the interrupted
        // turn on its own (once per user text) instead of idling with an
        // error — a live session that hit the guard mid-task (200676/200k
        // on glm) used to sit dead until a manual "continue".
        final lastMessage = _agent.state.messages.lastOrNull;
        if (!_overWindowAutoResumed &&
            compacted &&
            lastMessage is AssistantMessage &&
            isContextWindowExhaustedError(lastMessage.errorMessage)) {
          _overWindowAutoResumed = true;
          Future(
            () => _runWithTimeout(
              () => _agent.prompt(AgentService._overWindowContinuationNotice),
            ),
          );
        }
        // Steering/follow-up messages queued during the run get their own
        // run once this lifecycle fully finished — also after a manual
        // stop, so a queued message never silently dies in the transcript.
        if (_agent.hasQueuedMessages()) {
          Future(() => _runWithTimeout(() => _agent.continueRun()));
        }
      default:
    }
  }

  /// Extracts the textual content of a [UserMessage] for matching against
  /// [pendingSteerTexts]. Returns `null` for empty or non-text messages.
  String? _userMessageText(UserMessage message) {
    final content = message.content;
    if (content is String) {
      return content.isEmpty ? null : content;
    }
    final text = (content as List<ContentBlock>)
        .whereType<TextContent>()
        .map((b) => b.text)
        .join('\n');
    return text.isEmpty ? null : text;
  }

  /// Buffers the outbound-request summary for the next persist pass. The
  /// pass serializes through the same writer as message appends and flushes
  /// summaries right before their assistant message, so the CustomRecord
  /// stays ahead of it on the record chain (the replay walk expects that).
  void _persistModelRequest(TrajectoryRequestDetail detail) {
    _pendingRequestSummaries.add(detail);
  }

  void _appendAssistantDelta(String delta) {
    var target = _currentAssistantMessage;
    if (target == null) {
      target = FahChatMessage(role: 'assistant', content: '');
      _currentAssistantMessage = target;
      messages.add(target);
      // The status line flips to "writing…" — update the Live Activity.
      _pushLiveActivityStatus();
    }
    target.content += delta;
    _notify();
  }

  void _appendThinkingDelta(String delta) {
    var target = _currentThinkingMessage;
    if (target == null) {
      target = FahChatMessage(role: 'thinking', content: '');
      _currentThinkingMessage = target;
      messages.add(target);
      // The status line flips to "thinking…" — update the Live Activity.
      _pushLiveActivityStatus();
    }
    target.content += delta;
    _notify();
  }
}
