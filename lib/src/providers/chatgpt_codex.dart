/// Codex Responses API adapter for a ChatGPT OAuth session.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../session/uuid.dart';
import '../types.dart';
import 'chatgpt_oauth.dart';
import 'codex_transport.dart';
import 'provider_common.dart';

typedef ChatGptCredentialsPersist = FutureOr<void> Function(String encoded);

AssistantMessageEventStream streamChatGptCodex(
  Model model,
  Context context, {
  required String credentials,
  ChatGptCredentialsPersist? onCredentialsRefreshed,
  CancelToken? cancelToken,
  http.Client? client,
}) {
  final events = AssistantMessageEventStream();
  // No injected client: the shared keep-alive client (never closed per call).
  final httpClient = client ?? sharedProviderHttpClient();
  final state = ProviderStreamState(model);
  final session = _ChatGptCodexSession(
    model,
    context,
    credentials,
    onCredentialsRefreshed,
    events,
    state,
    cancelToken,
    httpClient,
  );
  unawaited(
    runProviderStream(
      events,
      state,
      cancelToken,
      httpClient,
      ownsClient: false, // shared or injected — never closed per call
      body: session.run,
    ),
  );
  return events;
}

final class _ChatGptCodexSession {
  _ChatGptCodexSession(
    this.model,
    this.context,
    this.encodedCredentials,
    this.onCredentialsRefreshed,
    this.events,
    this.state,
    this.cancelToken,
    this.client,
  );

  final Model model;
  final Context context;
  final String encodedCredentials;
  final ChatGptCredentialsPersist? onCredentialsRefreshed;
  final AssistantMessageEventStream events;
  final ProviderStreamState state;
  final CancelToken? cancelToken;
  final http.Client client;
  final _SseAccumulator _sse = _SseAccumulator();
  final CodexCookieJar _cookies = CodexCookieJar();

  /// Stable per-turn Codex telemetry ids; retries within the turn reuse
  /// them so the backend can correlate attempts.
  final String _sessionId = uuidv7();
  final String _threadId = uuidv7();

  /// Cookie header value captured before the latest request went out.
  String? _cookiesBeforeRequest;

