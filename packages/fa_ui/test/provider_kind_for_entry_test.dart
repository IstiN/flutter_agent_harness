// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// The ONE registry-entry → chat provider-kind mapping (issue #2156): a
// persisted entry identity wins, URL-shape dialects next, everything else
// plain openai-completions. The pickers and the agent-side provider→live
// linkage must dispatch the same entry onto the same wire.
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('providerKindForEntry', () {
    test('a persisted entry kind wins over every URL-shape check', () {
      // An edited/proxied codex URL stays on the codex wire (issue #2068
      // class): the identity, not the URL, dispatches.
      expect(
        providerKindForEntry(
          'chatgpt-codex',
          'https://proxy.example.com/backend-api/codex',
        ),
        'chatgpt-codex',
      );
    });

    test('URL-shape dialects classify entries without a kind', () {
      expect(
        providerKindForEntry(null, 'https://ai-proxy.lab.epam.com/v1'),
        'dial',
      );
      expect(
        providerKindForEntry(null, 'https://api.githubcopilot.com'),
        'copilot',
      );
      expect(
        providerKindForEntry(
          null,
          'https://generativelanguage.googleapis.com/v1beta',
        ),
        'google',
      );
      expect(
        providerKindForEntry(null, 'https://chatgpt.com/backend-api/codex'),
        'chatgpt-codex',
      );
    });

    test('every plain OpenAI-compatible endpoint rides openai-completions', () {
      expect(
        providerKindForEntry(null, 'https://api.aiin.by/v1'),
        'openai-completions',
      );
      expect(
        providerKindForEntry(null, 'http://localhost:11434/v1'),
        'openai-completions',
      );
    });
  });
}
