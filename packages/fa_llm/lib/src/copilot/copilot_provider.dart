import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../llm_message.dart';
import '../llm_provider.dart';

/// One model from `GET /models`.
class CopilotModelInfo {
  final String id;

  /// `capabilities.limits.max_context_window_tokens`, if exposed.
  final int? maxContextWindowTokens;

  /// `capabilities.limits.max_output_tokens`, if exposed.
  final int? maxOutputTokens;

  /// e.g. `/chat/completions`, `/responses` — presence of `/responses`
  /// means the model speaks the Responses API.
  final List<String> supportedEndpoints;

  const CopilotModelInfo({
    required this.id,
    this.maxContextWindowTokens,
    this.maxOutputTokens,
    this.supportedEndpoints = const [],
  });
}

/// A failed Copilot API call.
class CopilotChatException implements Exception {
  final int statusCode;
  final String message;

  const CopilotChatException(this.statusCode, this.message);

  @override
  String toString() => 'CopilotChatException($statusCode): $message';
}

/// Splits an SSE byte-text stream into complete `data:` payloads,
/// buffering incomplete frames until their terminating newline.
class SseParser {
  final StringBuffer _buffer = StringBuffer();

  List<String> push(String chunk) {
    _buffer.write(chunk);
    final lines = _buffer.toString().split('\n');
    _buffer
      ..clear()
      ..write(lines.removeLast());
    return [
      for (final line in lines)
        if (line.startsWith('data:')) line.substring(5).trim(),
    ];
  }
}

/// Extracts `choices[0].delta.content` from one SSE data payload.
/// Returns null for `[DONE]`, missing content, or unparsable data.
String? sseDeltaContent(String data) {
  if (data == '[DONE]') return null;
  try {
    final json = jsonDecode(data);
    if (json is! Map<String, dynamic>) return null;
    final choices = json['choices'] as List?;
    if (choices == null || choices.isEmpty) return null;
    final delta = choices.first['delta'] as Map<String, dynamic>?;
    final content = delta?['content'];
    return content is String ? content : null;
  } on FormatException {
    return null;
  }
}

/// LlmProvider over the GitHub Copilot Chat Completions API.
///
/// Headers follow copilot-proxy-go `internal/api/config.go:
/// BuildCopilotHeaders` plus per-request `X-Initiator` /
/// `Copilot-Vision-Request` (`internal/service/copilot.go`).
class CopilotProvider implements LlmProvider {
  static const _editorVersion = 'vscode/1.109.3';
  static const _pluginVersion = 'copilot-chat/0.37.6';
  static const _apiVersion = '2025-10-01';

  final Future<String> Function() token;

  /// Refresh path used after 401/403 (e.g. token manager getAgain);
  /// defaults to [token].
  final Future<String> Function() refresh;
  final String baseUrl;
  @override
  final String defaultModel;
  final int? maxTokens;
  final http.Client _client;

  StreamSubscription<List<int>>? _activeSubscription;

  CopilotProvider({
    required this.token,
    Future<String> Function()? refresh,
    required this.baseUrl,
    required this.defaultModel,
    this.maxTokens,
    http.Client? client,
  }) : refresh = refresh ?? token,
       _client = client ?? http.Client();

  /// Mandatory Copilot API headers plus per-request semantics:
  /// `X-Initiator` is `agent` when the last message role is
  /// assistant/tool (continuation), else `user`;
  /// `Copilot-Vision-Request` is sent only for image input.
  Map<String, String> _headers({
    required String copilotToken,
    required List<LlmMessage> messages,
  }) {
    final lastRole = messages.isEmpty ? '' : messages.last.role;
    final isAgent = lastRole == 'assistant' || lastRole == 'tool';
    final hasImages = messages.any(
      (m) => m.images != null && m.images!.isNotEmpty,
    );
    return {
      'Authorization': 'Bearer $copilotToken',
      'Content-Type': 'application/json',
      'Copilot-Integration-Id': 'vscode-chat',
      'Editor-Version': _editorVersion,
      'Editor-Plugin-Version': _pluginVersion,
      'User-Agent': 'GitHubCopilotChat/0.37.6',
      'Openai-Intent': 'conversation-agent',
      'X-Github-Api-Version': _apiVersion,
      'X-Request-Id': _requestId(),
      'X-Vscode-User-Agent-Library-Version': 'electron-fetch',
      'X-Initiator': isAgent ? 'agent' : 'user',
      if (hasImages) 'Copilot-Vision-Request': 'true',
    };
  }

  Map<String, dynamic> _payload(
    List<LlmMessage> messages, {
    required String model,
    required bool stream,
  }) => {
    'model': model,
    'messages': messages.map((m) => m.toJson()).toList(),
    'stream': stream,
    if (maxTokens != null) 'max_tokens': maxTokens,
  };