  Future<void> run() async {
    var credentials = ChatGptOAuthCredentials.decode(encodedCredentials);
    if (credentials.needsRefresh(DateTime.now())) {
      // Proactive: the access token is at/past expiry minus skew.
      credentials = await _refreshCredentials(credentials);
    }
    var refreshedOn401 = false;
    var replayedCookies = false;
    var response = await _request(credentials);
    while (true) {
      if (response.statusCode == 401 && !refreshedOn401) {
        // Reactive backstop: refresh once, persist, retry.
        refreshedOn401 = true;
        await response.stream.drain();
        credentials = await _refreshCredentials(credentials);
        response = await _request(credentials);
        continue;
      }
      if (!_isCloudflareChallenge(response)) break;
      await response.stream.drain();
      if (replayedCookies || !_learnedCookies()) {
        throw StateError(
          'ChatGPT responded with a Cloudflare challenge that cookie '
          'replay could not clear. Re-authenticate with '
          '`fa /provider chatgpt oauth` or retry later.',
        );
      }
      // Replay the freshly learned Cloudflare cookies once.
      replayedCookies = true;
      response = await _request(credentials);
    }
    if (response.statusCode != 200) {
      throw await _httpError(response);
    }
    events.push(StartEvent(partial: state.snapshot()));
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      cancelToken?.throwIfCancelled();
      _sse.add(line, _handleEvent);
    }
    _sse.finish(_handleEvent);
    _finish();
  }

  Uri get _endpoint => Uri.parse('${model.baseUrl}/responses');

  Future<http.StreamedResponse> _request(
    ChatGptOAuthCredentials credentials,
  ) async {
    final uri = _endpoint;
    // Snapshot before the send/store sequence: `_learnedCookies()` must
    // diff against exactly what this request carried, never the post-store
    // jar of the same response.
    final cookieHeader = _cookies.cookieHeader(uri);
    _cookiesBeforeRequest = cookieHeader;
    final request = http.Request('POST', uri)
      ..headers.addAll({
        'content-type': 'application/json',
        'accept': 'text/event-stream',
        ...codexRequestHeaders(
          accessToken: credentials.accessToken,
          accountId: credentials.accountId,
          sessionId: _sessionId,
          threadId: _threadId,
        ),
        'cookie': ?cookieHeader,
        // Model headers go last so they can override the defaults.
        ...?model.headers,
      })
      ..body = jsonEncode(_requestBody());
    final response = await client.send(request);
    // Cloudflare sets its cookies even on error responses — store always.
    _cookies.store(uri, response.headers);
    return response;
  }

  Future<ChatGptOAuthCredentials> _refreshCredentials(
    ChatGptOAuthCredentials credentials,
  ) async {
    final fresh = await refreshChatGptCredentials(credentials, client: client);
    await onCredentialsRefreshed?.call(fresh.encode());
    return fresh;
  }

  /// Whether the response looks like a Cloudflare challenge: outright 403,
  /// or 404/429 carrying a mitigation marker or an HTML body.
  bool _isCloudflareChallenge(http.StreamedResponse response) {
    final status = response.statusCode;
    if (status == 403) return true;
    if (status != 404 && status != 429) return false;
    return _header(response.headers, 'cf-mitigated') != null ||
        (_header(response.headers, 'content-type') ?? '').contains('text/html');
  }

  /// Whether the jar learned a cookie name it did not hold before the last
  /// request — the signal that a retry can carry fresh Cloudflare cookies.
  bool _learnedCookies() {
    final before = _cookiesBeforeRequest;
    final after = _cookies.cookieHeader(_endpoint);
    if (after == null) return false;
    if (before == null) return true;
    final beforeNames = {
      for (final pair in before.split('; ')) pair.split('=').first,
    };
    return after
        .split('; ')
        .any((pair) => !beforeNames.contains(pair.split('=').first));
  }

  /// Case-insensitive header lookup (header casing varies by hop).
  String? _header(Map<String, String> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value;
    }
    return null;
  }

  /// Builds the error for a non-200 response; a 429 carries the Codex
  /// rate-limit reset time when the backend advertises one.
  Future<ProviderHttpError> _httpError(http.StreamedResponse response) async {
    final body = await response.stream.bytesToString();
    var message = body;
    if (response.statusCode == 429) {
      final limits = parseCodexRateLimits(response.headers);
      final resetsAt = limits?.primary?.resetsAt ?? limits?.secondary?.resetsAt;
      if (resetsAt != null) {
        final resets = DateTime.fromMillisecondsSinceEpoch(
          resetsAt * 1000,
          isUtc: true,
        ).toIso8601String();
        message = 'rate limited; resets at $resets\n$body';
      }
    }
    return ProviderHttpError(
      response.statusCode,
      message,
      retryAfter: parseRetryAfter(response.headers['retry-after']),
    );
  }

  Map<String, dynamic> _requestBody() => {
    'model': model.id,
    'stream': true,
    // The ChatGPT Codex backend rejects server-side storage.
    'store': false,
    if (context.systemPrompt?.isNotEmpty ?? false)
      'instructions': context.systemPrompt,
    'input': [
      for (final message in downgradeUnsupportedImages(context.messages, model))
        _inputItem(message),
    ],
    if (context.tools?.isNotEmpty ?? false)
      'tools': [
        for (final tool in context.tools!)
          {
            'type': 'function',
            'name': tool.name,
            'description': tool.description,
            'parameters': tool.parameters,
          },
      ],
  };

  Map<String, dynamic> _inputItem(Message message) {
    if (message is UserMessage) {
      return {'role': 'user', 'content': _inputContent(message.content)};
    }
    if (message is ToolResultMessage) {
      return {
        'type': 'function_call_output',
        'call_id': message.toolCallId,
        'output': [
          for (final item in message.content)
            if (item is TextContent) {'type': 'input_text', 'text': item.text},
        ],
      };
    }
    final assistant = message as AssistantMessage;
    return {
      'role': 'assistant',
      'content': [
        for (final item in assistant.content)
          if (item is TextContent)
            {'type': 'output_text', 'text': item.text}
          else if (item is ToolCall)
            {
              'type': 'function_call',
              'call_id': item.id,
              'name': item.name,
              'arguments': jsonEncode(item.arguments),
            },
      ],
    };
  }

  List<Map<String, dynamic>> _inputContent(Object content) => switch (content) {
    String text => [
      {'type': 'input_text', 'text': text},
    ],
    List<ContentBlock> blocks => [
      for (final block in blocks)
        if (block is TextContent) {'type': 'input_text', 'text': block.text},
    ],
    _ => const [],
  };

  void _handleEvent(String? event, String data) {
    if (data == '[DONE]') return;
    final value = _decodeEvent(data);
    if (value == null) return;
    _dispatchEvent(event ?? value['type'] as String?, value);
  }

  /// Decodes the SSE data into a typed map; null when not a JSON object.
  Map<String, dynamic>? _decodeEvent(String data) {
    final decoded = jsonDecode(data);
    if (decoded is! Map) return null;
    return decoded.cast<String, dynamic>();
  }

  /// Routes the event type to the streaming handler.
  void _dispatchEvent(String? type, Map<String, dynamic> value) {
    if (_handleTextEvent(type, value)) return;
    if (_handleReasoningEvent(type, value)) return;
    if (_handleToolEvent(type, value)) return;
    if (_handleItemEvent(type, value)) return;
    _handleLifecycleEvent(type, value);
  }

  bool _handleTextEvent(String? type, Map<String, dynamic> value) {
    switch (type) {
      case 'response.output_text.delta':
        _textDelta(value['delta'] as String? ?? '');
      case 'response.output_text.done':
        _endText();
      default:
        return false;
    }
    return true;
  }

  bool _handleToolEvent(String? type, Map<String, dynamic> value) {
    switch (type) {
      case 'response.function_call_arguments.delta':
        _toolDelta(value);
      case 'response.function_call_arguments.done':
        _endTool();
      default:
        return false;
    }
    return true;
  }

  /// Reasoning deltas surface as a thinking block; the summary bookkeeping
  /// events carry nothing new for the transcript.
  bool _handleReasoningEvent(String? type, Map<String, dynamic> value) {
    switch (type) {
      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_text.delta':
        _thinkingDelta(value['delta'] as String? ?? '');
      case 'response.reasoning_summary_text.done':
      case 'response.reasoning_summary_part.added':
      case 'response.custom_tool_call_input.delta':
        break;
      default:
        return false;
    }
    return true;
  }

  /// `output_item` events pre-bind blocks (so argument streams without a
  /// `call_id` still bind) and close them out.
  bool _handleItemEvent(String? type, Map<String, dynamic> value) {
    switch (type) {
      case 'response.output_item.added':
        final item = value['item'];
        if (item is Map && item['type'] == 'function_call') {
          _ensureTool(
            item['call_id'] as String? ?? '',
            item['name'] as String? ?? '',
          );
        }
      case 'response.output_item.done':
        final item = value['item'];
        if (item is Map) {
          switch (item['type']) {
            case 'function_call':
              _endTool();
            case 'message':
              _endText();
          }
        }
      default:
        return false;
    }
    return true;
  }

  void _handleLifecycleEvent(String? type, Map<String, dynamic> value) {
    switch (type) {
      case 'response.created':
      case 'response.in_progress':
      case 'response.completed':
        _setResponse(value['response']);
      case 'response.failed':
        _handleFailed(value);
      case 'response.incomplete':
        _handleIncomplete(value);
    }
  }

  /// Terminal mid-stream failure: close the in-flight blocks so partial
  /// text stays visible, record the error on the state, and throw —
  /// `runProviderStream` converts the throw into the terminal `ErrorEvent`
  /// (errors-as-events invariant; the same termination path the OpenAI and
  /// Anthropic adapters use). Nothing escapes the adapter.
  Never _terminateWithError(String message) {
    _endThinking();
    _endText();
    _endTool();
    state
      ..stopReason = StopReason.error
      ..errorMessage = message;
    throw StateError(message);
  }

  /// Extracts the error message from a `response.failed` payload and ends
  /// the stream as a terminal error.
  Never _handleFailed(Map<String, dynamic> value) {
    final response = value['response'];
    final error = response is Map ? response['error'] : null;
    _terminateWithError(
      error is Map
          ? '${error['message'] ?? 'ChatGPT response failed'}'
          : 'ChatGPT response failed',
    );
  }

  /// `response.incomplete` is terminal: the turn ended early (token cap,
  /// content filter) and never completed.
  Never _handleIncomplete(Map<String, dynamic> value) {
    final response = value['response'];
    final details = response is Map ? response['incomplete_details'] : null;
    final reason = details is Map ? details['reason'] as String? : null;
    _terminateWithError(
      'ChatGPT response incomplete '
      '(${reason?.isNotEmpty == true ? reason : 'unknown'})',
    );
  }

  void _setResponse(Object? raw) {
    if (raw is! Map) return;
    state.responseId = raw['id'] as String? ?? state.responseId;
    state.responseModel = raw['model'] as String? ?? state.responseModel;
    final usage = raw['usage'];
    if (usage is Map) {
      final input = usage['input_tokens'] as int? ?? 0;
      final output = usage['output_tokens'] as int? ?? 0;
      state.usage = Usage(
        input: input,
        output: output,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: usage['total_tokens'] as int? ?? input + output,
        cost: const UsageCost(),
      );
    }
  }

  TextStreamingBlock? _text;
  ToolCallStreamingBlock? _tool;
  ThinkingStreamingBlock? _thinking;
  TextStreamingBlock _ensureText() {
    final existing = _text;
    if (existing != null) return existing;
    final block = TextStreamingBlock();
    _text = block;
    state.blocks.add(block);
    events.push(
      TextStartEvent(
        contentIndex: state.blocks.length - 1,
        partial: state.snapshot(),
      ),
    );
    return block;
  }

  void _textDelta(String delta) {
    if (delta.isEmpty) return;
    final block = _ensureText();
    block.text.write(delta);
    events.push(
      TextDeltaEvent(
        contentIndex: state.blocks.indexOf(block),
        delta: delta,
        partial: state.snapshot(),
      ),
    );
  }

  void _endText() {
    final block = _text;
    if (block != null) {
      pushBlockEndEvent(events, state.blocks, block, state.snapshot);
    }
    _text = null;
  }

  ToolCallStreamingBlock _ensureTool(String id, String name) {
    final existing = _tool;
    if (existing != null) return existing;
    final block = ToolCallStreamingBlock(id: id, name: name);
    _tool = block;
    state.blocks.add(block);
    events.push(
      ToolCallStartEvent(
        contentIndex: state.blocks.length - 1,
        partial: state.snapshot(),
      ),
    );
    return block;
  }

  void _toolDelta(Map<String, dynamic> value) {
    final block = _ensureTool(
      value['call_id'] as String? ?? '',
      value['name'] as String? ?? '',
    );
    final delta = value['delta'] as String? ?? '';
    block.partialArgs.write(delta);
    events.push(
      ToolCallDeltaEvent(
        contentIndex: state.blocks.indexOf(block),
        delta: delta,
        partial: state.snapshot(),
      ),
    );
  }

  ThinkingStreamingBlock _ensureThinking() {
    final existing = _thinking;
    if (existing != null) return existing;
    final block = ThinkingStreamingBlock();
    _thinking = block;
    state.blocks.add(block);
    events.push(
      ThinkingStartEvent(
        contentIndex: state.blocks.length - 1,
        partial: state.snapshot(),
      ),
    );
    return block;
  }

  void _thinkingDelta(String delta) {
    if (delta.isEmpty) return;
    final block = _ensureThinking();
    block.thinking.write(delta);
    events.push(
      ThinkingDeltaEvent(
        contentIndex: state.blocks.indexOf(block),
        delta: delta,
        partial: state.snapshot(),
      ),
    );
  }

  void _endThinking() {
    final block = _thinking;
    if (block != null) {
      pushBlockEndEvent(events, state.blocks, block, state.snapshot);
    }
    _thinking = null;
  }

  void _endTool() {
    final block = _tool;
    if (block != null) {
      pushBlockEndEvent(events, state.blocks, block, state.snapshot);
    }
    _tool = null;
  }

  void _finish() {
    _endThinking();
    _endText();
    _endTool();
    state.stopReason =
        state.blocks.any((block) => block is ToolCallStreamingBlock)
        ? StopReason.toolUse
        : StopReason.stop;
    events.push(DoneEvent(reason: state.stopReason, message: state.snapshot()));
  }
}

final class _SseAccumulator {
  String? _event;
  final _data = <String>[];
  void add(String line, void Function(String?, String) onEvent) {
    if (line.isEmpty) {
      _emit(onEvent);
      return;
    }
    if (line.startsWith('event:')) _event = line.substring(6).trim();
    if (line.startsWith('data:')) _data.add(line.substring(5).trimLeft());
  }

  void finish(void Function(String?, String) onEvent) => _emit(onEvent);
  void _emit(void Function(String?, String) onEvent) {
    if (_data.isNotEmpty) onEvent(_event, _data.join('\n'));
    _event = null;
    _data.clear();
  }
}
