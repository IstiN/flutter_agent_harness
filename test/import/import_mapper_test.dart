import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/import/claude_adapter.dart';
import 'package:flutter_agent_harness/src/import/foreign_session.dart';
import 'package:flutter_agent_harness/src/import/import_mapper.dart';
import 'package:flutter_agent_harness/src/import/omp_adapter.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';

/// UT tier for the pure mapper (GOAL M-section): the omp mapping golden
/// (REG-4), toolCall pairing + orphans (AC5), unseen-type tolerance (AC6),
/// claude main-chain vs sidechain (AC8/E13), and the byte-exact
/// customType preservation invariant.
void main() {
  late Directory home;
  late Directory project;
  late LocalExecutionEnv fs;

  String fixture(String name) => File(
    'test/import/fixtures/$name',
  ).readAsStringSync().replaceAll('__CWD__', project.path);

  Future<ForeignParseResult> readOmp(String fixtureName) async {
    final bucket = Directory(
      '${home.path}/.omp/agent/sessions/--${project.path
          .replaceFirst('/', '')
          .replaceAll('/', '-')}--',
    )..createSync(recursive: true);
    File('${bucket.path}/session.jsonl').writeAsStringSync(fixture(fixtureName));
    final adapter = OmpAdapter();
    final summaries = await adapter.discover(
      fs: fs,
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: const ImportLimits(),
    );
    return adapter.read(
      fs: fs,
      summary: summaries.firstWhere((s) => s.sourceId != 'x1'),
      homeDir: home.path,
      limits: const ImportLimits(),
    );
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('fa_import_map_home');
    project = Directory.systemTemp.createTempSync('fa_import_map_proj');
    fs = LocalExecutionEnv(cwd: project.path);
  });

  tearDown(() {
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
  });

  test('REG-4: the omp fixture maps to the pinned record sequence', () async {
    final mapped = mapForeignSession(await readOmp('omp_modern.jsonl'), 'omp');
    final kinds = [
      for (final item in mapped.items)
        switch (item.planned) {
          PlannedName() => 'name',
          PlannedMessage(:final message) => 'message:${message.role}',
          PlannedModelChange() => 'model_change',
          PlannedThinkingLevel() => 'thinking_level',
          PlannedCompaction() => 'compaction',
          PlannedCustom(:final customType) => 'custom:$customType',
          PlannedCustomMessage() => 'custom_message',
        },
    ];
    expect(kinds, [
      'name',
      'message:user',
      'model_change',
      'thinking_level',
      'message:assistant',
      'custom:import.omp',
      'message:toolResult',
      'custom:import.omp.session_init',
      'custom:import.omp.model_usage',
      'custom:import.omp.branch_summary',
      'custom:import.omp.reset_boundary',
      'custom:import.omp.credential_pin',
      'custom:import.omp.label',
      'message:assistant',
      'message:assistant',
      'message:user',
      'custom:import.omp.bashExecution',
      'compaction',
      'message:user',
    ]);
  });

  test('the newest user title wins and lands in the name plan (AC4)', () async {
    final mapped = mapForeignSession(await readOmp('omp_modern.jsonl'), 'omp');
    final name = mapped.items.first.planned as PlannedName;
    expect(name.name, 'Fix the login flow (renamed)');
    expect(name.name.contains('\n'), isFalse);
  });

  test('blank titles fall back to the first user message prefix (F5 pin)', () async {
    final bucket = Directory(
      '${home.path}/.omp/agent/sessions/--${project.path
          .replaceFirst('/', '')
          .replaceAll('/', '-')}--',
    )..createSync(recursive: true);
    File('${bucket.path}/t.jsonl').writeAsStringSync(
      '{"type":"session","version":3,"id":"t1","timestamp":'
      '"2026-01-01T00:00:00.000Z","cwd":"${project.path}"}\n'
      '{"type":"message","id":"t2","parentId":null,"timestamp":'
      '"2026-01-01T00:00:01.000Z","message":{"role":"user","content":'
      '"the first user message becomes the name","timestamp":0}}\n',
    );
    final adapter = OmpAdapter();
    final summaries = await adapter.discover(
      fs: fs,
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: const ImportLimits(),
    );
    final parse = await adapter.read(
      fs: fs,
      summary: summaries.single,
      homeDir: home.path,
      limits: const ImportLimits(),
    );
    final mapped = mapForeignSession(parse, 'omp');
    final name = mapped.items.whereType<MappedItem>()
        .map((i) => i.planned)
        .whereType<PlannedName>()
        .single;
    expect(name.name, 'the first user message becomes the name');
  });

  test('the user→assistant(toolCall)→toolResult chain pairs by toolCallId '
      'and orphans land as counted customs (AC5)', () async {
    final parse = await readOmp('omp_modern.jsonl');
    final mapped = mapForeignSession(parse, 'omp');
    final assistant = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedMessage>()
        .map((p) => p.message)
        .whereType<AssistantMessage>()
        .where((m) => m.content.any((b) => b is ToolCall))
        .first;
    final call = assistant.content.whereType<ToolCall>().first;
    expect(call.id, 'call-1');
    final result = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedMessage>()
        .map((p) => p.message)
        .whereType<ToolResultMessage>()
        .single;
    expect(result.toolCallId, 'call-1');
    expect(result.toolName, 'bash');

    // An orphan tool result (no matching call id on the path).
    final orphanParse = ForeignParseResult(records: [
      ForeignMessage(
        lineNumber: 1,
        role: 'toolResult',
        contents: const [ForeignText('lost')],
        rawMessage: const {'role': 'toolResult', 'toolCallId': 'ghost'},
        toolCallId: 'ghost',
      ),
    ], skippedRecords: 0, skippedBlocks: 0);
    final orphanMapped = mapForeignSession(orphanParse, 'omp');
    final orphan = orphanMapped.items
        .map((i) => i.planned)
        .whereType<PlannedCustom>()
        .single;
    expect(orphan.customType, 'import.omp.orphanToolResult');
    expect(
      orphan.data,
      containsPair('toolCallId', 'ghost'),
    );
  });

  test('foreign customType strings survive byte-exact (M-invariant)', () async {
    final parse = await readOmp('omp_modern.jsonl');
    final mapped = mapForeignSession(parse, 'omp');
    final toolStart = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedCustom>()
        .firstWhere((c) => (c.data as Map)['customType'] == 'tool_execution_start');
    expect(toolStart.customType, 'import.omp');
    expect((toolStart.data as Map)['customType'], 'tool_execution_start');
    final data = (toolStart.data as Map)['data'] as Map;
    expect(data['toolCallId'], 'call-1');
  });

  test('specd-but-unseen types tolerate as customs (AC6)', () async {
    final parse = await readOmp('omp_modern.jsonl');
    final mapped = mapForeignSession(parse, 'omp');
    final customTypes = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedCustom>()
        .map((c) => c.customType)
        .toList();
    for (final type in [
      'import.omp.session_init',
      'import.omp.model_usage',
      'import.omp.branch_summary',
      'import.omp.reset_boundary',
      'import.omp.credential_pin',
      'import.omp.label',
    ]) {
      expect(customTypes, contains(type), reason: 'missing tolerated $type');
    }
    // And a totally unknown future type.
    final unknownParse = ForeignParseResult(records: [
      ForeignUnhandled(lineNumber: 1, type: 'warp_drive', raw: {'x': 1}),
    ], skippedRecords: 0, skippedBlocks: 0);
    final mappedUnknown = mapForeignSession(unknownParse, 'omp');
    final custom = mappedUnknown.items
        .map((i) => i.planned)
        .whereType<PlannedCustom>()
        .single;
    expect(custom.customType, 'import.omp.warp_drive');
  });

  test('aborted empty assistant imports with the chain intact (E3)', () async {
    final mapped = mapForeignSession(await readOmp('omp_modern.jsonl'), 'omp');
    final aborted = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedMessage>()
        .map((p) => p.message)
        .whereType<AssistantMessage>()
        .firstWhere(
          (m) => m.stopReason == StopReason.aborted && m.content.isEmpty,
        );
    expect(aborted.content, isEmpty);
  });

  test('interrupted toolCall carries partialArguments as data (E4)', () async {
    final mapped = mapForeignSession(await readOmp('omp_modern.jsonl'), 'omp');
    final partial = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedMessage>()
        .map((p) => p.message)
        .whereType<AssistantMessage>()
        .expand((m) => m.content)
        .whereType<ToolCall>()
        .firstWhere((c) => c.id == 'call-partial');
    expect(partial.partialArguments, '{"pa');
    expect(partial.arguments, isEmpty);
  });

  test('assistant usage and stopReason map onto the FA slots', () async {
    final mapped = mapForeignSession(await readOmp('omp_modern.jsonl'), 'omp');
    final assistant = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedMessage>()
        .map((p) => p.message)
        .whereType<AssistantMessage>()
        .firstWhere((m) => m.content.any((b) => b is ToolCall));
    expect(assistant.usage.input, 100);
    expect(assistant.usage.totalTokens, 120);
    expect(assistant.usage.cost.total, 0.3);
    expect(assistant.stopReason, StopReason.toolUse);
    expect(assistant.model, 'zai/glm-5.3');
  });

  test('model_change lands verbatim with the provider prefix split', () async {
    final mapped = mapForeignSession(await readOmp('omp_modern.jsonl'), 'omp');
    final change = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedModelChange>()
        .single;
    expect(change.modelId, 'zai/glm-5.3');
    expect(change.provider, 'zai');
  });

  test('compaction keeps the summary verbatim and counts dropped fields',
      () async {
    final mapped = mapForeignSession(await readOmp('omp_modern.jsonl'), 'omp');
    final compaction = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedCompaction>()
        .single;
    expect(
      compaction.summary,
      'The conversation so far fixed the login flow',
    );
    expect(mapped.droppedFields['shortSummary'], 1);
    expect(mapped.droppedFields['firstKeptEntryId'], 1);
    expect(mapped.droppedFields['tokensBefore'], 1);
  });

  test('non-conversation roles map to inert customs, never messages', () async {
    final mapped = mapForeignSession(await readOmp('omp_modern.jsonl'), 'omp');
    final bash = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedCustom>()
        .firstWhere((c) => c.customType == 'import.omp.bashExecution');
    expect((bash.data as Map)['role'], 'bashExecution');
  });

  test('claude: main chain imports, sidechain excluded and counted '
      '(AC8/E13)', () async {
    final bucket = Directory(
      '${home.path}/.claude/projects/${claudeProjectSlug(project.path)}',
    )..createSync(recursive: true);
    File('${bucket.path}/claude-0001.jsonl')
        .writeAsStringSync(fixture('claude_basic.jsonl'));
    final adapter = ClaudeAdapter();
    final summaries = await adapter.discover(
      fs: fs,
      cwd: project.path,
      homeDir: home.path,
      tempDir: Directory.systemTemp.path,
      limits: const ImportLimits(),
    );
    expect(summaries, hasLength(1));
    final parse = await adapter.read(
      fs: fs,
      summary: summaries.single,
      homeDir: home.path,
      limits: const ImportLimits(),
    );
    final mapped = mapForeignSession(parse, 'claude');

    // The sidechain and the off-branch fork never reach the plans.
    final plannedText = mapped.items
        .map((i) => i.planned)
        .map((p) => switch (p) {
              PlannedCustom(:final data) => data.toString(),
              PlannedMessage(:final message) => message.toJson().toString(),
              _ => '',
            })
        .join('\n');
    expect(plannedText, isNot(contains('sidechain thing')));
    expect(plannedText, isNot(contains('off-branch fork answer')));
    // Sidechain (u3) + off-branch fork (a2) counted skipped.
    expect(parse.skippedRecords, greaterThanOrEqualTo(2));

    // last-prompt / permission-mode ride as inert claude customs.
    final customs = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedCustom>()
        .toList();
    final customTypes = customs.map((c) => c.customType).toSet();
    // AC6/M-invariant: every unmapped type lands namespaced as
    // import.<harness>.<type>, never a bare import.claude line.
    expect(customTypes, containsAll([
      'import.claude.session',
      'import.claude.last-prompt',
      'import.claude.permission-mode',
    ]));
    expect(customTypes.contains('import.claude'), isFalse);
    final inertTypes = customs
        .map((c) => c.data is Map ? (c.data as Map)['type'] : null)
        .toSet();
    expect(inertTypes, containsAll(['last-prompt', 'permission-mode']));

    // tool_use → toolCall; the lifted tool_result pairs with it (AC5).
    final call = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedMessage>()
        .map((p) => p.message)
        .whereType<AssistantMessage>()
        .expand((m) => m.content)
        .whereType<ToolCall>()
        .single;
    expect(call.id, 'tu-1');
    final result = mapped.items
        .map((i) => i.planned)
        .whereType<PlannedMessage>()
        .map((p) => p.message)
        .whereType<ToolResultMessage>()
        .single;
    expect(result.toolCallId, 'tu-1');

    // Main chain in parentUuid order: u1 → a1 → (lifted result + u2) → u4.
    final ordered = [
      for (final item in mapped.items)
        if (item.planned is PlannedMessage)
          (item.planned as PlannedMessage).message.role,
    ];
    expect(ordered, ['user', 'assistant', 'toolResult', 'user', 'user']);
  });
}
