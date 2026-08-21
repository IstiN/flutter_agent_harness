// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Live integration tests for the Google Generative AI provider adapter.
///
/// These tests hit the real Gemini API and require the `GOOGLE_API_KEY`
/// environment variable; every test skips gracefully when it is unset so
/// keyless CI/dev runs pass. Prompts are kept tiny and `maxTokens` small to
/// bound cost. Tagged `integration` and therefore excluded from the
/// pre-commit gate — run manually with:
/// `dart test --tags integration`
@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final _apiKey = Platform.environment['GOOGLE_API_KEY'];

/// `false` when the key is present (tests run), otherwise the skip reason.
final _skip = (_apiKey?.isEmpty ?? true) ? 'GOOGLE_API_KEY not set' : false;

/// Cheap current Gemini chat model. Thinking is disabled per-request via
/// [GoogleThinking] so text deltas arrive without a thinking preface.
const _model = Model(
  id: 'gemini-2.5-flash',
  name: 'Gemini 2.5 Flash',
  api: 'google-generative-ai',
  provider: 'google',
  baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  reasoning: true,
  input: ['text', 'image'],
  contextWindow: 1000000,
  maxTokens: 65536,
);

/// Trivial tool used to exercise tool-call streaming against the live API.
const _addTool = Tool(
  name: 'add',
  description: 'Add two numbers and return their sum.',
  parameters: {
    'type': 'object',
    'properties': {
      'a': {'type': 'number', 'description': 'First addend.'},
      'b': {'type': 'number', 'description': 'Second addend.'},
    },
    'required': ['a', 'b'],
    'additionalProperties': false,
  },
);

