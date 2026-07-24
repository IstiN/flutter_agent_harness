import 'dart:async';

import 'package:dart_tui/dart_tui.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

void main() {
  FaTuiCallbacks callbacks({
    List<String> submitted = const [],
    List<String> selectedModels = const [],
    void Function()? onInterrupt,
    Map<String, String>? picked,
    List<List<String>>? steered,
  }) {
    return FaTuiCallbacks(
      onSubmit: (line) async => submitted.add(line),
      onInterrupt: onInterrupt,
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
                  item.description.toLowerCase().contains(lower),
            )
            .toList();
      },
      buildModelMenu: (filter) => [
        if ('model-a'.contains(filter))
          const MenuItem(key: 'model-a', label: 'model-a'),
        if ('model-b'.contains(filter))
          const MenuItem(key: 'model-b', label: 'model-b'),
      ],
      statusLine: () => '/work · 0tok · turn 0 · test-model',
      prompt: 'fa> ',
    );
  }

  test('initial view shows framed input zone and status', () {
    final model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
    final view = model.view();
    // The input zone is framed between two rules; no prompt prefix.
    expect(view.content, contains('─' * 80));
    expect(view.content, contains('/work · 0tok · turn 0 · test-model'));
  });

  test('typing characters appends to input', () {
    var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
    model =
        model
                .update(
                  KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'a')),
                )
                .$1
            as FaTuiModel;
    model =
        model
                .update(
                  KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'b')),
                )
                .$1
            as FaTuiModel;
    expect(model.inputText, 'ab');
    expect(model.cursor, 2);
  });

  test('typing / opens slash menu', () {
    var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
    model =
        model
                .update(
                  KeyPressMsg(const TeaKey(code: KeyCode.rune, text: '/')),
                )
                .$1
            as FaTuiModel;
    expect(model.menuOpen, isTrue);
    expect(model.menuModelMode, isFalse);
    expect(model.menuItems.any((i) => i.key == '/help'), isTrue);
  });

  test('typing /models opens model picker', () {
    var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
    for (final ch in '/models'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
              as FaTuiModel;
    }
    expect(model.menuOpen, isTrue);
    expect(model.menuModelMode, isTrue);
    expect(model.menuItems.length, 2);
  });

  test('typing /models a filters the picker', () {
    var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
    for (final ch in '/models a'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
              as FaTuiModel;
    }
    expect(model.modelFilter, 'a');
    expect(model.menuItems.length, 1);
    expect(model.menuItems.single.key, 'model-a');
  });

  test('enter submits the input line', () async {
    final submitted = <String>[];
    var model = FaTuiModel(
      callbacks: callbacks(submitted: submitted),
      isExited: () => false,
    );
    for (final ch in 'hello'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
              as FaTuiModel;
    }
    final result = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    model = result.$1 as FaTuiModel;
    await result.$2?.call();
    expect(submitted, ['hello']);
    expect(model.inputText, '');
  });

  test('enter in model picker selects the model', () async {
    final selected = <String>[];
    var model = FaTuiModel(
      callbacks: callbacks(selectedModels: selected),
      isExited: () => false,
    );
    for (final ch in '/models'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
              as FaTuiModel;
    }
    model =
        model.update(KeyPressMsg(const TeaKey(code: KeyCode.down))).$1
            as FaTuiModel;
    final result = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    await result.$2?.call();
    expect(selected, ['model-b']);
  });

  test('output message appends lines above the input zone', () {
    var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
    model = model.update(OutputMsg('tool result\n')).$1 as FaTuiModel;
    model = model.update(OutputMsg('another line')).$1 as FaTuiModel;
    final view = model.view();
    expect(view.content, contains('tool result'));
    expect(view.content, contains('another line'));
    expect(view.content, contains('─' * 80));
  });

  test('isExited causes quit', () {
    var model = FaTuiModel(callbacks: callbacks(), isExited: () => true);
    final cmd = model
        .update(KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'a')))
        .$2;
    expect(cmd, isNotNull);
  });

  test('submit echoes the user line framed between rules', () async {
    final submitted = <String>[];
    var model = FaTuiModel(
      callbacks: callbacks(submitted: submitted),
      isExited: () => false,
    );
    for (final ch in 'hello'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
              as FaTuiModel;
    }
    final result = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    model = result.$1 as FaTuiModel;
    await result.$2?.call();
    expect(submitted, ['hello']);
    // The echo is the input with a background marker under a horizontal
    // rule (no rule below), stored UNPADDED — the view-time formatter pads
    // it to the current width (resize-safe).
    final lines = model.outputLines;
    final hello = lines.indexWhere((l) => l.contains('hello'));
    expect(hello, greaterThan(0));
    expect(lines[hello], startsWith('\x1b[48'));
    final padded = AnsiMarkdown(
      width: model.termWidth,
    ).formatLine(lines[hello]);
    expect(
      padded.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '').length,
      model.termWidth,
    );
    expect(
      lines[hello - 1].replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), ''),
      '─' * model.termWidth,
    );
    // Two trailing blanks: one consumed by the answer's first line, one
    // left visible as the empty line after the user message.
    expect(lines[hello + 1], '');
    expect(lines[hello + 2], '');
    expect(lines.join('\n'), isNot(contains('fa> hello')));
  });

  test(
    'spinner ticks cycle the Working… frame while the cursor stays hidden',
    () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = model.update(BusyMsg(true)).$1 as FaTuiModel;
      final spinnerRows = <String>{};
      for (var i = 0; i < 3; i++) {
        spinnerRows.add(
          model
              .view()
              .content
              .split('\n')
              .firstWhere((line) => line.contains('Working')),
        );
        model = model.update(SpinnerTickMsg()).$1 as FaTuiModel;
      }
      // The spinner animates; the trailing cursor line is the hide escape —
      // stable across ticks (the old re-homing suffix is gone on purpose).
      expect(spinnerRows.length, greaterThan(1));
      expect(model.view().content.split('\n').last, contains('\x1b[?25l'));
    },
  );

  test('escape aborts the run via onInterrupt without quitting', () {
    var interrupted = 0;
    var model = FaTuiModel(
      callbacks: callbacks(onInterrupt: () => interrupted++),
      isExited: () => false,
    );
    final result = model.update(
      KeyPressMsg(const TeaKey(code: KeyCode.escape)),
    );
    model = result.$1 as FaTuiModel;
    expect(interrupted, 1);
    expect(result.$2, isNull); // no quit command, unlike Ctrl+C
  });

  test('busy message shows the Working indicator above the input zone', () {
    var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
    expect(model.view().content, isNot(contains('Working…')));
    final result = model.update(BusyMsg(true));
    model = result.$1 as FaTuiModel;
    expect(model.busy, isTrue);
    expect(result.$2, isNotNull); // spinner loop kicked
    final frame = model.view().content;
    expect(frame, contains('Working…'));
    // The indicator renders above the framed input rules.
    expect(frame.indexOf('Working…'), lessThan(frame.lastIndexOf('─' * 80)));
    model = model.update(BusyMsg(false)).$1 as FaTuiModel;
    expect(model.busy, isFalse);
    expect(model.view().content, isNot(contains('Working…')));
  });

  test(
    'generic picker opens with a title and resolves via onPickerSelected',
    () async {
      final picked = <String, String>{};
      var model = FaTuiModel(
        callbacks: callbacks(picked: picked),
        isExited: () => false,
      );
      model =
          model
                  .update(
                    OpenPickerMsg('sessions', 'Sessions', const [
                      MenuItem(key: '0', label: '1) work'),
                      MenuItem(key: '1', label: '2) side-project'),
                    ]),
                  )
                  .$1
              as FaTuiModel;
      expect(model.menuOpen, isTrue);
      expect(model.menuModelMode, isTrue);
      expect(model.view().content, contains('[Sessions]'));

      // Typing does NOT filter a generic picker (static items).
      model =
          model
                  .update(
                    KeyPressMsg(const TeaKey(code: KeyCode.rune, text: 'w')),
                  )
                  .$1
              as FaTuiModel;
      expect(model.menuItems, hasLength(2));

      // Down + enter selects the second item; the picker closes.
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.down))).$1
              as FaTuiModel;
      final result = model.update(
        KeyPressMsg(const TeaKey(code: KeyCode.enter)),
      );
      await result.$2?.call();
      expect(picked, {'sessions': '1'});
      expect((result.$1 as FaTuiModel).menuOpen, isFalse);
    },
  );

  test('accepting a picker command from the slash menu submits it', () async {
    final submitted = <String>[];
    var model = FaTuiModel(
      callbacks: callbacks(submitted: submitted),
      isExited: () => false,
    );
    for (final ch in '/sessions'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
              as FaTuiModel;
    }
    // The slash menu shows /sessions; accepting it submits immediately
    // instead of filling the input.
    expect(model.menuOpen, isTrue);
    final result = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    model = result.$1 as FaTuiModel;
    await result.$2?.call();
    expect(submitted, ['/sessions']);
    expect(model.inputText, '');
  });

  test('sticky user echo pins to the top while streaming past it', () async {
    final submitted = <String>[];
    var model = FaTuiModel(
      callbacks: callbacks(submitted: submitted),
      isExited: () => false,
      termHeight: 12, // small viewport so content overflows fast
    );
    for (final ch in 'hello'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
              as FaTuiModel;
    }
    final submitted_ = model.update(
      KeyPressMsg(const TeaKey(code: KeyCode.enter)),
    );
    model = submitted_.$1 as FaTuiModel;
    await submitted_.$2?.call();
    expect(model.stickyLines, isNotEmpty);
    expect(model.stickyIndex, 0);

    model = model.update(BusyMsg(true)).$1 as FaTuiModel;
    for (var i = 0; i < 20; i++) {
      model =
          model.update(OutputMsg('line $i', newline: true)).$1 as FaTuiModel;
    }
    final stripped = model.view().content.replaceAll(
      RegExp(r'\x1b\[[0-9;]*m'),
      '',
    );
    final rows = stripped.split('\n');
    // The pinned echo sits at the top: rule, then the first input line.
    expect(rows[0], '─' * 80);
    expect(rows[1], contains('hello'));

    // Going idle unpins the echo.
    model = model.update(BusyMsg(false)).$1 as FaTuiModel;
    expect(model.stickyLines, isEmpty);
    expect(model.stickyIndex, -1);
  });

  test('chrome rows never exceed the terminal width', () {
    // A status line or menu item wider than the terminal must be truncated,
    // not soft-wrapped (a wrap desyncs the renderer's row math).
    var model = FaTuiModel(
      callbacks: FaTuiCallbacks(
        onSubmit: (_) async {},
        onModelSelected: (_) async {},
        buildSlashMenu: (_) => const [
          MenuItem(
            key: '/very-long-command',
            label: '/very-long-command',
            description: 'with an extremely long description that will not fit',
          ),
        ],
        buildModelMenu: (_) => const [],
        statusLine: () =>
            '/a/very/long/path/that/goes/on/and/on/and/on/and/on · ctx 99% '
            '(999k/1M) · 123456tok · \$9.9999 · turn 99 · a/very-long-model-id',
        prompt: '',
        opensPicker: null,
        onPickerSelected: null,
      ),
      isExited: () => false,
      termWidth: 60,
    );
    model =
        model
                .update(
                  KeyPressMsg(const TeaKey(code: KeyCode.rune, text: '/')),
                )
                .$1
            as FaTuiModel; // opens the menu
    final ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');
    for (final line in model.view().content.split('\n')) {
      expect(
        line.replaceAll(ansi, '').length,
        lessThanOrEqualTo(60),
        reason: 'row exceeds width: $line',
      );
    }
  });

  group('message queue (busy)', () {
    FaTuiModel busyModel({
      List<String> submitted = const [],
      List<List<String>>? steered,
    }) {
      final model = FaTuiModel(
        callbacks: callbacks(submitted: submitted, steered: steered),
        isExited: () => false,
      );
      return model.update(BusyMsg(true)).$1 as FaTuiModel;
    }

    FaTuiModel type(FaTuiModel model, String text) {
      var m = model;
      for (final ch in text.split('')) {
        m =
            m.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
                as FaTuiModel;
      }
      return m;
    }

    test('enter enqueues plain messages without submitting', () {
      final submitted = <String>[];
      var model = busyModel(submitted: submitted);
      model = type(model, 'first');
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter))).$1
              as FaTuiModel;
      expect(model.queue, ['first']);
      expect(model.inputText, '');
      expect(submitted, isEmpty);
      model = type(model, 'second');
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter))).$1
              as FaTuiModel;
      expect(model.queue, ['first', 'second']);
      // The view shows the queued lines and the hint.
      final frame = model.view().content;
      expect(frame, contains('❯ first'));
      expect(frame, contains('❯ second'));
      expect(frame, contains('↑ to edit · ctrl-s to send immediately'));
    });

    test('slash commands submit immediately even while busy', () async {
      final submitted = <String>[];
      var model = busyModel(submitted: submitted);
      model = type(model, '/help');
      // The slash menu is open: first enter accepts the command into the
      // input, second enter submits it (commands never queue).
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter))).$1
              as FaTuiModel;
      final result = model.update(
        KeyPressMsg(const TeaKey(code: KeyCode.enter)),
      );
      model = result.$1 as FaTuiModel;
      await result.$2?.call();
      expect(model.queue, isEmpty);
      expect(submitted, ['/help']);
    });

    test('up pops the last queued message into the input', () {
      var model = busyModel();
      model = type(model, 'one');
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter))).$1
              as FaTuiModel;
      model = type(model, 'two');
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter))).$1
              as FaTuiModel;
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.up))).$1
              as FaTuiModel;
      expect(model.inputText, 'two');
      expect(model.queue, ['one']);
      // A second up does NOT pop: the buffer is no longer empty (kimi-cli
      // pops only into an empty editor).
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.up))).$1
              as FaTuiModel;
      expect(model.inputText, 'two');
      expect(model.queue, ['one']);
    });

    test('ctrl+s steers the input plus the whole queue', () async {
      final steered = <List<String>>[];
      var model = busyModel(steered: steered);
      model = type(model, 'q1');
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter))).$1
              as FaTuiModel;
      model = type(model, 'typed');
      final result = model.update(
        KeyPressMsg(
          const TeaKey(code: KeyCode.rune, text: 's', modifiers: {KeyMod.ctrl}),
        ),
      );
      model = result.$1 as FaTuiModel;
      await result.$2?.call();
      expect(steered, [
        ['typed', 'q1'],
      ]);
      expect(model.queue, isEmpty);
      expect(model.inputText, '');
      // The steered messages were echoed into the history.
      expect(
        model.outputLines.join('\n'),
        allOf(contains('typed'), contains('q1')),
      );
    });

    test('drain echoes queued messages and hands them out', () async {
      var model = busyModel();
      model = type(model, 'later');
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter))).$1
              as FaTuiModel;
      // The run settles; the host drains.
      model = model.update(BusyMsg(false)).$1 as FaTuiModel;
      final completer = Completer<List<String>>();
      model = model.update(DrainQueueMsg(completer)).$1 as FaTuiModel;
      expect(await completer.future, ['later']);
      expect(model.queue, isEmpty);
      expect(model.outputLines.join('\n'), contains('later'));
    });
  });

  group('follow latch (auto-scroll)', () {
    FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

    FaTuiModel filledModel({int lines = 30}) {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termHeight: 12, // small viewport so content overflows fast
      );
      for (var i = 0; i < lines; i++) {
        model = send(model, OutputMsg('line $i', newline: true));
      }
      return model;
    }

    FaTuiCallbacks cancelCallbacks(List<String> cancelled) {
      return FaTuiCallbacks(
        onSubmit: (_) async {},
        onModelSelected: (_) async {},
        buildSlashMenu: (_) => const [],
        buildModelMenu: (_) => const [],
        statusLine: () => '',
        prompt: '',
        onPickerCancelled: cancelled.add,
      );
    }

    test('opening a picker does not break auto-follow', () {
      var model = filledModel();
      final bottom = model.scrollOffset;
      expect(bottom, greaterThan(0));
      expect(model.followTail, isTrue);

      model = send(
        model,
        OpenPickerMsg('provider', 'Select provider', const [
          MenuItem(key: 'a', label: 'a'),
        ]),
      );
      model = send(model, OutputMsg('question line', newline: true));
      expect(model.followTail, isTrue);
      expect(
        model.scrollOffset,
        greaterThan(bottom),
        reason: 'a transient viewport shrink must not detach follow',
      );

      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.escape)));
      model = send(model, OutputMsg('after close', newline: true));
      expect(model.view().content, contains('after close'));
      expect(model.followTail, isTrue);
    });

    test('scrolling up detaches, scrolling back to the bottom re-attaches', () {
      var model = filledModel();
      final bottom = model.scrollOffset;

      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.scrollOffset, bottom - 1);
      expect(model.followTail, isFalse);

      model = send(model, OutputMsg('new line while detached', newline: true));
      expect(model.scrollOffset, bottom - 1);

      // The detached output moved the bottom one row further; two downs
      // land on the exact new bottom and re-attach.
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      expect(model.followTail, isFalse);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      expect(model.followTail, isTrue);

      model = send(model, OutputMsg('tail line', newline: true));
      expect(model.view().content, contains('tail line'));
    });

    test('esc on a wizard picker reports onPickerCancelled', () {
      final cancelled = <String>[];
      var model = FaTuiModel(
        callbacks: cancelCallbacks(cancelled),
        isExited: () => false,
      );
      model = send(
        model,
        OpenPickerMsg('wizard:type', 'API type', const [
          MenuItem(key: 'openai', label: 'openai-like'),
        ]),
      );
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.escape)));
      expect(cancelled, ['wizard:type']);
      expect(model.menuOpen, isFalse);
    });

    test('esc on the models picker does not report a cancel', () {
      final cancelled = <String>[];
      var model = FaTuiModel(
        callbacks: cancelCallbacks(cancelled),
        isExited: () => false,
      );
      model = send(
        model,
        OpenPickerMsg('models', '', const [MenuItem(key: 'm1', label: 'm1')]),
      );
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.escape)));
      expect(cancelled, isEmpty);
    });

    test(
      'a long single-line message marks the sticky echo with an ellipsis',
      () async {
        var model = FaTuiModel(
          callbacks: cancelCallbacks(const []),
          isExited: () => false,
          termWidth: 60,
        );
        for (final ch in ('x' * 150).split('')) {
          model = send(
            model,
            KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)),
          );
        }
        final result = model.update(
          KeyPressMsg(const TeaKey(code: KeyCode.enter)),
        );
        model = result.$1 as FaTuiModel;
        await result.$2?.call();

        final sticky = model.stickyLines.join('\n');
        expect(sticky, contains('…'));
        final strippedSticky = sticky.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');
        for (final row in strippedSticky.split('\n')) {
          expect(row.length, lessThanOrEqualTo(60));
        }
        // The history keeps the full message, wrapped across rows.
        final history = model.view().content.replaceAll(
          RegExp(r'\x1b\[[0-9;]*m'),
          '',
        );
        final joined = history
            .split('\n')
            .where((row) => row.contains('x'))
            .join();
        expect(joined, contains('x' * 150));
      },
    );

    test('the scroll indicator lights only when the user scrolled away', () {
      var model = filledModel();
      // Busy shrinks the viewport by one row; following must not light it.
      model = send(model, BusyMsg(true));
      model = send(model, OutputMsg('streamed', newline: true));
      expect(model.view().content, isNot(contains('%')));

      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.view().content, contains('%'));
    });

    test('the physical cursor hides while busy and homes when idle', () {
      var model = filledModel();
      final position = RegExp(r'\x1b\[\d+;\d+H$');
      expect(
        model.view().content,
        contains('\x1b[?25h'),
        reason: 'idle: cursor shown',
      );

      model = send(model, BusyMsg(true));
      final busyContent = model.view().content;
      expect(busyContent, contains('\x1b[?25l'));
      expect(busyContent, isNot(contains('\x1b[?25h')));

      model = send(model, BusyMsg(false));
      final idleContent = model.view().content;
      expect(idleContent, contains('\x1b[?25h'));
      expect(position.hasMatch(idleContent), isTrue);
    });

    test(
      'a submit after scrolling up re-attaches follow and pins the echo',
      () async {
        var model = FaTuiModel(
          callbacks: callbacks(submitted: <String>[]),
          isExited: () => false,
          termHeight: 12,
        );
        for (var i = 0; i < 30; i++) {
          model = send(model, OutputMsg('line $i', newline: true));
        }
        // Detach the latch by scrolling up.
        model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
        expect(model.followTail, isFalse);

        // Submit a new message: follow re-attaches and the stream follows.
        for (final ch in 'hello'.split('')) {
          model = send(
            model,
            KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)),
          );
        }
        final result = model.update(
          KeyPressMsg(const TeaKey(code: KeyCode.enter)),
        );
        model = result.$1 as FaTuiModel;
        await result.$2?.call();
        expect(model.followTail, isTrue);

        model = send(model, BusyMsg(true));
        for (var i = 0; i < 20; i++) {
          model = send(model, OutputMsg('line $i', newline: true));
        }
        // The echo scrolled fully out of the viewport: the sticky pins at top.
        final rows = model
            .view()
            .content
            .replaceAll(RegExp(r'\x1b\[[0-9;?]*[A-Za-z]'), '')
            .split('\n');
        expect(rows[1], contains('hello'));
      },
    );

    test(
      'the sticky echo stays off while the message is still visible',
      () async {
        var model = FaTuiModel(
          callbacks: callbacks(submitted: <String>[]),
          isExited: () => false,
          termHeight: 12,
        );
        for (final ch in 'hello'.split('')) {
          model = send(
            model,
            KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)),
          );
        }
        final result = model.update(
          KeyPressMsg(const TeaKey(code: KeyCode.enter)),
        );
        model = result.$1 as FaTuiModel;
        await result.$2?.call();
        model = send(model, BusyMsg(true));
        // A few streamed lines: the echo still fits inside the viewport, so
        // no pinned duplicate may render.
        for (var i = 0; i < 3; i++) {
          model = send(model, OutputMsg('line $i', newline: true));
        }
        final ansi = RegExp(r'\x1b\[[0-9;]*m');
        final visible = model.view().content.replaceAll(ansi, '');
        expect(visible, contains('hello'));
        expect('hello'.allMatches(visible), hasLength(1));

        // Push the echo above the viewport: the pinned copy appears at the
        // top (and only there — the history row has scrolled away).
        for (var i = 3; i < 20; i++) {
          model = send(model, OutputMsg('line $i', newline: true));
        }
        final pushed = model.view().content.replaceAll(ansi, '');
        final rows = pushed.split('\n');
        expect(rows[1], contains('hello'), reason: 'pinned echo at the top');
        expect('hello'.allMatches(pushed), hasLength(1));
      },
    );
  });

  group('mouse wheel scrolling', () {
    FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

    FaTuiModel filledModel({int lines = 30}) {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termHeight: 12, // small viewport so content overflows fast
      );
      for (var i = 0; i < lines; i++) {
        model = send(model, OutputMsg('line $i', newline: true));
      }
      return model;
    }

    test('wheel up scrolls the transcript up by three rows', () {
      var model = filledModel();
      final bottom = model.scrollOffset;
      expect(bottom, greaterThan(0));
      expect(model.followTail, isTrue);

      model = send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(model.scrollOffset, bottom - 3);
      expect(model.followTail, isFalse);
    });

    test('wheel down scrolls the transcript down by three rows', () {
      var model = filledModel();
      final bottom = model.scrollOffset;
      model = send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(model.scrollOffset, bottom - 3);

      model = send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelDown)),
      );
      expect(model.scrollOffset, bottom);
      expect(model.followTail, isTrue);
    });

    test('the view requests cell-motion mouse mode', () {
      final model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      expect(model.view().mouseMode, MouseMode.cellMotion);
    });
  });

  group('input kill keys', () {
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

    test('ctrl+u kills from the cursor back to the start of the line', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'hello world');
      model = send(model, ctrl('u'));
      expect(model.inputText, isEmpty);
      expect(model.cursor, 0);

      model = typed(model, 'again');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.left)));
      model = send(model, ctrl('u'));
      expect(model.inputText, 'n');
      expect(model.cursor, 0);
    });

    test('ctrl+w kills the previous word and trailing whitespace first', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'hello world  ');
      model = send(model, ctrl('w'));
      expect(model.inputText, 'hello ');
      expect(model.cursor, 6);
      model = send(model, ctrl('w'));
      expect(model.inputText, '');
      expect(model.cursor, 0);
    });
  });
}