  Uri _uri(String path) => Uri.parse(
    '${baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl}$path',
  );

  /// Sends the request, refreshing the token exactly once on 401/403
  /// (copilot-proxy-go retry semantics).
  Future<http.StreamedResponse> _send(
    List<LlmMessage> messages, {
    required String model,
    required bool stream,
  }) async {
    var currentToken = await token();
    for (var attempt = 0; ; attempt++) {
      final request = http.Request('POST', _uri('/chat/completions'))
        ..headers.addAll(
          _headers(copilotToken: currentToken, messages: messages),
        );
      request.body = jsonEncode(
        _payload(messages, model: model, stream: stream),
      );
      final response = await _client.send(request);
      if (attempt == 0 &&
          (response.statusCode == 401 || response.statusCode == 403)) {
        currentToken = await refresh();
        continue;
      }
      return response;
    }
  }

  Future<String> _extractMessage(http.StreamedResponse response) async {
    final body = await response.stream.bytesToString();
    if (response.statusCode != 200) {
      throw CopilotChatException(
        response.statusCode,
        'Copilot request failed: ${response.statusCode} $body',
      );
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    final choices = json['choices'] as List?;
    if (choices != null && choices.isNotEmpty) {
      final message = choices.first['message'] as Map<String, dynamic>?;
      final content = message?['content'];
      if (content is String) return content;
    }
    return '';
  }

  @override
  Future<String> chat(
    String prompt, {
    String? model,
    void Function()? onCancel,
  }) => chatMessages(
    [LlmMessage(role: 'user', content: prompt)],
    model: model,
    onCancel: onCancel,
  );

  @override
  Future<String> chatMessages(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) async => _extractMessage(
    await _send(messages, model: model ?? defaultModel, stream: false),
  );

  @override
  Stream<String> chatStream(
    String prompt, {
    String? model,
    void Function()? onCancel,
  }) => chatMessagesStream(
    [LlmMessage(role: 'user', content: prompt)],
    model: model,
    onCancel: onCancel,
  );

  @override
  Stream<String> chatMessagesStream(
    List<LlmMessage> messages, {
    String? model,
    void Function()? onCancel,
  }) {
    late final StreamController<String> controller;
    final parser = SseParser();
    var completed = false;

    Future<void> close() async {
      if (completed) return;
      completed = true;
      await controller.close();
    }

    controller = StreamController<String>(
      onListen: () async {
        try {
          final response = await _send(
            messages,
            model: model ?? defaultModel,
            stream: true,
          );
          if (response.statusCode != 200) {
            final body = await response.stream.bytesToString();
            controller.addError(
              CopilotChatException(
                response.statusCode,
                'Copilot request failed: ${response.statusCode} $body',
              ),
            );
            await close();
            return;
          }
          _activeSubscription = response.stream.listen(
            (chunk) {
              for (final payload in parser.push(utf8.decode(chunk))) {
                if (payload == '[DONE]') {
                  unawaited(close());
                  return;
                }
                final content = sseDeltaContent(payload);
                if (content != null) controller.add(content);
              }
            },
            onError: controller.addError,
            onDone: close,
            cancelOnError: true,
          );
        } catch (error) {
          controller.addError(error);
          await close();
        }
      },
      onCancel: () {
        unawaited(close());
        return _activeSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  /// Stops the in-flight stream immediately.
  @override
  Future<void> cancel() async {
    await _activeSubscription?.cancel();
    _activeSubscription = null;
  }

  /// `GET /models` — the only source of truth for available models.
  Future<List<CopilotModelInfo>> listModels() async {
    final response = await _client.get(
      _uri('/models'),
      headers: _headers(copilotToken: await token(), messages: const []),
    );
    if (response.statusCode != 200) {
      throw CopilotChatException(
        response.statusCode,
        'Copilot /models failed: ${response.statusCode} ${response.body}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (json['data'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    return [
      for (final model in data)
        CopilotModelInfo(
          id: model['id'] as String,
          maxContextWindowTokens: _limit(model, 'max_context_window_tokens'),
          maxOutputTokens: _limit(model, 'max_output_tokens'),
          supportedEndpoints:
              (model['supported_endpoints'] as List?)?.cast<String>() ??
              const [],
        ),
    ];
  }

  static int? _limit(Map<String, dynamic> model, String key) {
    final capabilities = model['capabilities'] as Map<String, dynamic>?;
    final limits = capabilities?['limits'] as Map<String, dynamic>?;
    return limits?[key] as int?;
  }
}

String _requestId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