void main() {
  group('Google (google-generative-ai adapter, live)', () {
    test(
      'streams incremental text deltas, a done event, and non-zero usage',
      () async {
        final stream = streamGoogle(
          _model,
          Context(messages: [UserMessage.text('Say hello in three words.')]),
          GoogleOptions(
            apiKey: _apiKey!,
            maxTokens: 256,
            thinking: const GoogleThinking(enabled: false),
          ),
        );

        final events = await stream.toList();
        expect(events.first, isA<StartEvent>());

        final deltas = events.whereType<TextDeltaEvent>().toList();
        expect(deltas, isNotEmpty, reason: 'expected at least one text delta');
        final fullText = deltas.map((delta) => delta.delta).join();
        expect(fullText.trim(), isNotEmpty);
        // Partial-first contract: the first incremental delta is a prefix of
        // the accumulated final text.
        expect(fullText.startsWith(deltas.first.delta), isTrue);

        final done = events.last;
        expect(done, isA<DoneEvent>());
        final doneEvent = done as DoneEvent;
        expect(doneEvent.reason, isNot(StopReason.error));
        expect(doneEvent.reason, StopReason.stop);

        final message = await stream.result;
        expect(message.stopReason, doneEvent.reason);
        expect(message.usage.totalTokens, greaterThan(0));
        expect(message.usage.output, greaterThan(0));
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'streams a forced add() tool call with parsed arguments',
      () async {
        final stream = streamGoogle(
          _model,
          Context(
            messages: [UserMessage.text('Use the add tool to compute 40 + 2.')],
            tools: const [_addTool],
          ),
          GoogleOptions(
            apiKey: _apiKey!,
            maxTokens: 256,
            thinking: const GoogleThinking(enabled: false),
            toolChoice: 'any',
          ),
        );

        final events = await stream.toList();
        expect(events.whereType<ToolCallStartEvent>(), isNotEmpty);
        expect(events.whereType<ToolCallDeltaEvent>(), isNotEmpty);

        final end = events.whereType<ToolCallEndEvent>().single;
        expect(end.toolCall.name, 'add');
        expect(end.toolCall.id, isNotEmpty);
        final args = end.toolCall.arguments;
        expect((args['a'] as num) + (args['b'] as num), 42);

        final done = events.last;
        expect(done, isA<DoneEvent>());
        expect((done as DoneEvent).reason, StopReason.toolUse);
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'reads an inline PNG image and describes it',
      () async {
        // 8x8 red square PNG (75 bytes) — tiny, deterministic, cheap.
        const pngB64 =
            'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP4z8CAFWEXHbQSACj/P8Fu7N9hAAAAAElFTkSuQmCC';
        final stream = streamGoogle(
          _model,
          Context(
            messages: [
              UserMessage(
                content: [
                  TextContent(text: 'What color is this image?'),
                  ImageContent(data: pngB64, mimeType: 'image/png'),
                ],
                timestamp: DateTime.now(),
              ),
            ],
          ),
          GoogleOptions(
            apiKey: _apiKey!,
            maxTokens: 128,
            thinking: const GoogleThinking(enabled: false),
          ),
        );

        final events = await stream.toList();
        final error = events.whereType<ErrorEvent>().firstOrNull;
        expect(
          error,
          isNull,
          reason:
              'Gemini rejected the inline PNG: '
              '${error?.error.errorMessage ?? 'none'}',
        );
        final deltas = events.whereType<TextDeltaEvent>().toList();
        expect(deltas, isNotEmpty, reason: 'expected at least one text delta');
        final fullText = deltas.map((d) => d.delta).join();
        expect(fullText, isNotEmpty);
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'reads an RGBA PNG with alpha channel (converted to JPEG by the adapter)',
      () async {
        // 8x8 RGBA PNG (75 bytes) — alpha channel present. The Google
        // adapter converts PNG → JPEG before sending (strips alpha/EXIF).
        // This test asserts the conversion path works against the live API.
        const pngB64 =
            'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEklEQVR4nGP4z8DwHx9mGBkKAMLXf4EvceABAAAAAElFTkSuQmCC';
        final stream = streamGoogle(
          _model,
          Context(
            messages: [
              UserMessage(
                content: [
                  TextContent(text: 'What color is this image?'),
                  ImageContent(data: pngB64, mimeType: 'image/png'),
                ],
                timestamp: DateTime.now(),
              ),
            ],
          ),
          GoogleOptions(
            apiKey: _apiKey!,
            maxTokens: 128,
            thinking: const GoogleThinking(enabled: false),
          ),
        );

        final events = await stream.toList();
        final error = events.whereType<ErrorEvent>().firstOrNull;
        expect(
          error,
          isNull,
          reason:
              'Gemini rejected the RGBA PNG: '
              '${error?.error.errorMessage ?? 'none'}',
        );
        final deltas = events.whereType<TextDeltaEvent>().toList();
        expect(deltas, isNotEmpty, reason: 'expected at least one text delta');
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'corrupt image: retries with a placeholder instead of dying with 400',
      () async {
        // Half of a valid PNG — undecodable. The adapter must catch the
        // backend's 400 'Unable to process input image', retry once with
        // the image replaced by placeholder text, and complete the turn.
        const fullPngB64 =
            'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP4z8CAFWEXHbQSACj/P8Fu7N9hAAAAAElFTkSuQmCC';
        final truncated = base64Encode(base64Decode(fullPngB64).sublist(0, 30));
        final stream = streamGoogle(
          _model,
          Context(
            messages: [
              UserMessage(
                content: [
                  TextContent(
                    text:
                        'If you cannot see any image, say exactly: NO IMAGE. '
                        'Otherwise describe it.',
                  ),
                  ImageContent(data: truncated, mimeType: 'image/png'),
                ],
                timestamp: DateTime.now(),
              ),
            ],
          ),
          GoogleOptions(
            apiKey: _apiKey!,
            maxTokens: 128,
            thinking: const GoogleThinking(enabled: false),
          ),
        );

        final events = await stream.toList();
        final error = events.whereType<ErrorEvent>().firstOrNull;
        expect(
          error,
          isNull,
          reason:
              'the undecodable-image retry should have saved the turn: '
              '${error?.error.errorMessage ?? 'none'}',
        );
        final done = events.last as DoneEvent;
        expect(done.reason, StopReason.stop);
        expect(
          done.message.content
              .whereType<TextContent>()
              .map((b) => b.text)
              .join(),
          isNotEmpty,
        );
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'unsigned tool-call replay: retries with text notes instead of 400',
      () async {
        // Gemini 3 rejects replayed functionCall parts without a
        // thoughtSignature (400 'missing a thought_signature'). The adapter
        // must catch that, retry once with the call + result rewritten as
        // plain text notes, and complete the turn. (On models that do not
        // enforce signatures the first attempt just succeeds — either way
        // the turn completes without an error event.)
        final stream = streamGoogle(
          _model,
          Context(
            messages: [
              UserMessage.text(
                'Call ls on the uploads directory.',
                timestamp: DateTime.now(),
              ),
              AssistantMessage(
                content: const [
                  ToolCall(
                    id: 'call_1',
                    name: 'ls',
                    arguments: {'path': 'uploads'},
                  ),
                ],
                api: _model.api,
                provider: _model.provider,
                model: _model.id,
                usage: Usage.zero,
                stopReason: StopReason.toolUse,
                timestamp: DateTime.now(),
              ),
              ToolResultMessage(
                toolCallId: 'call_1',
                toolName: 'ls',
                content: const [TextContent(text: 'diagram.png')],
                isError: false,
                timestamp: DateTime.now(),
              ),
              UserMessage.text(
                'What did you see? Answer in one sentence.',
                timestamp: DateTime.now(),
              ),
            ],
          ),
          GoogleOptions(
            apiKey: _apiKey!,
            maxTokens: 256,
            thinking: const GoogleThinking(enabled: false),
          ),
        );

        final events = await stream.toList();
        final error = events.whereType<ErrorEvent>().firstOrNull;
        expect(
          error,
          isNull,
          reason:
              'the missing-signature retry should have saved the turn: '
              '${error?.error.errorMessage ?? 'none'}',
        );
        final done = events.last as DoneEvent;
        expect(done.reason, StopReason.stop);
        expect(
          done.message.content
              .whereType<TextContent>()
              .map((b) => b.text)
              .join(),
          isNotEmpty,
        );
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'CancelToken abort mid-stream ends with aborted stop reason',
      () async {
        final source = CancelTokenSource();
        final stream = streamGoogle(
          _model,
          Context(
            messages: [
              UserMessage.text('Count from 1 to 1000, one number per line.'),
            ],
          ),
          GoogleOptions(
            apiKey: _apiKey!,
            maxTokens: 2048,
            thinking: const GoogleThinking(enabled: false),
            cancelToken: source.token,
          ),
        );

        final events = <AssistantMessageEvent>[];
        await for (final event in stream) {
          events.add(event);
          if (event is TextDeltaEvent && !source.token.isCancelled) {
            source.cancel(); // abort after the very first delta
          }
        }

        expect(events.whereType<TextDeltaEvent>(), isNotEmpty);
        final terminal = events.last;
        expect(terminal, isA<ErrorEvent>());
        expect((terminal as ErrorEvent).reason, StopReason.aborted);
        final message = await stream.result;
        expect(message.stopReason, StopReason.aborted);
      },
      skip: _skip,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
