// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// The kaomoji thinking indicator's Flutter rendering (issue #1374): the
// random-frame swap cadence, the thinking block's SVG sprite icon (the
// head-with-gear is gone), and the status row's two-tone text spans —
// all deterministic through the seeded [Random] seam.
//
// Both swap clocks are TICKERS on the fake frame clock — the indicator
// owns no timer — so `tester.pump` drives the faces exactly like it
// drives the status row's elapsed seconds, and no test can end with a
// pending timer.
library;

import 'dart:math';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show
        KaomojiFace,
        KaomojiFacePicker,
        MemoryExecutionEnv,
        kKaomojiSwapPeriod;
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

/// The face the [KaomojiFacePicker] shows after [swaps] swaps from
/// [seed] — the replay twin every cadence assertion compares against.
KaomojiFace replayFace(int seed, int swaps) {
  final picker = KaomojiFacePicker(Random(seed));
  var face = picker.first();
  for (var i = 0; i < swaps; i++) {
    face = picker.next();
  }
  return face;
}

/// The face the mounted [KaomojiThinkingIcon] shows. Matches ONLY the
/// keyed box — flutter_svg 2.3.0 (the committed `flutter_app/
/// pubspec.lock` pin) mounts its own internal `SizedBox`es, so a
/// `find.byType(SizedBox)` matcher threw `Too many elements` (PR #1419
/// re-review round 2). The key is ours alone and version-stable.
KaomojiFace _shownFace(WidgetTester tester) =>
    (tester.widget(find.byWidgetPredicate(
      (w) => w.key is ValueKey<KaomojiFace>,
    )).key! as ValueKey<KaomojiFace>).value;

