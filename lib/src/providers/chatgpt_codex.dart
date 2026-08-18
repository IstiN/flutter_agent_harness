/// Codex Responses API adapter for a ChatGPT OAuth session.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../types.dart';
import 'chatgpt_oauth.dart';
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
  final httpClient = client ?? http.Client();
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
      ownsClient: client == null,
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

  Future<void> run() async {
    // ChatGPT Codex speaks WebSocket with Codex-specific headers
    // (x-openai-internal-codex-responses-lite, responses_websockets=
    // 2026-02-06, …) — plain HTTP POST returns 404 from the Codex
    // backend. Rather than surfacing the 404 to the user as if the
    // provider broke, emit a clear 'not yet supported' error so the
    // user knows to pick another provider until we build the WebSocket
    // adapter.
    var credentials = ChatGptOAuthCredentials.decode(encodedCredentials);
    var response = await _request(credentials);
    if (response.statusCode == 401) {
      await response.stream.drain();
      credentials = await refreshChatGptCredentials(
        credentials,
        client: client,
      );
      await onCredentialsRefreshed?.call(credentials.encode());
      response = await _request(credentials);
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      if (response.statusCode == 404) {
        throw StateError(
          'ChatGPT Codex is not supported yet — the backend requires a '
          'WebSocket connection with Codex-specific headers '
          '(x-openai-internal-codex-responses-lite). Plain HTTP /responses '
          'returns 404. Please pick another provider (OpenRouter, OpenAI, '
          'CodeMie, …) until the Codex WebSocket adapter ships.',
        );
      }
      throw ProviderHttpError(
        response.statusCode,
        body,
        retryAfter: parseRetryAfter(response.headers['retry-after']),
      );
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

  Future<http.StreamedResponse> _request(ChatGptOAuthCredentials credentials) {
    final request =
        http.Request('POST', Uri.parse('${model.baseUrl}/responses'))
          ..headers.addAll({
            'content-type': 'application/json',
            'accept': 'text/event-stream',
            'authorization': 'Bearer ${credentials.accessToken}',
            if (credentials.accountId != null)
              'ChatGPT-Account-ID': credentials.accountId!,
            ...?model.headers,
          })
          ..body = jsonEncode(_requestBody());
    return client.send(request);
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
    if (_handleToolEvent(type, value)) return;
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

  void _handleLifecycleEvent(String? type, Map<String, dynamic> value) {
    switch (type) {
      case 'response.created':
      case 'response.in_progress':
      case 'response.completed':
        _setResponse(value['response']);
      case 'response.failed':
        _handleFailed(value);
    }
  }

  /// Extracts the error message from a `response.failed` payload and throws.
  Never _handleFailed(Map<String, dynamic> value) {
    final response = value['response'];
    final error = response is Map ? response['error'] : null;
    throw StateError(
      error is Map
          ? error['message'] ?? 'ChatGPT response failed'
          : 'ChatGPT response failed',
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

  void _toolDelta(Map<String, dynamic> value) {
    var block = _tool;
    if (block == null) {
      block = ToolCallStreamingBlock(
        id: value['call_id'] as String? ?? '',
        name: value['name'] as String? ?? '',
      );
      _tool = block;
      state.blocks.add(block);
      events.push(
        ToolCallStartEvent(
          contentIndex: state.blocks.length - 1,
          partial: state.snapshot(),
        ),
      );
    }
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

  void _endTool() {
    final block = _tool;
    if (block != null) {
      pushBlockEndEvent(events, state.blocks, block, state.snapshot);
    }
    _tool = null;
  }

  void _finish() {
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
