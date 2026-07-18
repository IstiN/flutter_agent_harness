import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'env_factory.dart';
import 'prompts.g.dart';
import 'secrets_store.dart';

/// A UI-facing chat message.
final class FahChatMessage {
  FahChatMessage({
    required this.role,
    required this.content,
    this.imageBytes,
    this.toolName,
    this.isError = false,
  });

  /// One of `user`, `assistant`, `tool`, `system`.
  final String role;

  /// Text content. For images the text prompt lives here; the image bytes are
  /// in [imageBytes].
  String content;

  /// Non-null when the user attached an image.
  final Uint8List? imageBytes;

  /// Set for tool-related messages.
  final String? toolName;

  /// Whether this message represents an error.
  final bool isError;
}

/// Configuration needed to talk to a provider.
final class AgentConfig {
  AgentConfig({
    required this.providerKind,
    required this.modelId,
    required this.baseUrl,
    required this.apiKey,
    this.systemPrompt,
  });

  /// Provider adapter kind: `openai-completions`, `anthropic`, or `google`.
  final String providerKind;

  /// Model id passed to the provider.
  final String modelId;

  /// Provider base URL (e.g. OpenRouter `https://openrouter.ai/api/v1`).
  final String baseUrl;

  /// API key for the provider.
  final String apiKey;

  /// Optional system prompt override.
  final String? systemPrompt;

  Model toModel() => Model(
    id: modelId,
    name: modelId,
    api: providerKind,
    provider: providerKind,
    baseUrl: baseUrl,
    contextWindow: 128000,
    maxTokens: 4096,
  );
}

