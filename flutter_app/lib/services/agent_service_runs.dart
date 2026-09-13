// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Part of agent_service.dart: the host-completion + run-lifecycle members
// of [AgentService] live here so the main file stays under the 2800-line
// guard. Same library, so private members resolve; notifications go
// through `_notify()` (`notifyListeners` is @protected, callable only
// inside the class).

part of 'agent_service.dart';

extension AgentServiceRuns on AgentService {
  /// LLM completion for host features (the `jsr.fa.llm*` bridge in JS apps).
  /// Runs on a throwaway agent with no tools, so it never touches the session
  /// transcript. `system` messages are folded into the system prompt; `user`
  /// and `assistant` messages become the conversation, which should end with
  /// a user message. When [onDelta] is given, streamed text deltas are
  /// forwarded as they arrive.
  Future<String> completeOnce(
    List<FaLlmMessage> messages, {
    void Function(String delta)? onDelta,
  }) async {
    final model = _agent.state.model;
    final agent = Agent(
      model: model,
      systemPrompt: [
        'You are a tiny assistant embedded inside a host '
            'application. Answer briefly and plainly; no markdown fences unless '
            'the caller asks for code.',
        for (final message in messages)
          if (message.role == 'system') message.content,
      ].join('\n\n'),
      streamFunction: _agent.streamFunction,
      toolRegistry: ToolRegistry(const []),
    );
    if (onDelta != null) {
      agent.subscribe((event, cancelToken) async {
        if (event case MessageUpdateEvent(
          assistantMessageEvent: TextDeltaEvent(:final delta),
        )) {
          onDelta(delta);
        }
      });
    }
    final conversation = [
      for (final message in messages)
        if (message.role == 'assistant')
          AssistantMessage(
            content: [TextContent(text: message.content)],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.now(),
          )
        else if (message.role == 'user')
          UserMessage.text(message.content),
    ];
    if (conversation.isEmpty) {
      throw StateError('messages must include at least one user message');
    }
    await agent.promptMessages(conversation);
    final last = agent.state.messages.lastOrNull;
    if (last is AssistantMessage) {
      final text = last.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      if (text.isNotEmpty) return text;
      if (last.errorMessage != null) throw StateError(last.errorMessage!);
    }
    throw StateError('no completion returned');
  }

  /// Starts one agent run and settles the UI state no matter how it ends.
  ///
  /// [startRun] is invoked LAZILY inside a try/catch: `Agent.prompt*` throws
  /// synchronously when a run is already active, and the composer calls the
  /// send methods unawaited — a synchronous escape would surface as an
  /// unhandled async error in the console (the "Uncaught Error" storm after
  /// a provider failure) instead of the error banner. Timeouts and async
  /// failures land in `catchError`, which always re-enables the UI.
  void _runWithTimeout(Future<void> Function() startRun) {
    final Future<void> run;
    try {
      // Multi-day sessions: re-compose the prompt so the model sees
      // TODAY's date, not the session creation date.
      final config = _config;
      if (config != null) {
        _agent.state.systemPrompt = _composeSystemPrompt(config);
      }
      _armIdleWatchdog();
      run = startRun();
    } on Object catch (e) {
      _idleWatchdog?.cancel();
      isStreaming = false;
      error = e is StateError ? e.message : e.toString();
      _notify();
      return;
    }
    run.catchError((Object e) {
      _idleWatchdog?.cancel();
      isStreaming = false;
      error = e.toString();
      // dispose() aborts an in-flight run — its error lands here after the
      // service is gone; notifying a disposed ChangeNotifier throws.
      if (_disposed) return;
      _notify();
    });
  }
}
