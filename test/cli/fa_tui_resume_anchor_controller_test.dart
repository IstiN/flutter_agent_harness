// Issue #827 × #446: the RESUMED session restores the current-turn anchor
// through the real controller pipeline. The session replay writes the
// transcript, then the host calls `setReplayTurnAnchor` — the message must
// land AFTER the replayed output (`_send` flushes the buffer ahead of every
// non-output message) and resolve the echo index against the model's own
// output length, so the resumed window pins at the same turn boundary a
// live submit pinned at (resume renders 1:1 with live).
//
// Real controller + real program loop over an in-memory frame sink — no
// PTY, no IO (the PTY suites need a host tty).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart'
    show TuiProgramHooks, stripAnsi;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> data) => _bytes.add(data);

  void addError(Object error, [StackTrace? stackTrace]) {}

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

FaTuiCallbacks _callbacks() => FaTuiCallbacks(
  onSubmit: (_, {images = const []}) async {},
  onModelSelected: (_) async {},
  buildSlashMenu: (_) => const [],
  buildModelMenu: (_, _) => const [],
  statusLine: () => 'test',
  prompt: 'fa> ',
);

void main() {
  test('replay output + setReplayTurnAnchor pins the resumed window at the '
      'echo', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final controller = FaTuiController(
      callbacks: _callbacks(),
      isExited: () => false,
      programHooks: TuiProgramHooks(
        input: keys.stream,
        output: frames,
        width: 80,
        height: 24,
      ),
    );

    // The replay stream: 40 old rows, the last prompt echo (rule + text +
    // blank = lines 40..42), a 12-row reply — 15 rows, so the turn FITS the
    // 19-row viewport and the anchor pins above the bottom.
    for (var i = 0; i < 40; i++) {
      controller.sendOutput('old row $i', newline: true);
    }
    controller.sendOutput('${'─' * 80}\nRESUMED-PROMPT check the fold\n');
    for (var i = 0; i < 12; i++) {
      controller.sendOutput('resumed answer $i', newline: true);
    }
    controller.setReplayTurnAnchor(14);
    final run = controller.run();

    try {
      await waitForIt(() => frames.text.contains('resumed answer 11'));
      // The rendered screen pins at the replayed echo: the whole turn is
      // on the glass, the pre-echo rows are above the fold named by the
      // hint. (The count proves the ordering too — the anchor resolved
      // against the FULL 55-line stream; processed early it would degrade
      // to the bottom-follow window and paint old rows instead.)
      final screen = stripAnsi(frames.text);
      expect(screen, contains('^ 40 lines above fold - PgUp'));
      expect(screen, contains('RESUMED-PROMPT check the fold'));
      expect(screen, contains('resumed answer 11'));
      expect(screen, isNot(contains('old row')),
          reason: 'pre-echo rows stay above the fold on the resumed glass');
    } finally {
      keys.add([0x03]); // press 1 arms the double-press window (#830)…
      keys.add([0x03]); // …press 2 quits the TUI
      await run;
      await keys.close();
    }
  });
}
