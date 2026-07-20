import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'env_factory.dart';
import 'gemma/gemma_service.dart';
import 'gemma/gemma_stream_function.dart';
import 'gemma/gemma_types.dart';
import 'prompts.g.dart';
import 'sandbox_registry.dart';
import 'secrets_store.dart';
import 'transformers_js/transformers_js_service.dart';
import 'transformers_js/transformers_js_stream_function.dart';
import 'transformers_js/transformers_js_types.dart';
import 'upload.dart';
import 'webllm/webllm_service.dart';
import 'webllm/webllm_stream_function.dart';
import 'webllm/webllm_types.dart';

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
    this.contextWindow = 128000,
    this.maxTokens = 4096,
  });

  /// Provider adapter kind: `openai-completions`, `anthropic`, `google`,
  /// `webllm` (on-device, web — see `lib/webllm/`), `gemma` (on-device,
  /// iOS/Android — see `lib/gemma/`), or `transformers_js` (on-device, web —
  /// see `lib/transformers_js/`).
  final String providerKind;

  /// Model id passed to the provider.
  final String modelId;

  /// Provider base URL (e.g. OpenRouter `https://openrouter.ai/api/v1`).
  /// Empty for on-device providers.
  final String baseUrl;

  /// API key for the provider. Empty for on-device providers.
  final String apiKey;

  /// Optional system prompt override.
  final String? systemPrompt;

  /// Context window reported to the agent loop (drives overflow/compaction
  /// heuristics). Small for on-device models.
  final int contextWindow;

  /// Output-token cap reported to the agent loop.
  final int maxTokens;

  Model toModel() => Model(
    id: modelId,
    name: modelId,
    api: providerKind,
    provider: providerKind,
    baseUrl: baseUrl,
    contextWindow: contextWindow,
    maxTokens: maxTokens,
  );
}

/// Shown in place of an assistant bubble when a completed turn produced
/// neither text nor tool calls — a small on-device model occasionally
/// returns an empty completion, and a blank bubble looks like a UI bug.
/// UI-only: the persisted session message keeps its real (empty) content.
const emptyResponsePlaceholder = '(empty response — try again)';

