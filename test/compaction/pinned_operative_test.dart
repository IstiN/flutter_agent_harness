/// gh-1409 — compaction-pinned skill operative lines, compaction-side
/// integration coverage:
///
/// - UT-PIN-5: `CompactionPrompts` carries the verbatim-preserve section;
///   the override id `compaction/pinned_operative` resolves.
/// - AC3/E7: every summarization path (`summary`, `summaryUpdate`,
///   `turnPrefix`, structured checkpoint, chunked folds) carries the
///   pinned block + duty when pins exist, and byte-identical prompts when
///   they don't (F4).
/// - AC4: the sanitizer protects pin lines while stripping ephemeral
///   neighbors (persist path).
/// - IT-PIN-8/AC9: fold-on-fold ×3 — the pinned block is byte-stable
///   across generations (rebuilt from manifests, never from the prior
///   checkpoint text).
/// - REG-PIN-3/AC8/P1: session JSONL byte-identical with pins on vs off
///   for the same fake-summarized session — no pin text written into
///   records by the pipeline itself.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:test/test.dart';

Skill _skill(String name, List<String> operative) {
  final frontmatter = StringBuffer(
    '---\nname: $name\ndescription: $name skill.\n',
  );
  if (operative.isNotEmpty) {
    frontmatter.writeln('operative:');
    for (final line in operative) {
      frontmatter.writeln('  - "$line"');
    }
  }
  frontmatter.writeln('---\nBody.\n');
  return skillFromText(
    frontmatter.toString(),
    filePath: '/work/.fah/skills/$name/SKILL.md',
    fallbackName: name,
    scope: SkillScope.project,
    source: SkillSource.fah,
  )!;
}

AssistantMessage _assistant(String text) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'openai-completions',
    provider: 'openrouter',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

class _FakeSummarizer {
  _FakeSummarizer(this.results);

  final List<SummarizationResult> results;
  final prompts = <String>[];

  Future<SummarizationResult> call(SummarizationRequest request) async {
    prompts.add(request.prompt);
    return results.removeAt(0);
  }
}

const _pin = 'use fleet_sweep.sh; never hand-roll the gh battery';

PinnedOperativePayload _payload() {
  final registry = SkillOperativePins.build([
    _skill('fleet', [_pin]),
  ]);
  return PinnedOperativePayload(
    block: pinnedOperativePromptBlock(registry)!,
    lines: {for (final pin in registry.pins) pin.line},
  );
}