/// Wraps an [Agent] for the Flutter chat UI.
///
/// Persists sessions to [sessionsRoot] via [JsonlSessionRepo] and translates
/// agent lifecycle events into a list of [FahChatMessage].
class AgentService extends ChangeNotifier {
  AgentService({
    required this._agent,
    required this.env,
    required this.sessionsRoot,
    JsonlSessionRepo? repo,
    SecretRedactor? redactor,
  }) : _repo = repo ?? JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot) {
    _attachRedactor(redactor);
    _agent.subscribe(_onAgentEvent);
  }

  /// Convenience factory that creates the right [ExecutionEnv] for the
  /// platform and wires up the agent.
  static Future<AgentService> create({required AgentConfig config}) async {
    final env = await createPlatformEnv();
    final secrets = await createSecretsStore().readAll();
    final redactor = SecretRedactor.fromSecrets(secrets);
    return AgentService._withEnv(
      env: secrets.isEmpty ? env : SecretsExecutionEnv(env, secrets),
      config: config,
      redactor: redactor,
    );
  }

  AgentService._withEnv({
    required this.env,
    required AgentConfig config,
    SecretRedactor? redactor,
  }) : sessionsRoot = '${env.cwd}/sessions',
       _repo = JsonlSessionRepo(fs: env, sessionsRoot: '${env.cwd}/sessions') {
    _agent = Agent(
      model: config.toModel(),
      systemPrompt: _effectiveSystemPrompt(config, redactor),
      streamFunction: providerStreamFunction(
        config.providerKind,
        config.apiKey,
      ),
      toolRegistry: ToolRegistry(builtinTools(env)),
    );
    _attachRedactor(redactor);
    _agent.subscribe(_onAgentEvent);
  }

  /// The system prompt plus a secret-name hint (names only, never values).
  static String _effectiveSystemPrompt(
    AgentConfig config,
    SecretRedactor? redactor,
  ) {
    final base = config.systemPrompt ?? sandboxSystemPrompt;
    final names = redactor?.names ?? const <String>[];
    if (names.isEmpty) return base;
    return '$base\n\nAvailable secret env vars: ${names.join(', ')} — '
        'reference them as \$NAME in shell commands; never ask the user for '
        'their values and never print them.';
  }

  /// Composes redaction hooks onto the agent so secret values never reach
  /// the model, the transcript, or the session files.
  void _attachRedactor(SecretRedactor? redactor) {
    if (redactor == null || redactor.isEmpty) return;
    attachSecretRedactor(_agent, redactor);
  }

  late final Agent _agent;
  final JsonlSessionRepo _repo;
  final String sessionsRoot;

  /// The execution environment the agent's tools (and session storage) run
  /// against. Exposed so UI affordances — the file browser — show the exact
  /// filesystem the agent works in. Typed as the [ExecutionEnv] abstraction,
  /// never a concrete env, so alternative backends (in-memory web FS, cloud
  /// drives) drop in without UI changes.
  final ExecutionEnv env;

  final List<FahChatMessage> messages = [];
  bool isStreaming = false;
  String? error;

  Session? _session;
  int _persistedCount = 0;
  FahChatMessage? _currentAssistantMessage;

  /// Initializes session persistence.
  Future<void> initialize() async {
    _session = await _repo.create(
      JsonlSessionCreateOptions(
        cwd: _agent.state.model.provider,
        metadata: {
          'agent': 'flutter_agent_example',
          'model': _agent.state.model.id,
        },
      ),
    );
  }

  /// Sends a plain-text user message.
  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) return;
    _addUserMessage(text: text);
    _clearError();
    _runWithTimeout(_agent.prompt(text));
  }

  /// Sends a user message with an attached image.
  Future<void> sendImage({
    required Uint8List bytes,
    required String mimeType,
    String text = '',
  }) async {
    _addUserMessage(text: text, imageBytes: bytes, mimeType: mimeType);
    _clearError();
    final content = <ContentBlock>[
      if (text.isNotEmpty) TextContent(text: text),
      ImageContent(data: base64Encode(bytes), mimeType: mimeType),
    ];
    _runWithTimeout(
      _agent.promptMessage(
        UserMessage(content: content, timestamp: DateTime.now()),
      ),
    );
  }

  void _runWithTimeout(Future<void> run) {
    run
        .timeout(
          const Duration(seconds: 90),
          onTimeout: () {
            abort();
            throw TimeoutException(
              'The model did not respond within 90 seconds.',
            );
          },
        )
        .catchError((Object e) {
          isStreaming = false;
          error = e.toString();
          notifyListeners();
        });
  }

  /// Aborts the current run, if any.
  void abort() => _agent.abort();

  /// Waits until the agent becomes idle.
  Future<void> waitForIdle() => _agent.waitForIdle();

  /// Clears the in-memory transcript and starts a new session.
  Future<void> reset() async {
    _agent.reset();
    messages.clear();
    error = null;
    _persistedCount = 0;
    _currentAssistantMessage = null;
    await initialize();
    notifyListeners();
  }

  void _addUserMessage({
    required String text,
    Uint8List? imageBytes,
    String? mimeType,
  }) {
    messages.add(
      FahChatMessage(role: 'user', content: text, imageBytes: imageBytes),
    );
    notifyListeners();
  }

  void _clearError() {
    if (error != null) {
      error = null;
      notifyListeners();
    }
  }

  Future<void> _onAgentEvent(AgentEvent event, CancelToken cancelToken) async {
    switch (event) {
      case AgentStartEvent():
        isStreaming = true;
        _currentAssistantMessage = null;
        notifyListeners();
      case MessageUpdateEvent(:final assistantMessageEvent):
        if (assistantMessageEvent is TextDeltaEvent) {
          _appendAssistantDelta(assistantMessageEvent.delta);
        }
      case MessageEndEvent(:final message):
        if (message is ToolResultMessage) {
          final text = message.content
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n');
          messages.add(
            FahChatMessage(
              role: 'tool',
              content: text,
              toolName: message.toolName,
            ),
          );
          notifyListeners();
        } else if (message is AssistantMessage) {
          _finalizeAssistant(message);
        }
      case ToolExecutionStartEvent(:final toolName, :final args):
        messages.add(
          FahChatMessage(
            role: 'system',
            content: '[$toolName] ${_shortArgs(args)}',
          ),
        );
        notifyListeners();
      case ToolExecutionEndEvent(
        :final toolName,
        :final result,
        :final isError,
      ):
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
        notifyListeners();
      case AgentEndEvent():
        isStreaming = false;
        _currentAssistantMessage = null;
        notifyListeners();
        await _persist();
      default:
    }
  }

  void _appendAssistantDelta(String delta) {
    var target = _currentAssistantMessage;
    if (target == null) {
      target = FahChatMessage(role: 'assistant', content: '');
      _currentAssistantMessage = target;
      messages.add(target);
    }
    target.content += delta;
    notifyListeners();
  }

  void _finalizeAssistant(AssistantMessage message) {
    final text = message.content
        .whereType<TextContent>()
        .map((b) => b.text)
        .join();
    final target = _currentAssistantMessage;
    if (target == null) {
      messages.add(FahChatMessage(role: 'assistant', content: text));
    } else {
      target.content = text;
    }
    _currentAssistantMessage = null;
    if (message.stopReason case StopReason.error || StopReason.aborted) {
      error = message.errorMessage ?? 'Run failed (${message.stopReason.name})';
    }
    notifyListeners();
  }

  String _shortArgs(Map<String, dynamic> args) {
    final encoded = jsonEncode(args);
    if (encoded.length <= 80) return encoded;
    return '${encoded.substring(0, 80)}...';
  }

  Future<void> _persist() async {
    final session = _session;
    if (session == null) return;
    final all = _agent.state.messages;
    for (final message in all.skip(_persistedCount)) {
      await session.appendMessage(message);
    }
    _persistedCount = all.length;
  }
}
