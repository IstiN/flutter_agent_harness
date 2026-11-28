// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

/// gh-2472 — the model-facing `m<N>` record tags a model echoes into its
/// replies never reach the CLI's user-facing output. The persist-side
/// echo hygiene (`_withoutRecordTagEcho`) cleans the COMPLETE message;
/// the LIVE streaming deltas render verbatim, so the echo reached the
/// TUI (`>_Fa m1482 …`, the owner screenshot). These tests pin the
/// render-path hygiene:
/// - the raw live face streams sanitized deltas — a tag split across two
///   deltas (`m14` + `82 При…`) never flickers a fragment;
/// - the styled (ansi) face renders the sanitized buffer at message end;
/// - an undecided tail (`m2` with no trailing space) survives verbatim —
///   the gh-2412 `^m\d+ +` regex semantics is the contract;
/// - the TUI face paints the clean text under the `>_Fa ` prefix.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart'
    show TuiProgramHooks;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// One assistant turn whose answer streams in [deltas] fragments.
List<AssistantMessageEvent> splitDeltaTurn(List<String> deltas) {
  final empty = testAssistant();
  final partial = testAssistant(content: [TextContent(text: deltas.join())]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    for (final delta in deltas)
      TextDeltaEvent(contentIndex: 0, delta: delta, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> data) => _bytes.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);
}

/// Strips SGR/CSI sequences and collapses runs of spaces (the TUI frames
/// carry cursor moves; wrapped rows carry padding).
String _normalize(String s) => s
    .replaceAll(RegExp('\x1b\\[[0-9;?]*[a-zA-Z]'), '')
    .replaceAll(RegExp(' +'), ' ');

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction fake, {
    MarkdownSurface? markdownSurface,
    bool useTui = false,
    StreamController<List<int>>? keys,
    _FrameSink? frames,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive-Value]',
      env: env,
      sessionRoot: '/sessions',
      approvalMode: ApprovalMode.yolo,
      skillsAccess: SkillsAccess.granted,
      tuiProgramHooks: useTui
          ? TuiProgramHooks(
              input: keys!.stream,
              output: frames!,
              width: 80,
              height: 24,
            )
          : null,
    ),
    io: io,
    streamFunction: fake,
    useTui: useTui,
    markdownSurface: markdownSurface,
  );

  group('gh-2472: echoed record tags never reach the CLI output', () {
    test('raw live face: a tag split across deltas never flickers', () async {
      final fake = FakeStreamFunction([
        splitDeltaTurn(['m14', '82 Принято…']),
      ]);
      final cli = cliFor(
        fake.call,
        markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.raw),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('Принято…'));
      expect(
        out.contains('m14'),
        isFalse,
        reason: 'the echoed tag leaked to the live stream: $out',
      );
    });

    test('raw live face: an undecided tail survives verbatim', () async {
      final fake = FakeStreamFunction([
        splitDeltaTurn(['ответ\nm2']),
      ]);
      final cli = cliFor(
        fake.call,
        markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.raw),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      // `m2` has no trailing space — `^m\d+ +` never matched, the bytes
      // are the model's own words (the gh-2412 regex contract).
      expect(io.out.toString(), contains('ответ\nm2'));
    });

    test(
      'raw live face: a tag-only reply paints nothing (leading alias)',
      () async {
        // gh-2472 review: `m3208` alone is a reply that is ONLY its tag —
        // the gh-2412 leading-alias rule (`^m\d+(?=\s|$)`) strips it at the
        // finalize seam; the live face must not flash it either. The
        // stripped reply is a CLEAN empty, so the pre-existing #1085
        // empty-reply nudge fires a scripted `continue` turn (the tag-only
        // carrier shape is real: record_tag.dart's pure tool-call carrier).
        final fake = FakeStreamFunction([
          splitDeltaTurn(['m320', '8']),
          splitDeltaTurn(['Продолжаю: готово']),
        ]);
        final cli = cliFor(
          fake.call,
          markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.raw),
        );
        final run = cli.run();
        io.sendLine('hi');
        await waitForIt(() => fake.calls == 2 && !cli.isBusy);
        io.sendLine('/exit');
        await run;

        final out = io.out.toString();
        expect(
          out.contains('m3208'),
          isFalse,
          reason: 'the tag-only reply leaked to the live stream: $out',
        );
        expect(out, contains('Продолжаю: готово'));
      },
    );

    test('raw live face: a leading alias before a newline strips', () async {
      final fake = FakeStreamFunction([
        splitDeltaTurn(['m3208\nреальный ответ']),
      ]);
      final cli = cliFor(
        fake.call,
        markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.raw),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('реальный ответ'));
      expect(out.contains('m3208'), isFalse, reason: out);
    });

    test('ansi buffered face: the end-of-message render is clean', () async {
      final fake = FakeStreamFunction([
        splitDeltaTurn(['m', '1482 Один']),
      ]);
      final cli = cliFor(
        fake.call,
        markdownSurface: const MarkdownSurface(mode: MarkdownSurfaceMode.ansi),
      );
      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains('Один'));
      expect(out.contains('m1482'), isFalse, reason: out);
    });

    test('TUI face: clean text paints under the >_Fa prefix', () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      addTearDown(keys.close);
      final fake = FakeStreamFunction([
        splitDeltaTurn(['m14', '82 Принято. Ставлю ватч на PR']),
      ]);
      final cli = cliFor(fake.call, useTui: true, keys: keys, frames: frames);
      final run = cli.run();
      try {
        await waitForIt(
          () => frames.text.contains('\x1b[?1049h'),
          reason: 'the TUI boot reached the frame renderer',
        );
        keys.add(utf8.encode('hi'));
        keys.add([0x0d]);
        await waitForIt(
          () => _normalize(frames.text).contains('Принято'),
          reason: 'the turn streamed its sanitized answer',
        );

        final painted = _normalize(frames.text);
        expect(painted, contains('>_Fa'));
        expect(painted, contains('Принято'));
        expect(
          painted.contains('m14'),
          isFalse,
          reason: 'the echoed tag flickered through the TUI: $painted',
        );
      } finally {
        keys.add([0x03]);
        keys.add([0x03]);
        await run.timeout(const Duration(seconds: 10), onTimeout: () {});
        await io.close();
      }
    });
  });
}