void main() {
  group('UT-PIN-5 — CompactionPrompts carries the pinned section', () {
    test('default bundle carries the built-in verbatim-preserve prompt', () {
      expect(defaultCompactionPrompts.pinnedOperative, pinnedOperativePrompt);
      expect(
        RegExp(
          'verbatim',
          caseSensitive: false,
        ).hasMatch(pinnedOperativePrompt),
        isTrue,
      );
      expect(pinnedOperativePrompt, contains('character-for-character'));
    });

    test('override id compaction/pinned_operative resolves', () {
      const overrides = PromptOverrides({
        'compaction/pinned_operative': 'custom pinned duty',
      });
      final prompts = CompactionPrompts.fromOverrides(overrides);
      expect(prompts.pinnedOperative, 'custom pinned duty');
    });

    test('empty overrides keep the built-in', () {
      final prompts = CompactionPrompts.fromOverrides(PromptOverrides.empty);
      expect(prompts.pinnedOperative, pinnedOperativePrompt);
    });
  });

  group('AC3 — the pinned block rides the summarization prompts', () {
    test('first summary: block after conversation, duty in the tail', () async {
      final fake = _FakeSummarizer([SummarizationResult.success('checkpoint')]);
      await generateSummary(
        [UserMessage.text('hello')],
        summarize: fake.call,
        pinnedOperative: _payload(),
      );
      final prompt = fake.prompts.single;
      expect(prompt, contains('PINNED OPERATIVE LINES'));
      expect(prompt, contains('"$_pin"'));
      expect(prompt, contains('pinned from skill `fleet`'));
      // Block after the conversation, before the instruction tail.
      expect(
        prompt.indexOf('</conversation>'),
        lessThan(prompt.indexOf('PINNED OPERATIVE LINES')),
      );
      expect(
        prompt.indexOf('$_pin"'),
        lessThan(prompt.indexOf('PINNED SKILL DIRECTIVES')),
      );
      expect(
        prompt.indexOf('PINNED OPERATIVE LINES'),
        lessThan(prompt.indexOf('PINNED SKILL DIRECTIVES')),
      );
    });

    test(
      'update path (previousSummary) carries block + duty too (E7)',
      () async {
        final fake = _FakeSummarizer([SummarizationResult.success('fold 2')]);
        await generateSummary(
          [UserMessage.text('more')],
          summarize: fake.call,
          previousSummary: '## Goal\nearlier work',
          pinnedOperative: _payload(),
        );
        final prompt = fake.prompts.single;
        expect(prompt, contains('PINNED OPERATIVE LINES'));
        expect(prompt, contains('PINNED SKILL DIRECTIVES'));
        expect(prompt, contains('<previous-checkpoint>'));
      },
    );

    test('turn prefix path carries block + duty (E7, split turn)', () async {
      final fake = _FakeSummarizer([
        SummarizationResult.success('history checkpoint'),
        SummarizationResult.success('turn prefix checkpoint'),
      ]);
      final manager = CompactionManager(
        summarize: fake.call,
        pinnedOperative: _payload(),
      );
      final preparation = CompactionPreparation(
        firstKeptEntryId: 'e2',
        messagesToSummarize: [UserMessage.text('old history')],
        turnPrefixMessages: [UserMessage.text('prefix of a split turn')],
        isSplitTurn: true,
        tokensBefore: 100,
      );
      final result = await manager.compact(preparation);
      // Both calls of the split turn carry the block + the duty.
      expect(fake.prompts, hasLength(2));
      for (final prompt in fake.prompts) {
        expect(prompt.contains('PINNED OPERATIVE LINES'), isTrue);
        expect(prompt.contains('"$_pin"'), isTrue);
        expect(prompt.contains('PINNED SKILL DIRECTIVES'), isTrue);
      }
      expect(result.summary, contains('turn prefix checkpoint'));
    });

    test('F4 compat: no pins → prompts byte-identical to the pre-pin '
        'pipeline', () async {
      final fakeA = _FakeSummarizer([SummarizationResult.success('ckpt')]);
      final fakeB = _FakeSummarizer([SummarizationResult.success('ckpt')]);
      await generateSummary([UserMessage.text('hello')], summarize: fakeA.call);
      await generateSummary(
        [UserMessage.text('hello')],
        summarize: fakeB.call,
        pinnedOperative: null,
      );
      expect(fakeA.prompts.single, fakeB.prompts.single);
      expect(fakeA.prompts.single.contains('PINNED OPERATIVE'), isFalse);
    });
  });

  group('AC4 — sanitizer pin protection on the persist path', () {
    test('a pin the summarizer copied verbatim survives; ephemeral '
        'neighbors strip', () async {
      final ephemeral =
          "Your last tool call's result was dropped from "
          'context.';
      final fake = _FakeSummarizer([
        SummarizationResult.success('## Goal\nx\n\n$ephemeral\n\n"$_pin"\n'),
      ]);
      final manager = CompactionManager(
        summarize: fake.call,
        pinnedOperative: _payload(),
      );
      final preparation = CompactionPreparation(
        firstKeptEntryId: 'e1',
        messagesToSummarize: [UserMessage.text('hello')],
        turnPrefixMessages: const [],
        isSplitTurn: false,
        tokensBefore: 100,
      );
      final result = await manager.compact(preparation);
      expect(result.summary, contains('"$_pin"'));
      expect(result.summary.contains(ephemeral), isFalse);
      expect((result.details as Map)['sanitizedEphemeral'], isNotEmpty);
    });
  });

  group('IT-PIN-8/AC9 — fold-on-fold keeps pins byte-stable', () {
    test('three generations render the identical pinned block', () async {
      final payload = _payload();
      final block = payload.block;
      final promptsSeen = <String>[];
      String? prior;
      for (var generation = 1; generation <= 3; generation++) {
        final fake = _FakeSummarizer([
          SummarizationResult.success(
            'gen $generation checkpoint. Pinned: "$_pin"',
          ),
        ]);
        final summary = await generateSummary(
          [UserMessage.text('work of generation $generation')],
          summarize: fake.call,
          previousSummary: prior,
          pinnedOperative: payload,
        );
        promptsSeen.add(fake.prompts.single);
        // The registry (not the prior checkpoint) is the source: the
        // block is byte-identical at every generation, whatever the
        // summarizer paraphrased around it.
        expect(fake.prompts.single.contains(block), isTrue);
        prior = summary;
      }
      for (final prompt in promptsSeen) {
        expect(prompt.contains(block), isTrue);
      }
    });
  });

  group('REG-PIN-3/AC8 — session records byte-identical on/off', () {
    test('compactSession with and without pins appends equal records', () async {
      final envA = MemoryExecutionEnv();
      final envB = MemoryExecutionEnv();
      final repoA = JsonlSessionRepo(
        fs: envA,
        sessionsRoot: '/sessions',
        now: () => DateTime.utc(2026),
      );
      final repoB = JsonlSessionRepo(
        fs: envB,
        sessionsRoot: '/sessions',
        now: () => DateTime.utc(2026),
      );
      final sessionA = await repoA.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 'reg-pin-3'),
      );
      final sessionB = await repoB.create(
        JsonlSessionCreateOptions(cwd: '/work', id: 'reg-pin-3'),
      );

      Future<void> seed(Session session) async {
        for (var i = 0; i < 6; i++) {
          await session.appendMessage(
            UserMessage.text('user message $i ${'x' * 120}'),
          );
          await session.appendMessage(_assistant('answer $i ${'y' * 120}'));
        }
      }

      await seed(sessionA);
      await seed(sessionB);

      Future<SummarizationResult> fakeSummarizer(
        SummarizationRequest request,
      ) async {
        // The fake IGNORES the prompt (a pin-oblivious summarizer) — the
        // records must still come out identical.
        return SummarizationResult.success(
          '## Goal\nfixed checkpoint\n\n## Next Steps\n1. continue',
        );
      }

      const settings = CompactionSettings(
        enabled: true,
        reserveTokens: 16384,
        keepRecentTokens: 150,
      );
      final managerOn = CompactionManager(
        summarize: fakeSummarizer,
        settings: settings,
        pinnedOperative: _payload(),
      );
      final managerOff = CompactionManager(
        summarize: fakeSummarizer,
        settings: settings,
      );
      final recordOn = await managerOn.compactSession(sessionA);
      final recordOff = await managerOff.compactSession(sessionB);
      expect(recordOn, isNotNull);
      expect(recordOff, isNotNull);

      Future<String> sessionBytes(MemoryExecutionEnv env) async {
        final paths = <String>[];
        Future<void> walk(String dir) async {
          final entries = (await env.listDir(dir)).valueOrNull ?? const [];
          for (final entry in entries) {
            if (entry.kind == FileKind.directory) {
              await walk(entry.path);
            } else if (entry.name.endsWith('.jsonl')) {
              paths.add(entry.path);
            }
          }
        }

        await walk('/sessions');
        paths.sort();
        final buffers = <String>[];
        for (final path in paths) {
          buffers.add((await env.readTextFile(path)).valueOrNull ?? '');
        }
        return buffers.join('\n');
      }

      // The pipeline itself adds no pin bytes: both sessions persist the
      // same records (the fake summarizer never echoes pins, so nothing
      // pin-shaped lands in either). Volatile per-session fields (random
      // record ids, wall-clock timestamps) are normalized out — record
      // KINDS, structure and content must be equal.
      String normalize(String bytes) => bytes
          .replaceAllMapped(RegExp(r'"id":"[^"]*"'), (match) => '"id":X')
          .replaceAllMapped(
            RegExp(r'"(?:parentId|firstKeptEntryId)":"[^"]*"'),
            (match) =>
                '${match.group(0)!.substring(1, match.group(0)!.indexOf(':'))}:X',
          )
          .replaceAllMapped(
            RegExp(r'"timestamp":"[^"]*"'),
            (match) => '"timestamp":X',
          )
          .replaceAllMapped(
            RegExp(r'"timestamp":\d+'),
            (match) => '"timestamp":X',
          );
      final bytesOn = await sessionBytes(envA);
      final bytesOff = await sessionBytes(envB);
      expect(normalize(bytesOn), normalize(bytesOff));
      expect(bytesOn.contains(_pin), isFalse);
      expect(bytesOff.contains(_pin), isFalse);
      // Sanity: the file is real JSONL and the compaction record landed.
      expect(bytesOn.trim().split('\n'), isNotEmpty);
      expect(jsonDecode(bytesOn.trim().split('\n').first), isA<Map>());
      expect(normalize(bytesOn), contains('"type":"compaction"'));
    });
  });
  structuredCheckpointTests();
}

