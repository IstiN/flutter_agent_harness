import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show Platform, ProcessException, ProcessResult;

import 'package:dart_tui/dart_tui.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:flutter_agent_harness/src/tools/ask_tool.dart';
import 'package:test/test.dart';

void main() {
  FaTuiCallbacks callbacks({
    List<String> submitted = const [],
    List<String> selectedModels = const [],
    void Function()? onInterrupt,
    Map<String, String>? picked,
    List<List<String>>? steered,
    bool Function()? isShiftPressed,
  }) {
    return FaTuiCallbacks(
      onSubmit: (line) async => submitted.add(line),
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

  test('enter on empty input submits the empty line (guided flows use '
      '"empty = keep the default")', () async {
    final submitted = <String>[];
    var model = FaTuiModel(
      callbacks: callbacks(submitted: submitted),
      isExited: () => false,
    );
    final result = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    model = result.$1 as FaTuiModel;
    await result.$2?.call();
    expect(submitted, ['']);
    expect(model.inputText, '');
    // No user-message echo for the empty submit (it would read as a glitch).
    expect(model.stickyLines, isEmpty);
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

  FaTuiModel typedInto(FaTuiModel model, String text) {
    for (final ch in text.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch))).$1
              as FaTuiModel;
    }
    return model;
  }

  test('a long single-line input soft-wraps into physical rows', () {
    var model = FaTuiModel(
      callbacks: callbacks(),
      isExited: () => false,
      termWidth: 40,
    );
    final text = 'a' * 45 + 'b' * 45; // 90 chars at width 40
    model = typedInto(model, text);

    final plain = model.view().content.replaceAll(
      RegExp(r'\x1b\[[0-9;]*[A-Za-z]'),
      '',
    );
    // The whole prompt is visible as a paragraph — no horizontal clipping:
    // 40 a's, then 5 a's + 35 b's, then the trailing 10 b's.
    expect(plain, contains('${'a' * 40}\n'));
    expect(plain, contains('${'a' * 5}${'b' * 35}\n'));
    expect(plain, contains('b' * 10));
    // The cursor homes to the END of the wrapped text: row 2, column 10.
    final cursor = model.view().cursor;
    expect(cursor, isNotNull);
    expect(cursor!.x, 10);
  });

  test('an exact-width input gives the cursor its own empty row', () {
    var model = FaTuiModel(
      callbacks: callbacks(),
      isExited: () => false,
      termWidth: 40,
    );
    model = typedInto(model, 'a' * 40);
    final cursor = model.view().cursor;
    expect(cursor, isNotNull);
    expect(cursor!.x, 0); // one row past the full-width chunk
  });

  test('hard newlines and soft wraps stack in the input zone', () {
    var model = FaTuiModel(
      callbacks: callbacks(isShiftPressed: () => true),
      isExited: () => false,
      termWidth: 40,
    );
    model = typedInto(model, 'x' * 41); // wraps to 2 rows
    // shift+enter (the host reports shift) — a hard newline, then another
    // wrapped line.
    model =
        model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter))).$1
            as FaTuiModel;
    model = typedInto(model, 'y' * 41);
    final plain = model.view().content.replaceAll(
      RegExp(r'\x1b\[[0-9;]*[A-Za-z]'),
      '',
    );
    expect(plain, contains('${'x' * 40}\n'));
    expect(plain, contains('x\n'));
    expect(plain, contains('${'y' * 40}\n'));
    expect(plain, contains('y\n'));
    // Cursor: logical line 1, col 41 → wrapped row 1 of that line, col 1.
    final cursor = model.view().cursor;
    expect(cursor!.x, 1);
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
      // The busy row carries the elapsed seconds — a wedged endpoint is
      // visible instead of looking like a frozen UI.
      expect(
        spinnerRows.every((row) => RegExp(r'Working… \d+s').hasMatch(row)),
        isTrue,
      );
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

  test('generic picker type-to-filter narrows the static items', () async {
    final picked = <String, String>{};
    var model = FaTuiModel(
      callbacks: callbacks(picked: picked),
      isExited: () => false,
    );
    model =
        model
                .update(
                  OpenPickerMsg('m', 'chat model — model', const [
                    MenuItem(key: 'gpt-4o', label: 'gpt-4o'),
                    MenuItem(key: 'claude-sonnet', label: 'claude-sonnet'),
                    MenuItem(
                      key: 'kimi-k3',
                      label: 'kimi-k3',
                      description: 'fast',
                    ),
                  ]),
                )
                .$1
            as FaTuiModel;

    // Typing filters locally (label + description, case-insensitive).
    for (final rune in 'KIMI'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: rune))).$1
              as FaTuiModel;
    }
    expect(model.modelFilter, 'KIMI');
    expect(model.menuItems.map((i) => i.key), ['kimi-k3']);
    expect(model.view().content, contains('[chat model — model: KIMI]'));

    // Backspace restores the full list; the filter echo disappears.
    for (var i = 0; i < 4; i++) {
      model =
          model.update(KeyPressMsg(const TeaKey(code: KeyCode.backspace))).$1
              as FaTuiModel;
    }
    expect(model.modelFilter, isEmpty);
    expect(model.menuItems, hasLength(3));

    // Enter on the filtered list resolves the visible item.
    for (final rune in 'sonnet'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: rune))).$1
              as FaTuiModel;
    }
    final result = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    await result.$2?.call();
    expect(picked, {'m': 'claude-sonnet'});
    final closed = result.$1 as FaTuiModel;
    expect(closed.menuOpen, isFalse);
    expect(closed.menuAllItems, isEmpty);
  });

  test('generic picker filter with no matches keeps the title row', () {
    var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
    model =
        model
                .update(
                  OpenPickerMsg('m', 'Models', const [
                    MenuItem(key: 'a', label: 'alpha'),
                  ]),
                )
                .$1
            as FaTuiModel;
    for (final rune in 'zzz'.split('')) {
      model =
          model.update(KeyPressMsg(TeaKey(code: KeyCode.rune, text: rune))).$1
              as FaTuiModel;
    }
    expect(model.menuItems, isEmpty);
    final frame = model.view().content;
    expect(frame, contains('[Models: zzz]'));
    expect(frame, contains('(no matches)'));
    // Enter on an empty filtered list is a no-op (picker stays open).
    final result = model.update(KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    expect((result.$1 as FaTuiModel).menuOpen, isTrue);
  });

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

  test('the status row is padded to the width so a shorter status '
      'overwrites the previous tail', () {
    // Switching from a long model id to a short one must not leave the old
    // tail on screen (the renderer only rewrites covered cells).
    final ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');
    FaTuiModel modelWith(String status) => FaTuiModel(
      callbacks: FaTuiCallbacks(
        onSubmit: (_) async {},
        onModelSelected: (_) async {},
        buildSlashMenu: (_) => const [],
        buildModelMenu: (_) => const [],
        statusLine: () => status,
        prompt: '',
      ),
      isExited: () => false,
      termWidth: 40,
    );
    final longRow = modelWith('cwd · very-long-model-id-here · turn 9')
        .view()
        .content
        .split('\n')
        .lastWhere((l) => l.replaceAll(ansi, '').trim().isNotEmpty);
    expect(longRow.replaceAll(ansi, '').length, 40);
    final shortRow = modelWith('cwd · k3 · turn 1')
        .view()
        .content
        .split('\n')
        .lastWhere((l) => l.replaceAll(ansi, '').trim().isNotEmpty);
    // Padded with spaces to the full width — the old tail is overwritten.
    expect(shortRow.replaceAll(ansi, '').length, 40);
    expect(shortRow.replaceAll(ansi, ''), endsWith(' '));
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
      // The steered messages were echoed into the history, with the
      // visible "what happened to my message" receipt.
      expect(
        model.outputLines.join('\n'),
        allOf(contains('typed'), contains('q1')),
      );
      expect(
        model.outputLines.join('\n'),
        contains('steered into the running turn'),
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

  group('input history (submitted messages)', () {
    FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

    FaTuiModel type(FaTuiModel model, String text) {
      var m = model;
      for (final ch in text.split('')) {
        m = send(m, KeyPressMsg(TeaKey(code: KeyCode.rune, text: ch)));
      }
      return m;
    }

    FaTuiModel submit(FaTuiModel model, String text) {
      var m = type(model, text);
      return send(m, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
    }

    test('up/down cycles submitted messages, past-newest restores empty', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = submit(model, 'first message');
      model = submit(model, 'second message');
      expect(model.inputHistory, ['first message', 'second message']);
      expect(model.inputText, '');

      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.inputText, 'second message');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.inputText, 'first message');
      // Oldest reached — another up stays.
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.inputText, 'first message');

      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      expect(model.inputText, 'second message');
      // Past the newest: back to the (empty) draft, browsing exited.
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      expect(model.inputText, '');
      expect(model.historyIndex, -1);
    });

    test('editing a recalled entry exits browsing', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = submit(model, 'recall me');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.historyIndex, 0);
      model = type(model, '!');
      expect(model.historyIndex, -1);
      expect(model.inputText, 'recall me!');
    });

    test('the message queue pop wins over history browsing', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = submit(model, 'older message');
      expect(model.inputHistory, ['older message']);
      // Now a run streams and a message waits in the queue…
      model = model.update(BusyMsg(true)).$1 as FaTuiModel;
      model = type(model, 'queued one');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      expect(model.queue, ['queued one']);
      // ↑ pops the queued message back for editing — NOT the history entry.
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.inputText, 'queued one');
      expect(model.queue, isEmpty);
      expect(model.historyIndex, -1);
    });

    test('slash commands are not recorded in history', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = submit(model, 'a real message');
      // Type a slash command, close the completion menu, submit via Ctrl+S.
      model = type(model, '/session');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.escape)));
      model = send(
        model,
        KeyPressMsg(
          const TeaKey(code: KeyCode.rune, text: 's', modifiers: {KeyMod.ctrl}),
        ),
      );
      expect(model.inputHistory, ['a real message']);
    });

    test('steered messages are recorded in history', () async {
      final steered = <List<String>>[];
      var model =
          FaTuiModel(
                callbacks: callbacks(steered: steered),
                isExited: () => false,
              ).update(BusyMsg(true)).$1
              as FaTuiModel;
      model = type(model, 'steer this');
      final result = model.update(
        KeyPressMsg(
          const TeaKey(code: KeyCode.rune, text: 's', modifiers: {KeyMod.ctrl}),
        ),
      );
      await result.$2?.call();
      model = result.$1 as FaTuiModel;
      expect(model.inputHistory, ['steer this']);
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

    test('an idle output append still varies the cursor line (re-home)', () {
      // dart_tui's row diff re-emits the cursor-home sequence only when the
      // row carrying it changed; a lone mid-history append while idle used
      // to strand the physical cursor inside the transcript.
      var model = filledModel();
      final before = model.view().content.split('\n').last;
      model = send(model, OutputMsg('fresh output', newline: true));
      final after = model.view().content.split('\n').last;
      expect(after, isNot(before));
      expect(after, contains('\x1b[?25h'));
      expect(after, contains(RegExp(r'\x1b\[\d+;\d+H$')));
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

    test(
      'the view leaves the mouse to the terminal unless capture opts in',
      () {
        // Default: no capture — native select-to-copy in the terminal.
        final model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
        expect(model.view().mouseMode, MouseMode.none);
        // FA_TUI_MOUSE=1 wiring: wheel scrolling gets the mouse instead.
        final capturing = FaTuiModel(
          callbacks: callbacks(),
          isExited: () => false,
          mouseCapture: true,
        );
        expect(capturing.view().mouseMode, MouseMode.cellMotion);
      },
    );
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

  group('output coalescing', () {
    FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

    test('a merged burst produces the same lines as separate messages', () {
      // The controller folds a burst of sendOutput calls into ONE OutputMsg
      // (text concatenated, newline flags as '\n') — the model must land on
      // identical history either way.
      var separate = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      var merged = FaTuiModel(callbacks: callbacks(), isExited: () => false);

      final pieces = <(String, bool)>[
        ('hel', false),
        ('lo', false),
        (' world', true),
        ('next ', false),
        ('line', true),
        ('tail', false),
      ];
      final folded = StringBuffer();
      for (final (text, newline) in pieces) {
        separate = send(separate, OutputMsg(text, newline: newline));
        folded.write(text);
        if (newline) folded.write('\n');
      }
      merged = send(merged, OutputMsg(folded.toString()));

      expect(merged.outputLines, separate.outputLines);
    });
  });

  group('editing and picker keys', () {
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

    test('home/end/right/backspace/delete edit the buffer', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'abc');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.left)));
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.backspace)));
      expect(model.inputText, 'ac');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.right)));
      expect(model.cursor, 2);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.home)));
      expect(model.cursor, 0);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.delete)));
      expect(model.inputText, 'c');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.end)));
      expect(model.cursor, 1);
    });

    test('alt+left and alt+right jump by words', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'foo bar');
      model = send(
        model,
        KeyPressMsg(const TeaKey(code: KeyCode.left, modifiers: {KeyMod.alt})),
      );
      expect(model.cursor, 4);
      model = send(
        model,
        KeyPressMsg(const TeaKey(code: KeyCode.right, modifiers: {KeyMod.alt})),
      );
      expect(model.cursor, 7);
    });

    test('ctrl+o inserts a newline at the cursor', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'ab');
      model = send(model, ctrl('o'));
      expect(model.inputText, 'ab\n');
      expect(model.cursor, 3);
    });

    test('shift+enter inserts a newline when the host reports shift', () {
      var model = FaTuiModel(
        callbacks: callbacks(isShiftPressed: () => true),
        isExited: () => false,
      );
      model = typed(model, 'ab');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      expect(model.inputText, 'ab\n');
      expect(model.cursor, 3);
    });

    test('ctrl+s submits the input when idle', () async {
      final submitted = <String>[];
      var model = FaTuiModel(
        callbacks: callbacks(submitted: submitted),
        isExited: () => false,
      );
      model = typed(model, 'hi');
      final result = model.update(ctrl('s'));
      await result.$2?.call();
      expect(submitted, ['hi']);
    });

    test('ctrl+c interrupts and returns a quit command', () {
      var interrupted = false;
      final model = FaTuiModel(
        callbacks: callbacks(onInterrupt: () => interrupted = true),
        isExited: () => false,
      );
      final result = model.update(ctrl('c'));
      expect(interrupted, isTrue);
      expect(result.$2, isNotNull);
    });

    test('generic picker arrows and page keys navigate with clamping', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = send(
        model,
        OpenPickerMsg('sessions', 'Sessions', const [
          MenuItem(key: 'a', label: 'a'),
          MenuItem(key: 'b', label: 'b'),
          MenuItem(key: 'c', label: 'c'),
        ]),
      );
      expect(model.menuSelected, 0);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      // Clamped at the last item.
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      expect(model.menuSelected, 2);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.menuSelected, 1);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageDown)));
      expect(model.menuSelected, 2);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      expect(model.menuSelected, 0);
    });

    test('generic picker backspace is a no-op', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = send(
        model,
        OpenPickerMsg('sessions', 'Sessions', const [
          MenuItem(key: 'a', label: 'a'),
        ]),
      );
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.backspace)));
      expect(model.menuOpen, isTrue);
      expect(model.menuSelected, 0);
    });

    test('models picker backspace edits the filter', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, '/models ab');
      expect(model.modelFilter, 'ab');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.backspace)));
      expect(model.modelFilter, 'a');
      expect(model.menuItems.single.key, 'model-a');
    });

    test('slash menu escape closes it', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, '/');
      expect(model.menuOpen, isTrue);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.escape)));
      expect(model.menuOpen, isFalse);
    });

    test('slash menu arrows navigate the items', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, '/');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      expect(model.menuSelected, 1);
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.up)));
      expect(model.menuSelected, 0);
    });

    test('accepting /model from the slash menu opens the model picker', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, '/');
      // /help, /exit, /model — select the third.
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.down)));
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      expect(model.pickerId, 'models');
      expect(model.menuModelMode, isTrue);
      expect(model.menuItems, hasLength(2));
    });

    test('slash menu backspace keeps editing the input', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, '/h');
      expect(model.menuItems, hasLength(1));
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.backspace)));
      expect(model.inputText, '/');
      expect(model.menuItems, hasLength(4));
    });

    test('pageDown scrolls the history back down', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termHeight: 12,
      );
      for (var i = 0; i < 30; i++) {
        model = send(model, OutputMsg('line $i', newline: true));
      }
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      final scrolledUp = model.scrollOffset;
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageDown)));
      expect(model.scrollOffset, greaterThan(scrolledUp));
    });

    test('paste inserts at the cursor', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = typed(model, 'ad');
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.left)));
      model = send(model, PasteMsg('bc'));
      expect(model.inputText, 'abcd');
      expect(model.cursor, 3);
    });

    test('paste repairs dart_tui byte-as-charcode mojibake (Cyrillic)', () {
      // dart_tui 2.0.0's paste decoder maps every pasted byte to a char code
      // (Latin-1): UTF-8 Cyrillic arrives as mojibake. fa repairs it.
      final mangled = String.fromCharCodes(utf8.encode('Привет'));
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = send(model, PasteMsg(mangled));
      expect(model.inputText, 'Привет');
      expect(model.cursor, 6);
    });

    test('a multi-char rune splits into single key events', () {
      var model = FaTuiModel(callbacks: callbacks(), isExited: () => false);
      model = send(
        model,
        KeyPressMsg(TeaKey(code: KeyCode.rune, text: 'paste')),
      );
      expect(model.inputText, 'paste');
      expect(model.cursor, 5);
    });

    test('resize clamps the scroll offset and requests a clear', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termHeight: 12,
      );
      for (var i = 0; i < 30; i++) {
        model = send(model, OutputMsg('line $i', newline: true));
      }
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.pageUp)));
      final result = model.update(WindowSizeMsg(120, 20));
      expect(result.$2, isNotNull);
      expect((result.$1 as FaTuiModel).termWidth, 120);
    });
  });

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
      expect(textView.content, contains('\x1b[?25l'));
      expect(textView.content, isNot(contains('\x1b[?25h')));
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
      expect(pickerView.content, contains('\x1b[?25l'));
      expect(pickerView.content, isNot(contains('\x1b[?25h')));
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
      expect(pickerView.content, contains('\x1b[?25l'));
      expect(pickerView.content, isNot(contains('\x1b[?25h')));
      expect(pickerView.cursor, isNull);

      // Slash menu: typing edits the filter, so the cursor stays visible.
      final slashMenu = send(
        model,
        KeyPressMsg(const TeaKey(code: KeyCode.rune, text: '/')),
      );
      expect(slashMenu.menuOpen, isTrue);
      expect(slashMenu.view().content, contains('\x1b[?25h'));
    });
  });

  group('terminal flow control helpers', () {
    test('sttyDeviceFlag is -f on macOS and -F elsewhere', () {
      expect(FaTuiController.sttyDeviceFlag(), Platform.isMacOS ? '-f' : '-F');
    });

    test('sttyDisableFlowControl returns trimmed saved termios', () async {
      final calls = <List<String>>[];
      Future<ProcessResult> runner(List<String> args) async {
        calls.add(args);
        if (args.last == '-g') {
          return ProcessResult(0, 0, 'saved-string\n', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final result = await FaTuiController.sttyDisableFlowControl(
        '-F',
        runner: runner,
      );

      expect(result, 'saved-string');
      expect(calls, hasLength(2));
      expect(calls.first, ['-F', '/dev/tty', '-g']);
      expect(calls.last, ['-F', '/dev/tty', '-ixon', '-ixoff']);
    });

    test('sttyDisableFlowControl returns null when saving fails', () async {
      Future<ProcessResult> runner(List<String> args) async {
        return ProcessResult(0, 1, '', 'stty error');
      }

      final result = await FaTuiController.sttyDisableFlowControl(
        '-F',
        runner: runner,
      );
      expect(result, isNull);
    });

    test('sttyDisableFlowControl returns null when clearing fails', () async {
      Future<ProcessResult> runner(List<String> args) async {
        if (args.last == '-g') {
          return ProcessResult(0, 0, 'saved', '');
        }
        return ProcessResult(0, 1, '', 'stty error');
      }

      final result = await FaTuiController.sttyDisableFlowControl(
        '-F',
        runner: runner,
      );
      expect(result, isNull);
    });

    test('sttyDisableFlowControl returns null on ProcessException', () async {
      Future<ProcessResult> runner(List<String> args) async {
        throw ProcessException('stty', <String>[], 'not found');
      }

      final result = await FaTuiController.sttyDisableFlowControl(
        '-F',
        runner: runner,
      );
      expect(result, isNull);
    });
  });
}
