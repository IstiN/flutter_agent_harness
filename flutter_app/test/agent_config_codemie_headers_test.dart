// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// REG-2 for issue #2426: the app's model builds carry the CodeMie client
// header. `AgentConfig.toModel()` serves BOTH the reconfigure switch and
// the trailing-compaction summarizer (same constructor, part of
// agent_service.dart) — a build without the header 429s against the
// user's personal budget while the org budget has headroom.
import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toModel carries the CodeMie client header on a CodeMie endpoint '
      '(issue #2426 REG-2)', () {
    final config = AgentConfig(
      providerKind: 'openai-completions',
      modelId: 'codemie-model',
      baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
      apiKey: 'cookie-jar',
    );
    final model = config.toModel();
    expect(model.headers?[codeMieClientHeader], codeMieClient);
    // The cookie stays the sole auth credential.
    expect(model.headers?['cookie'], 'cookie-jar');
  });

  test('a non-CodeMie config carries no client header (INV-3)', () {
    final config = AgentConfig(
      providerKind: 'openai-completions',
      modelId: 'gpt-4o',
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'sk',
    );
    expect(config.toModel().headers, isNull);
  });
}