/// E7 — the structured-engine checkpoint path carries the pinned block
/// too (window 8000, reserve 2000 → trigger 6000, keep-recent 2000).
const _structuredSettings = CompactionSettings(
  enabled: true,
  reserveTokens: 2000,
  keepRecentTokens: 2000,
);

AssistantMessage _structuredAssistant(String text, {List<ToolCall>? calls}) {
  return AssistantMessage(
    content: [
      TextContent(text: text),
      ...?calls,
    ],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolResultMessage _structuredResult(String callId, String name, String text) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: name,
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );
}

void structuredCheckpointTests() {
  group('E7 — the structured checkpoint carries the pinned block', () {
    test('checkpoint prompt carries the pin block + duty; pin survives in '
        'the persisted checkpoint', () async {
      final repo = JsonlSessionRepo(
        fs: MemoryExecutionEnv(),
        sessionsRoot: '/sessions',
      );
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('fix the login crash'));
      await session.appendMessage(
        _structuredAssistant(
          'looking',
          calls: [ToolCall(id: 'c1', name: 'read', arguments: const {})],
        ),
      );
      await session.appendMessage(_structuredResult('c1', 'read', 'x' * 16000));
      await session.appendMessage(
        _structuredAssistant(
          'running tests',
          calls: [ToolCall(id: 'c2', name: 'bash', arguments: const {})],
        ),
      );
      await session.appendMessage(_structuredResult('c2', 'bash', 'y' * 12000));
      for (var i = 0; i < 6; i++) {
        await session.appendMessage(_structuredAssistant('filler analysis $i'));
      }
      final messages = await session.buildContextMessages();
      final state = AgentState(
        model: Model(
          id: 'm1',
          name: 'm1',
          api: 'anthropic-messages',
          provider: 'p',
          baseUrl: 'http://localhost:1',
          contextWindow: 8000,
          maxTokens: 4096,
        ),
        messages: messages,
      );
      final pins = _payload();
      final promptsSeen = <String>[];
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _structuredSettings,
        // An empty hide list ends the hide loop without failure — the run
        // proceeds to the checkpoint pass while still over the trigger.
        judge: (ledger) async => '[]',
        summarize: (request) async {
          promptsSeen.add(request.prompt);
          // The summarizer copies the pin verbatim (obedient case).
          return SummarizationResult.success('## Goal\nfixed\n\n"$_pin"\n');
        },
        checkpointPrompt:
            'CHECKPOINT INSTRUCTIONS '
            '\n${defaultCompactionPrompts.pinnedOperative}',
        pinnedOperativeBlock: pins.block,
        pinnedLines: pins.lines,
      );
      final hid = await compactor.run();
      expect(hid, isTrue);
      expect(promptsSeen, isNotEmpty);
      for (final prompt in promptsSeen) {
        expect(prompt.contains('PINNED OPERATIVE LINES'), isTrue);
        expect(prompt.contains('"$_pin"'), isTrue);
        // The block rides BEFORE the checkpoint instruction tail.
        expect(
          prompt.indexOf('PINNED OPERATIVE LINES'),
          lessThan(prompt.indexOf('CHECKPOINT INSTRUCTIONS')),
        );
      }
      // The persisted checkpoint keeps the pin verbatim
      // (sanitizer-protected, AC4 on the structured path).
      final entries = await session.getEntries();
      final checkpointText = entries
          .whereType<CompactCheckpointRecord>()
          .map((record) => record.text)
          .join('\n');
      expect(checkpointText, isNotEmpty);
      expect(checkpointText.contains('"$_pin"'), isTrue);
    });
  });
}
