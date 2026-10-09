@Tags(['integration'])
/// gh-1409 — compaction-pinned skill operative lines, end-to-end over a
/// real JSONL session (the image-registry e2e idiom):
///
/// - E2E-PIN-1/AC2: a session that read a skill, compacted through the
///   real pipeline (classic engine, real records) — every declared
///   operative line re-enters the assembled request VERBATIM, in a
///   provenance-carrying block placed after the compaction boundary, even
///   though the summary the pipeline produced never mentions it (F2: the
///   body tool result is >2000 chars, so the summary serializer truncated
///   it before the LLM ever saw it).
/// - E2E-PIN-2/AC5/F5: resume (a fresh Session opened over the SAME
///   JSONL) — the pin block is present on the first post-resume request
///   and NO SKILL.md re-read appears in the resumed transcript.
/// - E2E-PIN-3/AC9: fold-on-fold ×3 through real records — the rendered
///   carrier is byte-identical at every generation (rebuilt from
///   manifests, never from the prior checkpoint).
/// - P1 byte-scan/AC8: no pin text in the session JSONL — the persisted
///   file is byte-scanned directly.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _pin = 'use fleet_sweep.sh; never hand-roll the gh battery';

Skill _skill() => skillFromText(
  '---\nname: fleet\ndescription: Fleet sweeps.\n'
  'operative:\n  - "$_pin"\n---\nBody.\n',
  filePath: '/work/.fah/skills/fleet/SKILL.md',
  fallbackName: 'fleet',
  scope: SkillScope.project,
  source: SkillSource.fah,
)!;

const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 128,
  keepRecentTokens: 120,
);

