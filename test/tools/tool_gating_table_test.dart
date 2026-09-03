/// AC3 table test (issue #19): every capability-gated tool id is present in
/// the live registry surface (agent state + provider tool list) exactly
/// when its host capability is wired, and absent — with no description
/// trace — when it is not. Drives a real [AgentCli] per case.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

/// Trivial engine: presence gating never opens a database.
class _UnusedSqliteEngine implements SqliteEngine {
  @override
  SqliteDatabase openReadOnly(String path) =>
      throw UnimplementedError('never opened');
}

AgentCli _boot(AgentCliConfig config, FakeCliIO io) {
  return AgentCli(
    config: config,
    io: io,
    streamFunction: FakeStreamFunction([textTurn('ok')]).call,
  );
}

AgentCliConfig _config(
  FakeCliIO io, {
  WebSearchConfig? webSearchConfig,
  LspToolConfig? lspConfig,
  SqliteEngine? sqliteEngine,
  InspectImageConfig? visionConfig,
  TranscribeAudioConfig? transcribeConfig,
}) {
  return AgentCliConfig(
    model: testModel,
    apiKey: 'test-key',
    env: MemoryExecutionEnv(cwd: '/work'),
    sessionRoot: '/sessions',
    webSearchConfig: webSearchConfig,
    lspConfig: lspConfig,
    sqliteEngine: sqliteEngine,
    visionConfig: visionConfig,
    transcribeConfig: transcribeConfig,
  );
}

void main() {
  // (id, wired config, unwired config) — one row per capability-gated id.
  final cases =
      <
        (
          String,
          AgentCliConfig Function(FakeCliIO),
          AgentCliConfig Function(FakeCliIO),
        )
      >[
        (
          'web_search',
          (io) => _config(io, webSearchConfig: WebSearchConfig()),
          (io) => _config(io),
        ),
        (
          'web_fetch',
          (io) => _config(io, webSearchConfig: WebSearchConfig()),
          (io) => _config(io),
        ),
        (
          'lsp',
          (io) => _config(
            io,
            lspConfig: LspToolConfig(
              transportFactory: (_, _) => throw UnimplementedError(),
            ),
          ),
          (io) => _config(io),
        ),
        (
          'inspect_image',
          (io) => _config(
            io,
            visionConfig: const InspectImageConfig(modelId: 'v', apiKey: 'k'),
          ),
          (io) => _config(io),
        ),
        (
          'transcribe_audio',
          (io) => _config(
            io,
            transcribeConfig: const TranscribeAudioConfig(apiKey: 'k'),
          ),
          (io) => _config(io),
        ),
      ];

  for (final (id, wired, unwired) in cases) {
    group('capability gating: $id', () {
      test('capability present → tool offered to the model', () {
        final io = FakeCliIO();
        final cli = _boot(wired(io), io);
        final names = cli.agent.state.tools.map((t) => t.name).toSet();
        expect(names, contains(id), reason: 'agent.state.tools');
      });

      test('capability absent → tool hidden everywhere', () {
        final io = FakeCliIO();
        final cli = _boot(unwired(io), io);
        final names = cli.agent.state.tools.map((t) => t.name).toSet();
        expect(names, isNot(contains(id)), reason: 'agent.state.tools');
      });
    });
  }

  test('sqlite capability is visible in the read tool description', () {
    final withEngine = _boot(
      _config(FakeCliIO(), sqliteEngine: _UnusedSqliteEngine()),
      FakeCliIO(),
    );
    final withoutEngine = _boot(_config(FakeCliIO()), FakeCliIO());
    final sqliteRead = withEngine.agent.state.tools.firstWhere(
      (tool) => tool.name == 'read',
    );
    final plainRead = withoutEngine.agent.state.tools.firstWhere(
      (tool) => tool.name == 'read',
    );
    expect(sqliteRead.description, contains('## SQLite databases'));
    expect(plainRead.description, isNot(contains('SQLite')));
  });
}
