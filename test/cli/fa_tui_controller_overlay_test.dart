import 'dart:async';
import 'dart:io' show Platform, ProcessException, ProcessResult;

import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/composer_overlay.dart'
    show groupOf;
import 'package:flutter_agent_harness/src/cli/agent_hub_tui.dart';
import 'package:flutter_agent_harness/src/cli/fuzzy_matcher.dart' show scoreFuzzy;
import 'package:flutter_agent_harness/src/tools/ask_tool.dart' show AskOption;
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart' show MenuItem;
import 'package:test/test.dart';

/// Controller lifecycle + overlay areas of the fa_tui suite, split out of
/// fa_tui_test.dart to keep both files under the 2800-line gate.
void main() {
  FaTuiCallbacks callbacks({
    List<String> submitted = const [],
    List<String> selectedModels = const [],
    void Function()? onInterrupt,
    Map<String, String>? picked,
    List<List<String>>? steered,
    bool Function()? isShiftPressed,
    List<String> Function(String fragment)? pathCandidates,
  }) {
    return FaTuiCallbacks(
      onSubmit: (line, {images = const []}) async => submitted.add(line),
      onInterrupt: onInterrupt,
      isShiftPressed: isShiftPressed,
      opensPicker: (key) => key == '/sessions',
      onPickerSelected: (pickerId, key) async => picked?[pickerId] = key,
      onSteer: (messages) async => steered?.add(messages),
      onModelSelected: (id) async => selectedModels.add(id),
      buildSlashMenu: (prefix) {
        const items = [
          MenuItem(key: '/help', label: '/help', description: 'show help'),
          MenuItem(key: '/exit', label: '/exit', description: 'quit'),
          MenuItem(key: '/model', label: '/model', description: 'select model'),
          MenuItem(
            key: '/sessions',
            label: '/sessions',
            description: 'list sessions',
          ),
        ];
        final lower = prefix.toLowerCase();
        return items
            .where(
              (item) =>
                  item.key.toLowerCase().contains(lower) ||
                  item.description.toLowerCase().contains(lower) ||
                  // Mirror production slash_menu.dart: subsequence fallback
                  // so '/e' still surfaces /help and /model.
                  lower.isEmpty ||
                  scoreFuzzy(item.key, lower) != null,
            )
            .toList();
      },
      buildModelMenu: (filter, _) => [
        if ('model-a'.contains(filter))
          const MenuItem(key: 'model-a', label: 'model-a'),
        if ('model-b'.contains(filter))
          const MenuItem(key: 'model-b', label: 'model-b'),
      ],
      statusLine: () => '/work · 0tok · turn 0 · test-model',
      prompt: 'fa> ',
      pathCandidates: pathCandidates,
    );
  }
  group('FaTuiController pre-run queueing', () {
    test('sendOutput before run buffers and flushes without a program', () {
      // Pre-run sends flush straight into the pending queue (the program
      // replays them at run time); none of this touches a terminal.
      final controller = FaTuiController(
        callbacks: callbacks(),
        isExited: () => false,
      );
      expect(
        () => controller
          ..sendOutput('hello')
          ..sendOutput(' world', newline: true)
          ..sendOutput(''),
        returnsNormally,
      );
    });

    test('openPicker resolves the initial selection by key', () {
      final controller = FaTuiController(
        callbacks: callbacks(),
        isExited: () => false,
      );
      const items = [
        MenuItem(key: 'a', label: 'a'),
        MenuItem(key: 'b', label: 'b'),
      ];
      expect(
        () => controller
          ..openPicker('sessions', 'Sessions', items, initialKey: 'b')
          ..openPicker('sessions', 'Sessions', items, initialKey: 'missing')
          ..openPicker('sessions', 'Sessions', items),
        returnsNormally,
      );
    });

    test('openPrompt completer survives copyWith (regression test)', () {
      // Regression: _promptCompleter was lost on every copyWith, so
      // Enter/Esc could never resolve the prompt — chars worked (no
      // completer needed) but submit/cancel silently deadlocked.
      FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

      final model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      final completer = Completer<TuiPromptAnswer?>();
      var updated = send(
        model,
        OpenPromptMsg(TextPromptSpec(question: 'Enter value:'), completer),
      );
      expect(updated.prompt, isNotNull);
      expect(updated.prompt!.spec, isA<TextPromptSpec>());

      // Type a character — this creates a new model via copyWith.
      updated = send(
        updated,
        KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'x')),
      );
      expect(updated.prompt, isNotNull);
      expect(updated.prompt!.secretValue, 'x');

      // Press Enter — the completer must complete with the typed value.
      // Before the fix this silently did nothing (completer was null on
      // the copied model).
      updated = send(updated, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      expect(updated.prompt, isNull);
      expect(completer.isCompleted, isTrue);
      expect(completer.future, completion(isA<TextPromptAnswer>()));
    });

    test('prompt mode: a ctrl combo never leaks its letter into the '
        'buffer (the Cmd+Left/aaaa regression)', () {
      FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

      final model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      final completer = Completer<TuiPromptAnswer?>();
      var updated = send(
        model,
        OpenPromptMsg(TextPromptSpec(question: 'Enter value:'), completer),
      );
      updated = send(
        updated,
        KeyPressMsg(
          TeaKey(code: KeyCode.rune, text: 'a', modifiers: {KeyMod.ctrl}),
        ),
      );
      expect(updated.prompt!.secretValue, '', reason: 'ctrl+a is not text');
      // A plain char still lands.
      updated = send(
        updated,
        KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'a')),
      );
      expect(updated.prompt!.secretValue, 'a');
    });

    test('openPrompt Esc cancels and resolves with TuiPromptCancelled', () {
      FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

      final model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      final completer = Completer<TuiPromptAnswer?>();
      var updated = send(
        model,
        OpenPromptMsg(TextPromptSpec(question: 'Enter value:'), completer),
      );
      expect(updated.prompt, isNotNull);

      updated = send(updated, KeyPressMsg(const TeaKey(code: KeyCode.escape)));
      expect(updated.prompt, isNull);
      expect(completer.isCompleted, isTrue);
      expect(completer.future, completion(isA<TuiPromptCancelled>()));
    });

    test('prompt mode hides the physical cursor (inline caret only)', () {
      FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

      final model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      // Text prompt — the input row carries its own reverse-video caret, so
      // the physical cursor must not sit on the status line.
      final textPrompt = send(
        model,
        OpenPromptMsg(
          TextPromptSpec(question: 'Enter value:'),
          Completer<TuiPromptAnswer?>(),
        ),
      );
      final textView = textPrompt.view();
      expect(textView.cursor, isNull);

      // Picker prompt — no text input at all, cursor must stay hidden too.
      final pickerPrompt = send(
        model,
        OpenPromptMsg(
          const AskPromptSpec(
            header: 'Ask',
            question: 'Pick one:',
            index: 0,
            total: 1,
            options: [
              AskOption(label: 'a'),
              AskOption(label: 'b'),
            ],
          ),
          Completer<TuiPromptAnswer?>(),
        ),
      );
      final pickerView = pickerPrompt.view();
      expect(pickerView.cursor, isNull);
    });

    test('generic picker hides the cursor; slash menu keeps it', () {
      FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

      final model = FaTuiModel(callbacks: callbacks(), isExited: () => false);

      // Generic selection-only picker (approval/settings/wizard steps):
      // typing goes nowhere, so the physical cursor must not sit stranded
      // in the input zone.
      final picker = send(
        model,
        OpenPickerMsg('approval', 'Approval mode', [
          const MenuItem(key: 'yolo', label: 'yolo'),
        ]),
      );
      final pickerView = picker.view();
      expect(pickerView.cursor, isNull);

      // Slash menu: typing edits the filter, so the cursor stays visible.
      final slashMenu = send(
        model,
        KeyPressMsg(const TeaKey(code: KeyCode.rune, text: '/')),
      );
      expect(slashMenu.menuOpen, isTrue);
      expect(slashMenu.view().cursor, isNotNull);
    });
  });

  group('terminal input sanitization helpers', () {
    test('sttyDeviceFlag is -f on macOS and -F elsewhere', () {
      expect(FaTuiController.sttyDeviceFlag(), Platform.isMacOS ? '-f' : '-F');
    });

    test('sttySanitizeInput returns trimmed saved termios', () async {
      final calls = <List<String>>[];
      Future<ProcessResult> runner(List<String> args) async {
        calls.add(args);
        if (args.last == '-g') {
          return ProcessResult(0, 0, 'saved-string\n', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final result = await FaTuiController.sttySanitizeInput(
        '-F',
        runner: runner,
      );

      expect(result, 'saved-string');
      expect(calls, hasLength(2));
      expect(calls.first, ['-F', '/dev/tty', '-g']);
      expect(calls.last, [
        '-F',
        '/dev/tty',
        '-ixon',
        '-ixoff',
        '-icrnl',
        'discard',
        '^-',
        // Belt-and-braces IXANY clear (issue #735): any-key resume is the
        // tell-tale of a mid-session IXON regression.
        '-ixany',
      ]);
    });

    test('sttySanitizeInput returns null when saving fails', () async {
      Future<ProcessResult> runner(List<String> args) async {
        return ProcessResult(0, 1, '', 'stty error');
      }

      final result = await FaTuiController.sttySanitizeInput(
        '-F',
        runner: runner,
      );
      expect(result, isNull);
    });

    test('sttySanitizeInput returns null when clearing fails', () async {
      Future<ProcessResult> runner(List<String> args) async {
        if (args.last == '-g') {
          return ProcessResult(0, 0, 'saved', '');
        }
        return ProcessResult(0, 1, '', 'stty error');
      }

      final result = await FaTuiController.sttySanitizeInput(
        '-F',
        runner: runner,
      );
      expect(result, isNull);
    });

    test('sttySanitizeInput returns null on ProcessException', () async {
      Future<ProcessResult> runner(List<String> args) async {
        throw ProcessException('stty', <String>[], 'not found');
      }

      final result = await FaTuiController.sttySanitizeInput(
        '-F',
        runner: runner,
      );
      expect(result, isNull);
    });
  });

  group('scheduled follow-ups indicator (issue #115)', () {
    FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

    FaTuiModel withScheduled(FaTuiModel m, int count, int? nextDueMs) =>
        send(m, ScheduledStatusMsg(count, nextDueMs));

    test('pending follow-ups render on top of the Working row while busy', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      final due = DateTime.now().millisecondsSinceEpoch + 25 * 60 * 1000 + 5000;
      model = withScheduled(model, 2, due);
      model = send(model, const BusyMsg(true, source: 'run'));
      final frame = model.view().content;
      expect(frame, contains('⏰ 2 scheduled'));
      expect(frame, contains('next in 25m'));
      expect(
        frame.indexOf('⏰ 2 scheduled'),
        lessThan(frame.indexOf('Working…')),
        reason: 'the indicator sits ON TOP of the working row',
      );
    });

    test('the indicator stays visible while idle', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = withScheduled(
        model,
        1,
        DateTime.now().millisecondsSinceEpoch + 60000,
      );
      expect(model.busy, isFalse);
      expect(model.view().content, contains('⏰ 1 scheduled'));
    });

    test('a zero count clears the indicator', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = withScheduled(
        model,
        1,
        DateTime.now().millisecondsSinceEpoch + 60000,
      );
      expect(model.view().content, contains('⏰ 1 scheduled'));
      model = withScheduled(model, 0, null);
      expect(model.view().content, isNot(contains('⏰')));
    });

    test('an already-due record reads "due now", never a negative delay', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = withScheduled(
        model,
        1,
        DateTime.now().millisecondsSinceEpoch - 5000,
      );
      expect(model.view().content, contains('due now'));
    });
  });

  group('scheduled countdown tick (issue #213)', () {
    FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

    // A model whose clock the test drives by hand: advancing [currentMs]
    // is the fake-clock tick the real wall clock would provide.
    FaTuiModel fakeClockModel(DateTime Function() now) =>
        FaTuiModel(callbacks: callbacks(), isExited: () => false, now: now);

    test(
      'UT-tick: the idle countdown flips 14m -> 13m at the minute boundary',
      () {
        var currentMs = 10000 * 600; // minute-aligned fake epoch
        DateTime fakeNow() => DateTime.fromMillisecondsSinceEpoch(currentMs);
        var model = fakeClockModel(fakeNow);
        final due = currentMs + 14 * 60 * 1000 + 30000; // 14.5m out -> 14m
        final armed = model.update(ScheduledStatusMsg(1, due));
        model = armed.$1 as FaTuiModel;
        expect(model.busy, isFalse);
        expect(model.view().content, contains('⏰ 1 scheduled · next in 14m'));
        expect(
          armed.$2,
          isNotNull,
          reason: 'a minute-boundary tick must be armed while scheduled',
        );
        // No inbound messages; the minute boundary passes and the tick
        // fires — the re-render must recompute the ETA from the clock.
        currentMs += 60000;
        final ticked = model.update(const ScheduledTickMsg());
        model = ticked.$1 as FaTuiModel;
        expect(model.view().content, contains('next in 13m'));
        expect(
          ticked.$2,
          isNotNull,
          reason: 'the tick re-arms while still scheduled',
        );
      },
    );

    test('UT-no-timer: idle-and-unscheduled arms no tick and a stray tick '
        'never re-arms', () {
      var currentMs = 10000 * 600;
      DateTime fakeNow() => DateTime.fromMillisecondsSinceEpoch(currentMs);
      var model = fakeClockModel(fakeNow);
      final cleared = model.update(const ScheduledStatusMsg(0, null));
      expect(cleared.$2, isNull, reason: 'count 0 arms no countdown tick');
      model = cleared.$1 as FaTuiModel;
      final stray = model.update(const ScheduledTickMsg());
      expect(
        stray.$2,
        isNull,
        reason: 'a tick with nothing scheduled no-ops and disarms',
      );
    });

    test('UT-due: crossing the due time while idle flips the row to '
        '"due now" on the next tick', () {
      var currentMs = 10000 * 600;
      DateTime fakeNow() => DateTime.fromMillisecondsSinceEpoch(currentMs);
      var model = fakeClockModel(fakeNow);
      model = send(model, ScheduledStatusMsg(1, currentMs + 30000));
      expect(model.view().content, contains('next in 30s'));
      currentMs += 60000; // crossed the due time
      model = send(model, const ScheduledTickMsg());
      expect(model.view().content, contains('due now'));
    });

    test('UT-busy-parity: repeated status pushes never stack a second tick, '
        'and a fired tick disarms once the count drops to 0', () {
      var currentMs = 10000 * 600;
      DateTime fakeNow() => DateTime.fromMillisecondsSinceEpoch(currentMs);
      var model = fakeClockModel(fakeNow);
      final first = model.update(ScheduledStatusMsg(1, currentMs + 90000));
      expect(first.$2, isNotNull);
      model = first.$1 as FaTuiModel;
      // A nearer record appears (E2): the pending boundary tick already
      // covers it — boundaries are wall-clock aligned, so no re-arm.
      final second = model.update(ScheduledStatusMsg(2, currentMs + 45000));
      expect(second.$2, isNull, reason: 'one pending countdown timer max');
      model = second.$1 as FaTuiModel;
      // E1: the record fires/cancels; the outstanding tick fires once and
      // the chain stops.
      model = send(model, const ScheduledStatusMsg(0, null));
      final deadTick = model.update(const ScheduledTickMsg());
      expect(deadTick.$2, isNull);
    });
  });

  group('readline editing keys (issue #275)', () {
    FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;
    FaTuiModel typed(FaTuiModel m, String text) {
      for (final ch in text.split('')) {
        m = send(m, KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)));
      }
      return m;
    }

    KeyPressMsg ctrl(String ch) => KeyPressMsg(
      TeaKey(code: KeyCode.rune, text: ch, modifiers: {KeyMod.ctrl}),
    );

    test('ctrl+k kills to line end; at the cursor end it is a no-op', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'hello world');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.left)));
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.left)));
      model = send(model, ctrl('k'));
      expect(model.inputText, 'hello wor');
      // Cursor already at the end: unclaimed guard path.
      model = send(model, ctrl('k'));
      expect(model.inputText, 'hello wor');
    });

    test('ctrl+y yanks the last kill; consecutive yanks walk the ring', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'alpha beta');
      model = send(model, ctrl('w')); // kills 'beta'
      expect(model.inputText, 'alpha ');
      model = send(model, ctrl('y'));
      expect(model.inputText, 'alpha beta');
      // A second ctrl+y rotates to the OLDER kill entry; with a single
      // entry the ring wraps onto the same text.
      model = send(model, ctrl('y'));
      expect(model.inputText, contains('beta'));
      // No kill ever made: the guard keeps the input untouched.
      var fresh = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      fresh = typed(fresh, 'plain');
      fresh = send(fresh, ctrl('y'));
      expect(fresh.inputText, 'plain');
    });

    test('ctrl+t transposes at the cursor; empty input is a no-op', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'ab');
      model = send(model, ctrl('t'));
      expect(model.inputText, 'ba');
      var empty = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      empty = send(empty, ctrl('t'));
      expect(empty.inputText, '');
    });

    test('ctrl+z undoes the last edit group', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'kept');
      model = send(
        model,
        ctrl('w'),
      ); // no word before cursor 0? 'kept' is a word
      model = send(model, ctrl('z'));
      expect(model.inputText, contains('kept'));
      // Nothing to undo on a fresh composer.
      var fresh = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      fresh = send(fresh, ctrl('z'));
      expect(fresh.inputText, '');
    });

    test('a ! line completes the trailing shell word from workspace paths', () {
      var model = FaTuiModel(
        callbacks: callbacks(pathCandidates: (_) => ['build/notes.md']),
        isExited: () => false,
      );
      model = typed(model, '!cat not');
      expect(model.menuOpen, isTrue);
      // The token starts after '!cat ' (position 5).
      expect(model.menuTokenStart, 5);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.tab)));
      expect(model.inputText, '!cat build/notes.md ');
    });
  });

  group('composer overlay helpers', () {
    test('groupOf classifies skill keys apart from commands', () {
      expect(
        groupOf(const MenuItem(key: '/skill:goal ', label: '/goal')),
        'skills',
      );
      expect(groupOf(const MenuItem(key: '/exit', label: '/exit')), 'commands');
    });
  });

  group('agents hub overlay (issue #277)', () {
    FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;
    KeyPressMsg ctrl(String ch) => KeyPressMsg(
      TeaKey(code: KeyCode.rune, text: ch, modifiers: {KeyMod.ctrl}),
    );

    FaTuiCallbacks hubCallbacks({
      Future<void> Function(String action, String? key)? onAction,
      void Function()? onInterrupt,
    }) {
      return FaTuiCallbacks(
        onSubmit: (_, {images = const []}) async {},
        onInterrupt: onInterrupt,
        onModelSelected: (_) async {},
        buildSlashMenu: (_) => const [],
        buildModelMenu: (_, _) => const [],
        statusLine: () => '/work · 0tok · turn 0 · test-model',
        prompt: 'fa> ',
        onHubAction: onAction,
      );
    }

    FaHubState tree() => FaHubState.tree(
      footer: '',
      rows: const [
        HubLine('main', key: 'main'),
        HubLine('  a1', key: 'a1'),
      ],
    );

    test('hub keys drive the tree selection', () {
      var model = FaTuiModel(
        callbacks: hubCallbacks(),
        isExited: () => false,
        hub: tree(),
      );
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      expect(model.hub!.selectedKey, 'a1');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.hub!.selectedKey, 'main');
    });

    test(
      'tree aliases: hjkl move/collapse, q closes, unknown is a no-op',
      () async {
        final actions = <String, String?>{};
        var model = FaTuiModel(
          callbacks: hubCallbacks(
            onAction: (action, key) async => actions[action] = key,
          ),
          isExited: () => false,
          hub: tree(),
        );
        // vi aliases drive the same moves as the arrows.
        model = send(
          model,
          KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'j')),
        );
        expect(model.hub!.selectedKey, 'a1');
        model = send(
          model,
          KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'k')),
        );
        expect(model.hub!.selectedKey, 'main');

        // h/l collapse and re-expand the selected row's branch.
        model = send(
          model,
          KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'l')),
        );
        expect(model.hub!.visibleRows.length, 1, reason: 'a1 collapses away');
        model = send(
          model,
          KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'h')),
        );
        expect(model.hub!.visibleRows.length, 2, reason: 'a1 is visible again');

        // A rune with no binding changes nothing.
        model = send(
          model,
          KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'x')),
        );
        expect(model.hub!.selectedKey, 'main');

        // q closes like esc.
        final (next, cmd) = model.update(
          KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'q')),
        );
        model = next as FaTuiModel;
        expect(model.hub, isNull);
        await cmd?.call();
        expect(actions['close'], 'main');
      },
    );

    test(
      'enter keeps the overlay open and calls back with the selection',
      () async {
        final actions = <String, String?>{};
        var model = FaTuiModel(
          callbacks: hubCallbacks(
            onAction: (action, key) async => actions[action] = key,
          ),
          isExited: () => false,
          hub: tree(),
        );
        final (next, cmd) = model.update(
          KeyPressMsg(const TeaKey(code: KeyCode.enter)),
        );
        model = next as FaTuiModel;
        expect(model.hub, isNotNull);
        await cmd?.call();
        expect(actions['enter'], 'main');
      },
    );

    test('esc closes the overlay and reports close', () async {
      final actions = <String>[];
      var model = FaTuiModel(
        callbacks: hubCallbacks(
          onAction: (action, _) async => actions.add(action),
        ),
        isExited: () => false,
        hub: tree(),
      );
      final (next, cmd) = model.update(
        KeyPressMsg(const TeaKey(code: KeyCode.escape)),
      );
      model = next as FaTuiModel;
      expect(model.hub, isNull);
      await cmd?.call();
      expect(actions, ['close']);
    });

    test('transcript esc goes back with the overlay still open', () async {
      final actions = <String>[];
      var model = FaTuiModel(
        callbacks: hubCallbacks(
          onAction: (action, _) async => actions.add(action),
        ),
        isExited: () => false,
        hub: FaHubState.transcript(
          agentId: 'a1',
          lines: const ['x'],
          running: false,
        ),
      );
      final (next, cmd) = model.update(
        KeyPressMsg(const TeaKey(code: KeyCode.escape)),
      );
      model = next as FaTuiModel;
      expect(model.hub, isNotNull);
      await cmd?.call();
      expect(actions, ['back']);
    });

    test('ctrl+c aborts and quits even with the overlay open', () {
      var interrupted = false;
      var model = FaTuiModel(
        callbacks: hubCallbacks(onInterrupt: () => interrupted = true),
        isExited: () => false,
        hub: tree(),
      );
      final (next, cmd) = model.update(ctrl('c'));
      expect(interrupted, isTrue);
      expect(identical(next, model), isTrue, reason: 'state untouched');
      expect(cmd, isNotNull, reason: 'the quit command');
    });

    test('a host re-push carries the selection', () {
      var model = FaTuiModel(
        callbacks: hubCallbacks(),
        isExited: () => false,
        hub: tree(),
      );
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      model = send(
        model,
        HubStateMsg(
          FaHubState.tree(
            footer: '',
            rows: const [
              HubLine('main', key: 'main'),
              HubLine('  a1', key: 'a1'),
              HubLine('  b2', key: 'b2'),
            ],
          ),
        ),
      );
      expect(model.hub!.selectedKey, 'a1');
    });

    test('view renders the hub frame while open', () {
      final model = FaTuiModel(
        callbacks: hubCallbacks(),
        isExited: () => false,
        hub: tree(),
      );
      expect(model.view().content, contains('agents hub'));
    });
  });

  // The OSC 11 background-probe tier tests live in
  // fa_tui_emitters_test.dart (2800-line static gate).
}