AssistantMessage _assistant(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'openai-completions',
  provider: 'openrouter',
  model: 'm1',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

/// The skill-read turn: an assistant `read` tool call answered with a body
/// LARGER than the 2000-char summary-serialization cap (F2).
List<Message> _skillReadTurn() {
  final body = 'x' * 5000;
  return [
    AssistantMessage(
      content: [
        ToolCall(
          id: 'call-1',
          name: 'read',
          arguments: {'path': '/work/.fah/skills/fleet/SKILL.md'},
        ),
      ],
      api: 'openai-completions',
      provider: 'openrouter',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.toolUse,
      timestamp: DateTime.utc(2026),
    ),
    ToolResultMessage(
      toolCallId: 'call-1',
      toolName: 'read',
      content: [TextContent(text: body)],
      isError: false,
      timestamp: DateTime.utc(2026),
    ),
  ];
}

class _DropEverythingSummarizer {
  final prompts = <String>[];

  Future<SummarizationResult> call(SummarizationRequest request) async {
    prompts.add(request.prompt);
    // A deliberately pin-oblivious checkpoint: the mechanism must not rely
    // on summarizer obedience (the carrier is the boundary).
    return SummarizationResult.success(
      '## Goal\nboard sweep.\n\n## Next Steps\n1. continue the sweep\n',
    );
  }
}

PinnedOperativePayload _payload() {
  final registry = SkillOperativePins.build([_skill()]);
  return PinnedOperativePayload(
    block: pinnedOperativePromptBlock(registry)!,
    lines: {for (final pin in registry.pins) pin.line},
  );
}

/// Builds a session with the incident shape: user ask → skill read (big
/// body) → several padded turns. Returns (session, repo, env).
Future<(Session, JsonlSessionRepo, MemoryExecutionEnv)>
_incidentSession() async {
  final env = MemoryExecutionEnv();
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/work/.fah/sessions');
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  await session.appendMessage(UserMessage.text('sweep the board, u1'));
  for (final message in _skillReadTurn()) {
    await session.appendMessage(message);
  }
  // Padded turns so the skill read sits far above the kept tail (F3: the
  // cut is by token position, so a session-start read is cut in every
  // real fold).
  for (var i = 0; i < 4; i++) {
    await session.appendMessage(UserMessage.text('u$i ${'a' * 400}'));
    await session.appendMessage(_assistant('w' * 400));
  }
  return (session, repo, env);
}

/// The window a provider request would see: the projected context with the
/// pin carriers injected (the loop's payload-only step).
Future<List<Message>> _requestWindow(
  Session session,
  List<Skill> skills,
) async {
  final projected = await session.buildContextMessages();
  return injectOperativePinCarriers(projected, skills: skills);
}

void main() {
  final skills = [_skill()];

  test('E2E-PIN-1/AC2: fold over a skill-reading session — the pin rides '
      'the assembled request verbatim, after the boundary', () async {
    final (session, _, _) = await _incidentSession();
    final summarizer = _DropEverythingSummarizer();
    final manager = CompactionManager(
      summarize: summarizer.call,
      settings: _settings,
      pinnedOperative: _payload(),
    );
    final record = await manager.compactSession(session);
    expect(record, isNotNull);

    final window = await _requestWindow(session, skills);
    final texts = [
      for (final message in window)
        if (message is UserMessage && message.content is String)
          message.content as String,
    ];
    // Verbatim (P3), provenance-tagged, in the fixed wrapper.
    expect(
      texts.any((t) => t.contains('"$_pin"') && t.contains(pinBlockOpenTag)),
      isTrue,
    );
    expect(texts.any((t) => t.contains('pinned from skill `fleet`')), isTrue);
    // AFTER the boundary — never inside the summarized range (IT-PIN-2 at
    // the session level).
    final boundary = window.indexWhere(
      (m) =>
          m is UserMessage &&
          (m.content as String).startsWith(compactionSummaryPrefix),
    );
    final carrier = window.indexWhere(
      (m) =>
          m is UserMessage && (m.content as String).contains(pinBlockOpenTag),
    );
    expect(boundary, greaterThanOrEqualTo(0));
    expect(carrier, boundary + 1);
    // The summarizer's own prompt was duty-loaded, but its (fake) output
    // dropped the pin — the CARRIER is what restored it (AC3: repair from
    // the registry, never from summary text).
    expect(texts.where((t) => t.contains('checkpoint')).length, 1);
  });

  test('E2E-PIN-2/AC5: resume over the same JSONL — pin present, zero '
      'SKILL.md re-reads', () async {
    final (session, repo, _) = await _incidentSession();
    await CompactionManager(
      summarize: _DropEverythingSummarizer().call,
      settings: _settings,
      pinnedOperative: _payload(),
    ).compactSession(session);

    // The resumed process: a fresh Session over the same file.
    final listed = await repo.list(cwd: '/work');
    expect(listed, hasLength(1));
    final resumed = await repo.open(listed.single);

    final resumedRecords = await resumed.getEntries();
    final skillReads = [
      for (final record in resumedRecords)
        if (record is MessageRecord && record.message is AssistantMessage)
          for (final block in (record.message as AssistantMessage).content)
            if (block is ToolCall &&
                block.name == 'read' &&
                block.arguments['path'] == '/work/.fah/skills/fleet/SKILL.md')
              block,
    ];
    expect(skillReads, hasLength(1)); // only the ORIGINAL read — no re-read.

    final window = await _requestWindow(resumed, skills);
    final requestText = [
      for (final message in window)
        if (message is UserMessage && message.content is String)
          message.content as String,
    ].join('\n');
    expect(requestText.contains('"$_pin"'), isTrue);
    expect(requestText.contains(pinBlockOpenTag), isTrue);
  });

  test('E2E-PIN-3/AC9: fold-on-fold ×3 — the carrier is byte-identical '
      'across generations', () async {
    final (session, _, _) = await _incidentSession();
    final manager = CompactionManager(
      summarize: _DropEverythingSummarizer().call,
      settings: _settings,
      pinnedOperative: _payload(),
    );
    final carriers = <String>[];
    for (var generation = 0; generation < 3; generation++) {
      await manager.compactSession(session);
      final window = await _requestWindow(session, skills);
      final carrier = window
          .whereType<UserMessage>()
          .where((m) => m.content is String)
          .map((m) => m.content as String)
          .firstWhere((t) => t.contains(pinBlockOpenTag), orElse: () => '');
      expect(carrier, isNotEmpty, reason: 'generation $generation lost pins');
      carriers.add(carrier);
    }
    expect(carriers.toSet(), hasLength(1));
  });

  test('P1/AC8 byte-scan: no pin text in the session JSONL', () async {
    final (session, repo, env) = await _incidentSession();
    await CompactionManager(
      summarize: _DropEverythingSummarizer().call,
      settings: _settings,
      pinnedOperative: _payload(),
    ).compactSession(session);
    final path = (await repo.list(cwd: '/work')).single.path;
    final text = (await env.readTextFile(path)).valueOrNull ?? '';
    expect(text.contains(_pin), isFalse);
    expect(text.contains(pinBlockOpenTag), isFalse);
  });
}