/// A chat attachment already staged in the sandbox (see
/// [AgentService.stageAttachment]): [path] is the env-relative path the
/// outgoing message references; raster image attachments (see
/// [isInlineImageMimeType] — PNG/JPEG/GIF/WebP, never SVG) additionally
/// ride along inline for hosted providers.
typedef StagedAttachment = ({String path, Uint8List bytes, String mimeType});

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
    _responseTimeout = const Duration(seconds: 90);
    _providerKind = _agent.state.model.provider;
    _redactor = redactor;
    _attachRedactor(redactor);
    _attachApproval();
    _agent.subscribe(_onAgentEvent);
  }

  /// Convenience factory that creates the right [ExecutionEnv] for the
  /// platform and wires up the agent.
  ///
  /// [env] overrides the platform env — the app passes its shared instance
  /// so the provider registry and the agent (and, on web, the IndexedDB
  /// snapshot persistence) all operate on one filesystem.
  static Future<AgentService> create({
    required AgentConfig config,
    ExecutionEnv? env,
  }) async {
    final resolvedEnv = env ?? await createPlatformEnv();
    final secretsStore = createSecretsStore();
    final secrets = await secretsStore.readAll();
    final redactor = SecretRedactor.fromSecrets(secrets);
    return AgentService._withEnv(
      env: secrets.isEmpty
          ? resolvedEnv
          : SecretsExecutionEnv(resolvedEnv, secrets),
      config: config,
      redactor: redactor,
      webSearchConfig: WebSearchConfig(secrets: secretsStore),
    );
  }

  AgentService._withEnv({
    required this.env,
    required AgentConfig config,
    SecretRedactor? redactor,
    WebSearchConfig? webSearchConfig,
  }) : sessionsRoot = '${env.cwd}/sessions',
       _repo = JsonlSessionRepo(fs: env, sessionsRoot: '${env.cwd}/sessions') {
    _providerKind = config.providerKind;
    _redactor = redactor;
    _responseTimeout = _isOnDeviceKind(config.providerKind)
        // First on-device generation compiles WebGPU shaders (WebLLM,
        // transformers.js) or loads multi-GB weights into memory (Gemma),
        // which can take minutes; hosted providers keep the tight timeout.
        ? const Duration(minutes: 10)
        : const Duration(seconds: 90);
    // On-device backends have small context windows; keep only the core
    // coding tools so the tool-instruction block stays small.
    final isOnDevice = _isOnDeviceKind(config.providerKind);
    _agent = Agent(
      model: config.toModel(),
      systemPrompt: _effectiveSystemPrompt(config, redactor),
      streamFunction: _streamFunctionFor(config),
      toolRegistry: ToolRegistry([
        ...builtinTools(
          env,
          webSearch: isOnDevice ? null : webSearchConfig,
          model: () => _agent.state.model,
        ),
        askTool(callback: _answerAskQuestions),
      ]),
    );
    _attachRedactor(redactor);
    _attachApproval();
    _agent.subscribe(_onAgentEvent);
  }

  /// Whether [providerKind] is an on-device backend (WebLLM, Gemma, or
  /// transformers.js), which needs the relaxed response timeout.
  static bool _isOnDeviceKind(String providerKind) =>
      providerKind == webLlmProviderKind ||
      providerKind == gemmaProviderKind ||
      providerKind == transformersJsProviderKind;

  /// Picks the stream function for [config]'s backend: the on-device
  /// bridges for `webllm`/`gemma`/`transformers_js`, the HTTP adapters
  /// otherwise.
  static StreamFunction _streamFunctionFor(AgentConfig config) {
    if (config.providerKind == webLlmProviderKind) {
      return webLlmStreamFunction(createWebLlmService());
    }
    if (config.providerKind == gemmaProviderKind) {
      return gemmaStreamFunction(createGemmaService());
    }
    if (config.providerKind == transformersJsProviderKind) {
      return transformersJsStreamFunction(createTransformersJsService());
    }
    return providerStreamFunction(config.providerKind, config.apiKey);
  }

  /// The system prompt plus a secret-name hint (names only, never values).
  ///
  /// The `{{commands}}` placeholder is filled from the central sandbox
  /// registry ([formatSandboxCommandSection]) for the current platform, so
  /// the model sees exactly the shell commands that exist here.
  static String _effectiveSystemPrompt(
    AgentConfig config,
    SecretRedactor? redactor,
  ) {
    final base = (config.systemPrompt ?? sandboxSystemPrompt).replaceAll(
      '{{commands}}',
      formatSandboxCommandSection(_sandboxPlatform),
    );
    final names = redactor?.names ?? const <String>[];
    if (names.isEmpty) return base;
    return '$base\n\nAvailable secret env vars: ${names.join(', ')} — '
        'reference them as \$NAME in shell commands; never ask the user for '
        'their values and never print them.';
  }

  /// The platform whose commands the system prompt advertises, decided with
  /// the same signal [createPlatformEnv] uses to pick the [ExecutionEnv]:
  /// web → mobile → desktop.
  static SandboxPlatform get _sandboxPlatform => isWebPlatform
      ? SandboxPlatform.web
      : isMobile
      ? SandboxPlatform.mobile
      : SandboxPlatform.desktop;

  /// Exposes [_effectiveSystemPrompt] to tests.
  @visibleForTesting
  static String effectiveSystemPromptForTest(
    AgentConfig config,
    SecretRedactor? redactor,
  ) => _effectiveSystemPrompt(config, redactor);

  /// Composes redaction hooks onto the agent so secret values never reach
  /// the model, the transcript, or the session files.
  void _attachRedactor(SecretRedactor? redactor) {
    if (redactor == null || redactor.isEmpty) return;
    attachSecretRedactor(_agent, redactor);
  }

  /// Attaches the approval gate. The prompt surface is [approvalPromptHandler]
  /// — installed by the chat screen, which owns a [BuildContext]; until then
  /// (and whenever it is unset) prompt-policy calls are denied, the safe
  /// default for a sandbox.
  void _attachApproval() {
    approval.prompt = (request) {
      final handler = approvalPromptHandler;
      if (handler == null) return ApprovalDecision.deny;
      return handler(request);
    };
    attachApproval(_agent, approval);
  }

  /// The approval gate attached to the agent. Default mode is
  /// [ApprovalMode.write] — read-only tools run freely, mutating and shell
  /// tools prompt — switchable at runtime via [setApprovalMode] (settings
  /// dialog) and persisted nowhere (session-scoped).
  final ApprovalManager approval = ApprovalManager(mode: ApprovalMode.write);

  /// UI hook rendering the approval prompt (the chat screen installs a
  /// Material dialog). `null` → prompt-policy calls are denied.
  ApprovalPrompt? approvalPromptHandler;

  /// UI hook rendering the ask tool's questions (the chat screen installs a
  /// Material bottom sheet). `null` → ask calls resolve as cancelled, the
  /// safe headless default.
  AskCallback? askHandler;

  /// Routes the ask tool's questions to the installed [askHandler].
  Future<List<AskAnswer>?> _answerAskQuestions(
    List<AskQuestion> questions,
  ) async {
    final handler = askHandler;
    if (handler == null) return null;
    return handler(questions);
  }

  /// Exposes the agent's registered tools to tests (ask-tool wiring checks).
  @visibleForTesting
  List<Tool> get toolsForTest => _agent.state.tools;

  /// Switches the approval mode (settings dialog's mode selector).
  void setApprovalMode(ApprovalMode mode) {
    if (approval.mode == mode) return;
    approval.mode = mode;
    notifyListeners();
  }

  late final Agent _agent;

  /// Response deadline for one agent run; 10 minutes for the on-device
  /// providers (WebLLM's and transformers.js's first run compiles WebGPU
  /// shaders; Gemma loads multi-GB weights), 90 s otherwise.
  /// Reassigned by [reconfigure] when the backend kind changes.
  late Duration _responseTimeout;
  final JsonlSessionRepo _repo;
  final String sessionsRoot;

  /// Provider adapter kind of the active backend (`openai-completions`,
  /// `webllm`, ...). Updated by [reconfigure].
  String get providerKind => _providerKind;
  late String _providerKind;

  /// Model id of the active backend (shorthand for the agent's current
  /// model; updated by [reconfigure]).
  String get modelId => _agent.state.model.id;

  /// Redactor captured at construction so [reconfigure] can rebuild the
  /// system prompt's secret-name hint.
  SecretRedactor? _redactor;

  /// The execution environment the agent's tools (and session storage) run
  /// against. Exposed so UI affordances — the file browser — show the exact
  /// filesystem the agent works in. Typed as the [ExecutionEnv] abstraction,
  /// never a concrete env, so alternative backends (in-memory web FS, cloud
  /// drives) drop in without UI changes.
  final ExecutionEnv env;

  final List<FahChatMessage> messages = [];
  bool isStreaming = false;
  String? error;

  /// Builtin tools whose completion may mean the sandbox filesystem changed
  /// (the actual tool names in `builtinTools`: `write`, `edit`, `bash`).
  /// `bash` is included because a shell command can touch arbitrary files;
  /// failed results still bump — a partially-run command may have mutated
  /// files before failing.
  static const _kMutatingToolNames = {'write', 'edit', 'bash'};

  /// Filesystem revision: bumped whenever a mutating tool
  /// ([_kMutatingToolNames]) finishes, so UI watching the sandbox (the file
  /// browser) can auto-refresh instead of polling. Listeners must tolerate
  /// false positives — a bump does not prove a specific file changed.
  final ValueNotifier<int> fsRevision = ValueNotifier<int>(0);

  Session? _session;
  String? _sessionId;
  int _persistedCount = 0;
  FahChatMessage? _currentAssistantMessage;

  /// Id of the session new messages persist to (`null` until [initialize]).
  String? get currentSessionId => _sessionId;

  /// Initializes session persistence.
  Future<void> initialize() async {
    final session = await _repo.create(
      JsonlSessionCreateOptions(
        cwd: _agent.state.model.provider,
        metadata: {
          'agent': 'flutter_agent_example',
          'model': _agent.state.model.id,
        },
      ),
    );
    _session = session;
    _sessionId = (await session.getMetadata()).id;
  }

  /// Sends a plain-text user message.
  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) return;
    _addUserMessage(text: text);
    _clearError();
    _runWithTimeout(() => _agent.prompt(text));
  }

  /// Directory (relative to [env]'s working directory) where chat
  /// attachments are staged before the outgoing message references them.
  static const String uploadsDir = 'uploads';

  /// Whether the active provider accepts inline image content: hosted
  /// providers do; the on-device text-only backends (WebLLM, Gemma,
  /// transformers.js) get file paths only, never [ImageContent].
  bool get inlinesImageAttachments => !_isOnDeviceKind(providerKind);

  /// Stages a chat attachment into [uploadsDir] inside the sandbox,
  /// creating the directory and de-duplicating the file name on collision
  /// (`report.pdf` → `report-1.pdf` → …). Returns the env-relative path
  /// (`uploads/report.pdf`) the outgoing message should reference.
  ///
  /// Throws [StateError] with a readable message when nothing was written —
  /// callers must surface it (a snackbar), never fail silently.
  Future<String> stageAttachment({
    required String name,
    required Uint8List bytes,
  }) async {
    // A picked name can carry browser-supplied subdirectories
    // (webkitRelativePath); chat attachments flatten into uploads/.
    final base = sanitizeUploadName(name).split('/').last;
    if (base.isEmpty) {
      throw StateError('"$name" has no usable file name.');
    }
    final dirResult = await env.createDir(uploadsDir);
    if (dirResult.isErr) {
      throw StateError(
        'Could not create $uploadsDir: ${dirResult.errorOrNull!.message}',
      );
    }
    var candidate = '$uploadsDir/$base';
    for (var n = 1; (await env.exists(candidate)).valueOrNull ?? false; n++) {
      candidate = '$uploadsDir/${_dedupeName(base, n)}';
    }
    final writeResult = await env.writeBinaryFile(candidate, bytes);
    if (writeResult.isErr) {
      throw StateError(
        'Could not store $base: ${writeResult.errorOrNull!.message}',
      );
    }
    return candidate;
  }

  /// `name.ext` → `name-1.ext` for n = 1; names without an extension get
  /// the suffix appended whole.
  static String _dedupeName(String name, int n) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '$name-$n';
    return '${name.substring(0, dot)}-$n${name.substring(dot)}';
  }

  /// Best-effort delete of a file staged via [stageAttachment] — used when
  /// a pending attachment chip is removed before sending. Only paths inside
  /// [uploadsDir] qualify; failures are ignored (the file is small and the
  /// sandbox is ephemeral).
  Future<void> discardStagedAttachment(String path) async {
    if (!path.startsWith('$uploadsDir/')) return;
    try {
      await env.remove(path);
    } on Object {
      // Best effort: a leftover file in uploads/ is harmless.
    }
  }

  /// Sends a user message referencing files staged via [stageAttachment]:
  /// the text names each sandbox path so the agent reads the file with its
  /// tools, followed by the user's typed text. Raster image attachments
  /// ([isInlineImageMimeType]) are additionally inlined as [ImageContent]
  /// when the active provider is a hosted one ([inlinesImageAttachments]);
  /// SVG and other non-decodable types always travel as path references
  /// only, and on-device text-only backends receive the paths only.
  Future<void> sendAttachments({
    required List<StagedAttachment> attachments,
    String text = '',
  }) async {
    if (attachments.isEmpty) return sendText(text);
    final fullText = [
      for (final attachment in attachments)
        '[attached file: ${attachment.path} — read it with your tools]',
      if (text.trim().isNotEmpty) text.trim(),
    ].join('\n');
    final images = [
      for (final attachment in attachments)
        if (isInlineImageMimeType(attachment.mimeType)) attachment,
    ];
    final inline = images.isNotEmpty && inlinesImageAttachments;
    _addUserMessage(
      text: fullText,
      imageBytes: inline ? images.first.bytes : null,
      mimeType: inline ? images.first.mimeType : null,
    );
    _clearError();
    if (!inline) {
      _runWithTimeout(() => _agent.prompt(fullText));
      return;
    }
    _runWithTimeout(
      () => _agent.promptMessage(
        UserMessage(
          content: [
            TextContent(text: fullText),
            for (final image in images)
              ImageContent(
                data: base64Encode(image.bytes),
                mimeType: image.mimeType,
              ),
          ],
          timestamp: DateTime.now(),
        ),
      ),
    );
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
      () => _agent.promptMessage(
        UserMessage(content: content, timestamp: DateTime.now()),
      ),
    );
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
      run = startRun();
    } on Object catch (e) {
      isStreaming = false;
      error = e is StateError ? e.message : e.toString();
      notifyListeners();
      return;
    }
    run
        .timeout(
          _responseTimeout,
          onTimeout: () {
            abort();
            throw TimeoutException(
              'The model did not respond within '
              '${_responseTimeout.inSeconds} seconds.',
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

  @override
  void dispose() {
    fsRevision.dispose();
    super.dispose();
  }

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

  /// Switches the backend (provider/model/key) for subsequent messages while
  /// keeping the visible transcript and the current session.
  ///
  /// Any in-flight run is aborted first and awaited, so no zombie stream
  /// survives the switch; the deliberate abort's error banner is cleared.
  /// The [Agent] itself is reused — only its model, system prompt, and
  /// stream function are swapped — so tool wiring and the transcript live
  /// on. For WebLLM the settings form has already run `loadModel` (the
  /// engine is a singleton), so the new stream function reuses the warm
  /// instance. The switch is recorded as a `model_change` session record.
  Future<void> reconfigure(AgentConfig config) async {
    abort();
    await waitForIdle();
    _agent.state.model = config.toModel();
    _agent.state.systemPrompt = _effectiveSystemPrompt(config, _redactor);
    _agent.streamFunction = _streamFunctionFor(config);
    _providerKind = config.providerKind;
    _responseTimeout = _isOnDeviceKind(config.providerKind)
        ? const Duration(minutes: 10)
        : const Duration(seconds: 90);
    error = null;
    notifyListeners();
    // Best effort: a failed marker write must not break the switch.
    try {
      await _session?.appendModelChange(
        provider: config.providerKind,
        modelId: config.modelId,
      );
    } on Object {
      // Session persistence is best effort here.
    }
  }

  /// Lists persisted sessions, newest first (across all provider dirs under
  /// [sessionsRoot]). Cheap: reads only the JSONL headers.
  Future<List<SessionMetadata>> listSessions() => _repo.list();

  /// Loads a persisted session into the chat: the agent's context and the
  /// visible transcript are replaced by the session's active branch, and new
  /// messages append to that session.
  Future<void> loadSession(SessionMetadata metadata) async {
    abort();
    await waitForIdle();
    final session = await _repo.open(metadata);
    final contextMessages = await session.buildContextMessages();
    _agent.reset();
    _agent.state.messages = contextMessages;
    _session = session;
    _sessionId = metadata.id;
    _persistedCount = contextMessages.length;
    _currentAssistantMessage = null;
    error = null;
    messages
      ..clear()
      ..addAll(contextMessages.map(_toChatMessage));
    notifyListeners();
  }

  /// Deletes a persisted session. Deleting the ACTIVE session starts a new
  /// empty one, so the chat never points at a removed file.
  Future<void> deleteSession(SessionMetadata metadata) async {
    final isActive = metadata.id == _sessionId;
    if (isActive) {
      // Stop any in-flight run and let its persistence settle before the
      // session file disappears underneath it.
      abort();
      await waitForIdle();
    }
    await _repo.delete(metadata);
    if (isActive) await reset();
  }

  /// Projects a persisted context [Message] back into the UI transcript.
  static FahChatMessage _toChatMessage(Message message) {
    switch (message) {
      case UserMessage(:final content):
        if (content is String) {
          return FahChatMessage(role: 'user', content: content);
        }
        final blocks = content as List<ContentBlock>;
        Uint8List? imageBytes;
        for (final block in blocks.whereType<ImageContent>()) {
          imageBytes = base64Decode(block.data);
          break;
        }
        return FahChatMessage(
          role: 'user',
          content: blocks
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n'),
          imageBytes: imageBytes,
        );
      case AssistantMessage(:final content):
        return FahChatMessage(
          role: 'assistant',
          content: content.whereType<TextContent>().map((b) => b.text).join(),
        );
      case ToolResultMessage(:final content, :final toolName, :final isError):
        return FahChatMessage(
          role: 'tool',
          content: content
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n'),
          toolName: toolName,
          isError: isError,
        );
      default:
        return FahChatMessage(role: 'system', content: message.toString());
    }
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
        if (_kMutatingToolNames.contains(toolName)) {
          // "Hook" for file-watching UI: the agent may have changed files.
          fsRevision.value++;
        }
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
        await _maybeAutoCompact();
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
    var text = message.content
        .whereType<TextContent>()
        .map((b) => b.text)
        .join();
    final hasToolCalls = message.content.any((block) => block is ToolCall);
    if (text.trim().isEmpty &&
        !hasToolCalls &&
        message.stopReason != StopReason.error &&
        message.stopReason != StopReason.aborted) {
      // A completed turn with neither text nor tool calls (small on-device
      // models do this) must not render as a blank bubble.
      text = emptyResponsePlaceholder;
    }
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

  /// Compaction thresholds for the active model, scaled by
  /// [CompactionSettings.forWindow] to the conversation window (the model's
  /// context window minus the system-prompt overhead). pi's fixed defaults
  /// exceed the whole window of an on-device model, so the same settings
  /// cannot serve hosted 128k models and 8k WebLLM presets.
  CompactionSettings get compactionSettings =>
      CompactionSettings.forWindow(_conversationWindow);

  /// The window left for the conversation after [_systemOverheadTokens];
  /// `0` when the prompt alone exhausts the model window (compaction then
  /// has nothing sensible to plan against).
  int get _conversationWindow {
    final window = _agent.state.model.contextWindow - _systemOverheadTokens;
    return window > 0 ? window : 0;
  }

  /// Estimated tokens the provider counts against the context window on top
  /// of the transcript: the rendered system prompt plus — for the chat-only
  /// on-device backends (WebLLM, transformers.js), whose stream functions
  /// run through the prompt-tools wrapper — the tool instructions appended
  /// to that prompt. The wrapper's instruction block outweighs the base
  /// system prompt several times over, so ignoring it would size compaction
  /// against a window the engine does not actually have.
  int get _systemOverheadTokens {
    var system = _agent.state.systemPrompt;
    if (_providerKind == webLlmProviderKind ||
        _providerKind == transformersJsProviderKind) {
      system = '$system\n\n${promptToolInstructions(_agent.state.tools)}';
    }
    return estimateTokens(UserMessage.text(system));
  }

  /// Auto-compaction after each completed run (CLI parity): when the
  /// estimated transcript crosses the scaled threshold, the oldest history
  /// is summarized so the next engine call still fits the window. Best
  /// effort — a failure leaves the history untouched and a later turn
  /// retries.
  Future<void> _maybeAutoCompact() async {
    final conversationWindow = _conversationWindow;
    if (_session == null || conversationWindow <= 0) return;
    final settings = compactionSettings;
    final transcriptTokens = estimateContextTokens(
      _agent.state.messages,
    ).tokens;
    if (!shouldCompact(transcriptTokens, conversationWindow, settings)) {
      return;
    }
    // The whole transcript fits in the kept region: compaction could not
    // drop anything. (A single oversized message can still overflow the
    // engine — that surfaces as a readable run error, not a compaction
    // loop.)
    if (transcriptTokens <= settings.keepRecentTokens) return;
    await _compact(settings);
  }

  Future<void> _compact(CompactionSettings settings) async {
    final session = _session;
    if (session == null) return;
    try {
      final manager = CompactionManager(
        summarize: streamFunctionSummarizer(
          _agent.streamFunction,
          _agent.state.model,
        ),
        settings: settings,
      );
      final record = await manager.compactSession(session);
      if (record == null) return;
      // Replace the in-memory transcript (and its UI projection) with the
      // session's compacted context, mirroring loadSession.
      _agent.state.messages = await session.buildContextMessages();
      _persistedCount = _agent.state.messages.length;
      messages
        ..clear()
        ..addAll(_agent.state.messages.map(_toChatMessage));
      notifyListeners();
    } on Object {
      // Best effort, like persistence: a failed compaction must not leak
      // into the agent's event plumbing; the next turn retries.
    }
  }
}