Widget _tileWrap(Widget child) {
  return FaUiThemeProvider(
    data: const FaUiTheme(),
    child: MaterialApp(
      theme: buildFahTheme(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

/// The status row's service stand-in (same pattern as
/// fa_run_status_row_test.dart).
class _PhaseService extends FakeChatService {
  final List<FaChatMessage> rows = [];
  bool streaming = false;

  @override
  List<FaChatMessage> get messages => rows;
  @override
  bool get isStreaming => streaming;

  void notify() => notifyListeners();
}

/// A transcript-level service for the live-thinking wiring test: a real
/// message list the screen's metadata mapping consumes.
class _TranscriptService extends FakeChatService {
  List<FaChatMessage> msgs = const [];
  bool streaming = false;

  @override
  List<FaChatMessage> get messages => msgs;
  @override
  bool get isStreaming => streaming;
}

/// (active, face) per thinking tile's [KaomojiSwapper], in tree order.
/// The transcript renders NEWEST-FIRST, so ORDER IS NOT THE CONTRACT —
/// the gate is: each tile is identified by its swapper's
/// [KaomojiSwapper.active] flag (exactly one live), and only the live
/// face ever moves.
List<(bool, KaomojiFace)> _swapperStates(WidgetTester tester) => [
      for (final swapper in tester.widgetList<KaomojiSwapper>(
        find.byType(KaomojiSwapper),
      ))
        (swapper.active, _faceOf(tester, swapper)),
    ];

/// The face a specific swapper's tile shows, through the keyed box its
/// builder mounts ([_shownFace]'s matcher, scoped to one swapper).
KaomojiFace _faceOf(WidgetTester tester, KaomojiSwapper swapper) {
  final box = tester.widget(
    find.descendant(
      of: find.byWidget(swapper),
      matching: find.byWidgetPredicate((w) => w.key is ValueKey<KaomojiFace>),
    ),
  );
  return (box.key! as ValueKey<KaomojiFace>).value;
}

void main() {
  testWidgets('KaomojiSwapper: random swap exactly on the ~0.9 s cadence',
      (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: KaomojiSwapper(
          random: Random(7),
          builder: (_, face) => Text(face.text),
        ),
      ),
    );
    String shown() => tester.widget<Text>(find.byType(Text)).data!;

    final first = shown();
    expect(first, replayFace(7, 0).text);
    await tester.pump(kKaomojiSwapPeriod - const Duration(milliseconds: 1));
    expect(shown(), first, reason: 'no swap before the cadence boundary');
    await tester.pump(const Duration(milliseconds: 1));
    expect(shown(), replayFace(7, 1).text);
    expect(shown(), isNot(first), reason: 'a swap never repeats the face');
    await tester.pump(kKaomojiSwapPeriod);
    expect(shown(), replayFace(7, 2).text);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('KaomojiSwapper: active=false freezes the face (AC4)',
      (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: KaomojiSwapper(
          active: false,
          random: Random(3),
          builder: (_, face) => Text(face.text),
        ),
      ),
    );
    final frozen = tester.widget<Text>(find.byType(Text)).data!;
    await tester.pump(const Duration(seconds: 3));
    expect(
      tester.widget<Text>(find.byType(Text)).data,
      frozen,
      reason: 'an inactive indicator never animates',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('KaomojiSwapper: going inactive mid-run stops the swaps',
      (tester) async {
    Widget tree({required bool active}) => Directionality(
          textDirection: TextDirection.ltr,
          child: KaomojiSwapper(
            active: active,
            random: Random(7),
            builder: (_, face) => Text(face.text),
          ),
        );
    await tester.pumpWidget(tree(active: true));
    await tester.pump(kKaomojiSwapPeriod);
    final afterFirstSwap = tester.widget<Text>(find.byType(Text)).data!;
    expect(afterFirstSwap, replayFace(7, 1).text);

    // The phase ends: the same position in the tree flips inactive.
    await tester.pumpWidget(tree(active: false));
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.widget<Text>(find.byType(Text)).data,
      afterFirstSwap,
      reason: 'the swap clock stopped with the phase',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('thinking tile: the kaomoji sprite replaces the '
      'head-with-gear, frozen when the phase is over', (tester) async {
    await tester.pumpWidget(
      _tileWrap(
        ChatMessageTile(
          message: FaChatMessage(role: 'thinking', content: 'hmm'),
          images: SandboxImageResolver(MemoryExecutionEnv()),
        ),
      ),
    );
    expect(find.byType(KaomojiThinkingIcon), findsOneWidget);
    expect(find.byIcon(Icons.psychology_outlined), findsNothing);
    expect(tester.takeException(), isNull);
    final frozen = _shownFace(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(_shownFace(tester), same(frozen),
        reason: 'a finished thinking note keeps its frozen face');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('thinkingLive: the tile icon swaps on the ~0.9 s cadence',
      (tester) async {
    await tester.pumpWidget(
      _tileWrap(
        ChatMessageTile(
          message: FaChatMessage(role: 'thinking', content: 'hmm'),
          images: SandboxImageResolver(MemoryExecutionEnv()),
          thinkingLive: true,
        ),
      ),
    );
    final before = _shownFace(tester);
    await tester.pump(kKaomojiSwapPeriod - const Duration(milliseconds: 1));
    expect(_shownFace(tester), same(before),
        reason: 'no swap before the cadence boundary');
    await tester.pump(const Duration(milliseconds: 1));
    expect(_shownFace(tester), isNot(same(before)),
        reason: 'the live thinking block animates');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle: the status row mounts no face (AC4)', (tester) async {
    final service = _PhaseService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FaRunStatusRow(service: service)),
      ),
    );
    expect(find.byType(KaomojiFaceText), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('status row (web TUI Working…): two-tone face spans, '
      'random swap on the shared cadence, gone with the phase',
      (tester) async {
    final service = _PhaseService()
      ..rows.add(FaChatMessage(role: 'user', content: 'go'))
      ..streaming = true
      ..notify();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FaRunStatusRow(service: service)),
      ),
    );
    expect(find.textContaining('Thinking'), findsOneWidget);

    const eye = Color(0xFF60D0D0);
    const mouth = Color(0xFF70A0E0);
    TextSpan richRoot() => tester
        .widget<RichText>(
          find.descendant(
            of: find.byType(KaomojiFaceText),
            matching: find.byType(RichText),
          ),
        )
        .text as TextSpan;

    // Text.rich does NOT mount the given span as the RichText root — it
    // nests it under a wrapper span (text: null), so the run spans sit
    // one level down (PR #1419 re-review round 2; reading
    // `root().children![0].text` nulled).
    List<TextSpan> runs() => [
      for (final span in (richRoot().children!.single as TextSpan).children!)
        span as TextSpan,
    ];
    String shown() => [for (final span in runs()) span.text!].join();
    Set<Color> tones() => {
      for (final span in runs()) span.style!.color!,
    };

    // First tick: the run opens on a random face.
    await tester.pump(const Duration(milliseconds: 100));
    final first = shown();
    expect(first, isNotEmpty);
    expect(
      tones(),
      containsAll({eye, mouth}),
      reason: '$first renders two-tone: teal eyes/face strokes, blue mouth',
    );
    expect(
      tones().every((tone) => tone == eye || tone == mouth),
      isTrue,
      reason: 'no color outside the brand palette',
    );

    // Sub-cadence ticks repaint nothing; the 0.9 s boundary swaps.
    await tester.pump(const Duration(milliseconds: 800));
    expect(shown(), first, reason: 'no swap before the cadence boundary');
    await tester.pump(const Duration(milliseconds: 100));
    expect(shown(), isNot(first), reason: 'a swap never repeats the face');

    // Phase end: the face (and the ticker driving it) stops with the row.
    service
      ..streaming = false
      ..notify();
    await tester.pump();
    expect(find.byType(KaomojiFaceText), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('liveThinkingMessage: the NEWEST thinking block, only while '
      'streaming', () {
    final service = _TranscriptService()
      ..msgs = [
        FaChatMessage(role: 'thinking', content: 'finished turn'),
        FaChatMessage(role: 'user', content: 'go on'),
        FaChatMessage(role: 'thinking', content: 'live turn'),
      ];
    expect(liveThinkingMessage(service), isNull, reason: 'idle: nothing live');
    expect(liveThinkingMessageIndex(service), -1);

    service.streaming = true;
    expect(liveThinkingMessageIndex(service), 2);
    expect(liveThinkingMessage(service), same(service.msgs[2]));

    // A transcript with no thinking block at all stays ungated.
    service.msgs = [FaChatMessage(role: 'user', content: 'hi')];
    expect(liveThinkingMessage(service), isNull);
  });

  testWidgets('wiring (AC4): only the NEWEST thinking tile animates while '
      'a run streams — finished notes stay frozen', (tester) async {
    // The regression for the PR #1419 re-review probe: two thinking
    // tiles through the REAL chat-screen mapping, one pump past the
    // swap boundary, only the live block's face moves.
    final service = _TranscriptService()
      ..msgs = [
        FaChatMessage(role: 'thinking', content: 'finished turn'),
        FaChatMessage(role: 'user', content: 'go on'),
        FaChatMessage(role: 'thinking', content: 'live turn'),
      ]
      ..streaming = true;
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: FaChatScreen(service: service)));
    // The transcript sync (50 ms debounce) + the reveal gate's frame.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    // Round-3 review contract: identify the tiles through the GATE
    // itself, not through tree order — the transcript renders
    // NEWEST-FIRST (a positional [0]/[1] assumption inverts the
    // assertions). Exactly one swapper is live; only its face moves.
    expect(_swapperStates(tester), hasLength(2));
    expect(
      _swapperStates(tester).where((state) => state.$1),
      hasLength(1),
      reason: 'exactly ONE live swapper: the newest thinking block',
    );
    final liveBefore = _swapperStates(tester).firstWhere((s) => s.$1).$2;
    final frozenBefore = _swapperStates(tester).firstWhere((s) => !s.$1).$2;

    await tester.pump(kKaomojiSwapPeriod);

    final after = _swapperStates(tester);
    expect(
      after.where((state) => state.$1),
      hasLength(1),
      reason: 'the gate stays single-live across the swap boundary',
    );
    expect(after.firstWhere((s) => s.$1).$2, isNot(same(liveBefore)),
        reason: 'the LIVE thinking block animates');
    expect(after.firstWhere((s) => !s.$1).$2, same(frozenBefore),
        reason: 'the finished thinking note keeps its frozen face');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('KaomojiFaceText: a degenerate (whitespace) face falls back '
      'to a plain span — never a crash', (tester) async {
    const blank = KaomojiFace(
      'test-blank',
      [(' ', false)],
      [(' ', false)],
      '',
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: KaomojiFaceText(face: blank),
      ),
    );
    expect(tester.takeException(), isNull);
    // The fallback mounts the text as the ROOT span (a plain Text), not
    // the nested run structure of the two-tone path.
    final root =
        tester.widget<RichText>(find.byType(RichText)).text as TextSpan;
    expect(root.text, ' ');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
