import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'env_factory.dart';

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
    required ExecutionEnv env,
    required this.sessionsRoot,
    JsonlSessionRepo? repo,
  }) : _repo = repo ?? JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot) {
    _agent.subscribe(_onAgentEvent);
  }

  /// Convenience factory that creates the right [ExecutionEnv] for the
  /// platform and wires up the agent.
  static Future<AgentService> create({required AgentConfig config}) async {
    final env = await createPlatformEnv();
    return AgentService._withEnv(env: env, config: config);
  }

  AgentService._withEnv({
    required ExecutionEnv env,
    required AgentConfig config,
  }) : sessionsRoot = '${env.cwd}/sessions',
       _repo = JsonlSessionRepo(fs: env, sessionsRoot: '${env.cwd}/sessions') {
    _agent = Agent(
      model: config.toModel(),
      systemPrompt: config.systemPrompt ?? _defaultSystemPrompt,
      streamFunction: providerStreamFunction(
        config.providerKind,
        config.apiKey,
      ),
      toolRegistry: ToolRegistry(builtinTools(env)),
    );
    _agent.subscribe(_onAgentEvent);
  }

  /// Default system prompt for the mobile/web sandbox: names the assistant
  /// and teaches the agent the sandbox's actual capabilities so it does not
  /// discover them by trial and error.
  static const String _defaultSystemPrompt =
      'You are fah (also called fa), a helpful coding assistant. '
      'Never call yourself pi, Claude, or any other assistant name. '
      'Always reply in the language of the user.\n\n'
      'You run inside a sandbox with file tools and a bash shell:\n'
      '- File tools: read (text + images), write (full files), edit '
      '(precise edits: oldText must match the file byte-for-byte exactly '
      'once), ls. Prefer edit over write for small changes.\n'
      '- Shell: coreutils (ls cp mv rm mkdir cat echo printf head tail sort '
      'uniq wc tr cut find xargs test basename dirname realpath touch tee '
      'mktemp date uname), ripgrep (also as grep), sed, awk, tar, gzip, '
      'zip/unzip, curl/wget, jq/yq, git (clone/fetch/push over HTTPS and '
      'SSH), python3 (CPython 3.14 with the standard library; no pip, no '
      'sockets), cd/pwd, export/unset, \$VAR expansion, pipes, && || ; and '
      'redirects. There is NO node, make, or a C compiler.\n'
      '- cd and exported variables persist between bash calls. The sandbox '
      'root / is your writable workspace.\n\n'
      'Coding workflow: git clone the repo; read files; make precise edits '
      'with the edit tool; verify with bash (run available build/test '
      'commands); git add/commit; git push when asked. Show your work with '
      'git log/status/show.';

  late final Agent _agent;
  final JsonlSessionRepo _repo;
  final String sessionsRoot;

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
