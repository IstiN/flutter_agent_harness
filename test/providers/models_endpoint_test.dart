// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/providers/models_endpoint.dart';
import 'package:test/test.dart';

void main() {
  group('parseModelsResponse', () {
    test('parses the OpenAI/OpenRouter {"data": [{"id": ...}]} shape', () {
      final (ids, windows, caps, _) = parseModelsResponse(
        '{"data": [{"id": "gpt-4o", "context_length": 128000, '
        '"max_completion_tokens": 16384}, {"id": "other"}]}',
      );
      expect(ids, ['gpt-4o', 'other']);
      expect(windows['gpt-4o'], 128000);
      expect(caps['gpt-4o'], 16384);
      expect(windows.containsKey('other'), isFalse);
    });

    test('parses the gateway {"models": [{"alias": ...}]} dialect', () {
      final (ids, windows, _, _) = parseModelsResponse(
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

    test('parses the AIIN input_modalities list into per-model modalities', () {
      // Real AIIN gateway shape (api.aiin.by /v1/models, fetched 2026-11):
      // text+image entries the vision heuristic cannot see by name.
      final (_, _, _, modalities) = parseModelsResponse(
        '{"models": ['
        '{"alias": "mistralai/mistral-large-4-0", "context_length": 1048576, '
        '"modality": "text+image->text", '
        '"input_modalities": ["text", "image"], '
        '"output_modalities": ["text"]}, '
        '{"alias": "z-ai/glm-5.1", "context_length": 204800, '
        '"modality": "text->text", '
        '"input_modalities": ["text"], "output_modalities": ["text"]}'
        ']}',
      );
      expect(
        modalities['mistralai/mistral-large-4-0'],
        ['text', 'image'],
      );
      expect(modalities['z-ai/glm-5.1'], ['text']);
    });

    test('modality string is the fallback when input_modalities is absent', () {
      final (_, _, _, modalities) = parseModelsResponse(
        '{"data": [{"id": "meta/muse-spark-1.2", '
        '"modality": "text+image->text"}]}',
      );
      expect(modalities['meta/muse-spark-1.2'], ['text', 'image']);
    });

    test('entries without modality fields are absent from the map', () {
      final (_, _, _, modalities) = parseModelsResponse(
        '{"data": [{"id": "plain-id", "context_length": 4096}]}',
      );
      expect(modalities.containsKey('plain-id'), isFalse);
    });

    test('malformed modality fields are skipped, never throw', () {
      final (_, _, _, modalities) = parseModelsResponse(
        '{"data": ['
        '{"id": "a", "input_modalities": "text"}, '
        '{"id": "b", "modality": 42}, '
        '{"id": "c", "input_modalities": ["text", 7, "image"]}'
        ']}',
      );
      expect(modalities.containsKey('a'), isFalse);
      expect(modalities.containsKey('b'), isFalse);
      expect(modalities['c'], ['text', 'image']);
    });
  });

  group('normalizeAiinModelInfo', () {
    test('replaces a blanket 1M stamp on a curated family with its real '
        'window (claude → 200k)', () {
      final info = parseModelsResponse(
        '{"models": ['
        '{"alias": "anthropic/claude-sonnet-5", "context_length": 1048576}, '
        '{"alias": "anthropic/claude-sonnet-5.5", "context_length": 1000000}'
        ']}',
      );
      final normalized = normalizeAiinModelInfo(info);
      expect(normalized.$2['anthropic/claude-sonnet-5'], 200000);
      expect(normalized.$2['anthropic/claude-sonnet-5.5'], 200000);
    });

    test('a precise endpoint value wins over the curated family default', () {
      // claude-opus-4.5 reports its true 200000 (no stamp) — untouched.
      final info = parseModelsResponse(
        '{"models": [{"alias": "anthropic/claude-opus-4.5", '
        '"context_length": 200000}]}',
      );
      expect(normalizeAiinModelInfo(info).$2['anthropic/claude-opus-4.5'],
          200000);
    });

    test('gemini keeps its legitimate 1M (curated value equals the stamp)',
        () {
      final info = parseModelsResponse(
        '{"models": [{"alias": "google/gemini-3.5-flash", '
        '"context_length": 1048576}]}',
      );
      expect(normalizeAiinModelInfo(info).$2['google/gemini-3.5-flash'],
          1048576);
    });

    test('uncurated families keep the endpoint report (no global 1M fallback)',
        () {
      final info = parseModelsResponse(
        '{"models": ['
        '{"alias": "minimax/minimax-m3", "context_length": 1048576}, '
        '{"alias": "moonshotai/kimi-k3", "context_length": 1048576}'
        ']}',
      );
      final windows = normalizeAiinModelInfo(info).$2;
      expect(windows['minimax/minimax-m3'], 1048576);
      expect(windows['moonshotai/kimi-k3'], 1048576);
    });

    test('a missing window falls back to the curated per-family map', () {
      final info = parseModelsResponse(
        '{"models": ['
        '{"alias": "anthropic/claude-haiku-5.5"}, '
        '{"alias": "google/gemini-4-carbon"}, '
        '{"alias": "z-ai/glm-5.3"}'
        ']}',
      );
      final windows = normalizeAiinModelInfo(info).$2;
      expect(windows['anthropic/claude-haiku-5.5'], 200000);
      expect(windows['google/gemini-4-carbon'], 1048576);
      expect(windows.containsKey('z-ai/glm-5.3'), isFalse);
    });

    test('a zero-reported window is treated as absent (curated map applies)',
        () {
      final info = parseModelsResponse(
        '{"models": [{"alias": "anthropic/claude-sonnet-4.6", '
        '"context_length": 0}]}',
      );
      expect(normalizeAiinModelInfo(info).$2['anthropic/claude-sonnet-4.6'],
          200000);
    });

    test('modalities ride the normalization untouched', () {
      final info = parseModelsResponse(
        '{"models": [{"alias": "anthropic/claude-sonnet-5", '
        '"context_length": 1048576, '
        '"input_modalities": ["text", "image", "file"]}]}',
      );
      expect(normalizeAiinModelInfo(info).$4['anthropic/claude-sonnet-5'], [
        'text',
        'image',
        'file',
      ]);
    });

    test('family tokens match case-insensitively across provider prefixes',
        () {
      final info = parseModelsResponse(
        '{"models": [{"alias": "SiliconFlow/anthropic/Claude-Sonnet-5", '
        '"context_length": 1048576}]}',
      );
      expect(
        normalizeAiinModelInfo(info).$2['SiliconFlow/anthropic/Claude-Sonnet-5'],
        200000,
      );
    });
  });
}
