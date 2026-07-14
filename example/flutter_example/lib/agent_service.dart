import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart' show LocalExecutionEnv;
import 'package:path_provider/path_provider.dart';

/// A UI-facing chat message.
final class ChatMessage {
  ChatMessage({
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
/// agent lifecycle events into a list of [ChatMessage].
class AgentService extends ChangeNotifier {
  AgentService({
    required this._agent,
    required ExecutionEnv env,
    required this.sessionsRoot,
    JsonlSessionRepo? repo,
  }) : _repo = repo ?? JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot) {
    _agent.subscribe(_onAgentEvent);
  }

  /// Creates a service for the mobile/desktop filesystem.
  ///
  /// [appDir] is used as both the execution-environment cwd and the parent of
  /// the `sessions` directory. The [config] selects provider/model/credentials.
  factory AgentService.fromLocalEnv({
    required Directory appDir,
    required AgentConfig config,
  }) {
    final env = LocalExecutionEnv(cwd: appDir.path);
    final model = config.toModel();
    final agent = Agent(
      model: model,
      systemPrompt:
          config.systemPrompt ??
          'You are fah (also called fa), a helpful coding assistant. '
              'Never call yourself pi, Claude, or any other assistant name.',
      streamFunction: providerStreamFunction(
        config.providerKind,
        config.apiKey,
      ),
      toolRegistry: ToolRegistry(builtinTools(env)),
    );
    return AgentService(
      agent: agent,
      env: env,
      sessionsRoot: '${appDir.path}/sessions',
    );
  }

  /// Convenience factory that resolves the application documents directory.
  static Future<AgentService> create({required AgentConfig config}) async {
    final appDir = await getApplicationDocumentsDirectory();
    return AgentService.fromLocalEnv(appDir: appDir, config: config);
  }

  final Agent _agent;
  final JsonlSessionRepo _repo;
  final String sessionsRoot;

  final List<ChatMessage> messages = [];
  bool isStreaming = false;
  String? error;

  Session? _session;
  int _persistedCount = 0;

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
    unawaited(_agent.prompt(text));
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
    unawaited(
      _agent.promptMessage(
        UserMessage(content: content, timestamp: DateTime.now()),
      ),
    );
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
    await initialize();
    notifyListeners();
  }

  void _addUserMessage({
    required String text,
    Uint8List? imageBytes,
    String? mimeType,
  }) {
    messages.add(
      ChatMessage(role: 'user', content: text, imageBytes: imageBytes),
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
        messages.add(ChatMessage(role: 'assistant', content: ''));
        notifyListeners();
      case MessageUpdateEvent(:final assistantMessageEvent):
        if (assistantMessageEvent is TextDeltaEvent) {
          final last = messages.lastWhere(
            (m) => m.role == 'assistant',
            orElse: () => ChatMessage(role: 'assistant', content: ''),
          );
          last.content += assistantMessageEvent.delta;
          notifyListeners();
        }
      case MessageEndEvent(:final message):
        if (message is ToolResultMessage) {
          final text = message.content
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n');
          messages.add(
            ChatMessage(
              role: 'tool',
              content: text,
              toolName: message.toolName,
            ),
          );
          notifyListeners();
        } else if (message is AssistantMessage) {
          final last = messages.lastWhere(
            (m) => m.role == 'assistant',
            orElse: () => ChatMessage(role: 'assistant', content: ''),
          );
          if (last.content.isEmpty) {
            last.content = message.content
                .whereType<TextContent>()
                .map((b) => b.text)
                .join();
            notifyListeners();
          }
          if (message.stopReason case StopReason.error || StopReason.aborted) {
            error =
                message.errorMessage ??
                'Run failed (${message.stopReason.name})';
            notifyListeners();
          }
        }
      case ToolExecutionStartEvent(:final toolName, :final args):
        messages.add(
          ChatMessage(
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
          ChatMessage(
            role: 'tool',
            content: text,
            toolName: toolName,
            isError: isError,
          ),
        );
        notifyListeners();
      case AgentEndEvent():
        isStreaming = false;
        await _persist();
        notifyListeners();
      default:
    }
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
