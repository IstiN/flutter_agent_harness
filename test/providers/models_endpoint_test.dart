// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/providers/models_endpoint.dart';
import 'package:test/test.dart';

void main() {
  group('parseModelsResponse', () {
    test('parses the OpenAI/OpenRouter {"data": [{"id": ...}]} shape', () {
      final (ids, windows, caps) = parseModelsResponse(
        '{"data": [{"id": "gpt-4o", "context_length": 128000, '
        '"max_completion_tokens": 16384}, {"id": "other"}]}',
      );
      expect(ids, ['gpt-4o', 'other']);
      expect(windows['gpt-4o'], 128000);
      expect(caps['gpt-4o'], 16384);
      expect(windows.containsKey('other'), isFalse);
    });

    test('parses the gateway {"models": [{"alias": ...}]} dialect', () {
      final (ids, windows, _) = parseModelsResponse(
        '{"models": ['
        '{"alias": "openai/gpt-4o-mini", "display_name": "GPT-4o Mini", '
        '"context_length": 128000}, '
        '{"alias": "google/gemini-3-flash", "context_window": 1000000}'
        ']}',
      );
      expect(ids, ['google/gemini-3-flash', 'openai/gpt-4o-mini']);
      expect(windows['openai/gpt-4o-mini'], 128000);
      expect(windows['google/gemini-3-flash'], 1000000);
    });

    test('empty data yields empty results, never throws', () {
      expect(parseModelsResponse('{}').$1, isEmpty);
      expect(parseModelsResponse('{"data": []}').$1, isEmpty);
      expect(parseModelsResponse('{"models": [{"no_id": 1}]}').$1, isEmpty);
    });
  });
}
