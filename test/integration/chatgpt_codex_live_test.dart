// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Live integration test for the ChatGPT Codex adapter (`streamChatGptCodex`)
/// against the real Codex backend.
///
/// Requires the encoded OAuth credentials blob in the `CHATGPT_OAUTH_CREDENTIALS`
/// environment variable — run `/provider chatgpt oauth` once, then export the
/// blob stored under that key name. Every test skips cleanly when it is unset
/// so keyless CI/dev runs pass. The blob is never printed: failures surface
/// only server-side error text. Tagged `integration` and therefore excluded
/// from the pre-commit gate — run manually with:
/// `dart test --tags integration`
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Encoded ChatGPT OAuth credentials blob (as stored by
/// `/provider chatgpt oauth` under `CHATGPT_OAUTH_CREDENTIALS`).
final _credentials = Platform.environment['CHATGPT_OAUTH_CREDENTIALS'];

/// `false` when the blob is present (the test runs), otherwise the skip
/// reason pointing at the sign-in flow.
final _skip = (_credentials?.isEmpty ?? true)
    ? 'CHATGPT_OAUTH_CREDENTIALS not set — run `/provider chatgpt oauth` '
          'first and export the stored blob'
    : false;

final _model = Model(
  id: 'gpt-5-codex',
  api: 'responses',
  provider: 'chatgpt',
  baseUrl: chatGptCodexBaseUrl,
  input: const ['text'],
  contextWindow: 128000,
  maxTokens: 16384,
);

void main() {
  test(
    'streams a pong from the live Codex backend',
    () async {
      final stream = streamChatGptCodex(
        _model,
        Context(messages: [UserMessage.text('Reply with the word: pong')]),
        credentials: _credentials!,
      );

      final events = await stream.toList();

      final deltas = events.whereType<TextDeltaEvent>().toList();
      expect(deltas, isNotEmpty, reason: 'expected at least one text delta');
      final fullText = deltas.map((delta) => delta.delta).join();
      expect(fullText.trim(), isNotEmpty);

      final done = events.last;
      expect(done, isA<DoneEvent>());
      final doneEvent = done as DoneEvent;
      expect(doneEvent.reason, isNot(StopReason.error));
      final messageText = doneEvent.message.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join();
      expect(messageText.trim(), isNotEmpty);
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
