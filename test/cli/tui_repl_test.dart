import 'dart:async';

import 'package:flutter_agent_harness/src/cli/key_event.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

class _NoopStyle implements TuiStyle {
  @override
  String bold(String text) => text;
  @override
  String dim(String text) => text;
  @override
  String cyan(String text) => text;
  @override
  String green(String text) => text;
  @override
  String yellow(String text) => text;
  @override
  String magenta(String text) => text;
}

class _Harness {
  final out = StringBuffer();
  final submitted = <String>[];
  final selectedModels = <String>[];
  final input = StreamController<dynamic>();
  late TuiRepl repl;

  _Harness() {
    repl = TuiRepl(
      write: out.write,
      writeln: (text) => out.writeln(text),
      prompt: 'fa> ',
      statusLine: () => '/work · 0tok · turn 0 · test-model',
      style: _NoopStyle(),
      columns: 80,
      rows: 24,
      buildSlashMenu: (prefix) {
        final lower = prefix.toLowerCase();
        const items = [
          MenuItem(key: '/help', label: '/help', description: 'show help'),
          MenuItem(key: '/exit', label: '/exit', description: 'quit'),
          MenuItem(key: '/model', label: '/model', description: 'select model'),
        ];
        return items
            .where(
              (item) =>
                  item.key.toLowerCase().contains(lower) ||
                  item.description.toLowerCase().contains(lower),
            )
            .toList();
      },
      buildModelMenu: (filter) => const [
        MenuItem(key: 'model-a', label: 'model-a'),
        MenuItem(key: 'model-b', label: 'model-b'),
      ],
      onSubmit: (line) async => submitted.add(line),
      onModelSelected: (id) async => selectedModels.add(id),
    );
  }

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  Future<void> finish() async {
    await input.close();
  }
}

void main() {
  test('typing / opens the command menu', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();

    expect(h.out.toString(), contains('[Commands]'));
    expect(h.out.toString(), contains('/help'));
    expect(h.out.toString(), contains('/exit'));

    await h.finish();
    await run;
  });

  test('escape closes the command menu', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    expect(h.out.toString(), contains('[Commands]'));

    h.input.add(const KeyEvent(type: KeyType.escape));
    await h.pump();
    final lastFrame = h.out.toString().split('\x1b[?2026l').last;
    expect(lastFrame, isNot(contains('[Commands]')));

    await h.finish();
    await run;
  });

  test('arrow down + enter selects a slash command then submits it', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.down));
    await h.pump();
    // First item is /help, down selects /exit.
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();

    await h.finish();
    await run;

    expect(h.submitted, ['/exit']);
  });

  test('typing after / filters the command menu', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    h.input.add(const KeyEvent(char: 'h', type: KeyType.char));
    await h.pump();

    final output = h.out.toString();
    final lastMenu = output.lastIndexOf('[Commands]');
    expect(lastMenu, greaterThanOrEqualTo(0));
    final menuSlice = output.substring(lastMenu);
    expect(menuSlice.contains('/help'), isTrue);
    expect(menuSlice.contains('/exit'), isFalse);

    await h.finish();
    await run;
  });

  test('typing /models opens the model picker', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    for (final ch in 'models'.split('')) {
      h.input.add(KeyEvent(char: ch, type: KeyType.char));
    }
    await h.pump();

    expect(h.out.toString(), contains('[Select model]'));
    expect(h.out.toString(), contains('model-a'));
    expect(h.out.toString(), contains('model-b'));

    await h.finish();
    await run;
  });

  test('openModelMenu opens the model picker', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.repl.openModelMenu();
    await h.pump();

    expect(h.out.toString(), contains('[Select model]'));
    expect(h.out.toString(), contains('model-a'));

    await h.finish();
    await run;
  });

  test('enter in the model picker selects a model', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.repl.openModelMenu();
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.down));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();

    await h.finish();
    await run;

    expect(h.selectedModels, ['model-b']);
  });

  test('selecting /model from slash menu opens model picker', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    // /model is the third item, so press down twice.
    h.input.add(const KeyEvent(type: KeyType.down));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.down));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();

    expect(h.out.toString(), contains('[Select model]'));

    await h.finish();
    await run;
  });

  test('refresh updates the model picker while open', () async {
    final h = _Harness();
    final extra = <MenuItem>[];
    h.repl = TuiRepl(
      write: h.out.write,
      writeln: (text) => h.out.writeln(text),
      prompt: 'fa> ',
      statusLine: () => '/work · 0tok · turn 0 · test-model',
      style: _NoopStyle(),
      columns: 80,
      rows: 24,
      buildSlashMenu: (_) => const [],
      buildModelMenu: (filter) => [
        const MenuItem(key: 'model-a', label: 'model-a'),
        ...extra,
      ],
      onSubmit: (line) async => h.submitted.add(line),
      onModelSelected: (id) async => h.selectedModels.add(id),
    );
    final run = h.repl.run(h.input.stream);

    h.repl.openModelMenu();
    await h.pump();
    expect(h.out.toString(), contains('model-a'));
    expect(h.out.toString(), isNot(contains('model-c')));

    extra.add(const MenuItem(key: 'model-c', label: 'model-c'));
    h.repl.refresh();
    await h.pump();
    expect(h.out.toString(), contains('model-c'));

    await h.finish();
    await run;
  });

  test('typing /models open filters the model picker', () async {
    final h = _Harness();
    h.repl = TuiRepl(
      write: h.out.write,
      writeln: (text) => h.out.writeln(text),
      prompt: 'fa> ',
      statusLine: () => '/work · 0tok · turn 0 · test-model',
      style: _NoopStyle(),
      columns: 80,
      rows: 24,
      buildSlashMenu: (_) => const [],
      buildModelMenu: (filter) => [
        if ('model-a'.contains(filter))
          const MenuItem(key: 'model-a', label: 'model-a'),
        if ('model-b'.contains(filter))
          const MenuItem(key: 'model-b', label: 'model-b'),
      ],
      onSubmit: (line) async => h.submitted.add(line),
      onModelSelected: (id) async => h.selectedModels.add(id),
    );
    final run = h.repl.run(h.input.stream);

    for (final ch in '/models a'.split('')) {
      h.input.add(KeyEvent(char: ch, type: KeyType.char));
    }
    await h.pump();

    final output = h.out.toString();
    final lastMenu = output.lastIndexOf('[Select model: a]');
    expect(lastMenu, greaterThanOrEqualTo(0));
    final menuSlice = output.substring(lastMenu);
    expect(menuSlice, contains('model-a'));
    expect(menuSlice, isNot(contains('model-b')));

    await h.finish();
    await run;
  });

  test('typing in model picker filters the list', () async {
    final h = _Harness();
    h.repl = TuiRepl(
      write: h.out.write,
      writeln: (text) => h.out.writeln(text),
      prompt: 'fa> ',
      statusLine: () => '/work · 0tok · turn 0 · test-model',
      style: _NoopStyle(),
      columns: 80,
      rows: 24,
      buildSlashMenu: (_) => const [],
      buildModelMenu: (filter) => [
        if ('model-a'.contains(filter))
          const MenuItem(key: 'model-a', label: 'model-a'),
        if ('model-b'.contains(filter))
          const MenuItem(key: 'model-b', label: 'model-b'),
      ],
      onSubmit: (line) async => h.submitted.add(line),
      onModelSelected: (id) async => h.selectedModels.add(id),
    );
    final run = h.repl.run(h.input.stream);

    h.repl.openModelMenu();
    await h.pump();
    h.input.add(const KeyEvent(char: 'a', type: KeyType.char));
    await h.pump();

    final output = h.out.toString();
    final lastMenu = output.lastIndexOf('[Select model: a]');
    expect(lastMenu, greaterThanOrEqualTo(0));
    final menuSlice = output.substring(lastMenu);
    expect(menuSlice, contains('model-a'));
    expect(menuSlice, isNot(contains('model-b')));

    await h.finish();
    await run;
  });

  test('tab in model picker accepts the current selection', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.repl.openModelMenu();
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.down));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.tab));
    await h.pump();

    await h.finish();
    await run;

    expect(h.selectedModels, ['model-b']);
  });

  test('appendOutput adds lines above the prompt', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.repl.appendOutput('tool result line\n');
    await h.pump();
    h.repl.appendOutput('another line');
    await h.pump();

    final output = h.out.toString();
    expect(output, contains('tool result line'));
    expect(output, contains('another line'));
    expect(output, contains('fa> '));

    await h.finish();
    await run;
  });

  test('alt screen is entered and exited', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);
    await h.pump();
    expect(h.out.toString(), contains('\x1b[?1049h'));

    await h.finish();
    await run;
    expect(h.out.toString(), contains('\x1b[?1049l'));
  });

  test('cursor motion and editing keys edit the buffer', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    for (final ch in 'abc'.split('')) {
      h.input.add(KeyEvent(char: ch, type: KeyType.char));
    }
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.left));
    h.input.add(const KeyEvent(type: KeyType.left));
    await h.pump();
    // Cursor on 'b': backspace deletes 'a'.
    h.input.add(const KeyEvent(type: KeyType.backspace));
    await h.pump();
    // Append at the end.
    h.input.add(const KeyEvent(type: KeyType.end));
    h.input.add(const KeyEvent(char: 'd', type: KeyType.char));
    await h.pump();
    // Home + delete removes the leading 'b'.
    h.input.add(const KeyEvent(type: KeyType.home));
    h.input.add(const KeyEvent(type: KeyType.delete));
    await h.pump();
    // Right past the end is a no-op; submit what remains.
    h.input.add(const KeyEvent(type: KeyType.right));
    h.input.add(const KeyEvent(type: KeyType.right));
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();

    await h.finish();
    await run;

    expect(h.submitted, ['cd']);
  });

  test('unknown keys are ignored', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(type: KeyType.unknown));
    h.input.add(const KeyEvent(char: 'a', type: KeyType.char));
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();

    await h.finish();
    await run;

    expect(h.submitted, ['a']);
  });

  test('tab accepts the selected slash command', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.tab));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();

    await h.finish();
    await run;

    expect(h.submitted, ['/help']);
  });

  test(
    'slash menu arrows, shiftTab, and page keys move the selection',
    () async {
      final h = _Harness();
      final run = h.repl.run(h.input.stream);

      h.input.add(const KeyEvent(char: '/', type: KeyType.char));
      await h.pump();
      h.input.add(const KeyEvent(type: KeyType.pageDown));
      await h.pump();
      // Last item is /model: pageUp + down lands on /exit.
      h.input.add(const KeyEvent(type: KeyType.pageUp));
      h.input.add(const KeyEvent(type: KeyType.down));
      await h.pump();
      // up then shiftTab return to the first item, down again to /exit.
      h.input.add(const KeyEvent(type: KeyType.up));
      h.input.add(const KeyEvent(type: KeyType.shiftTab));
      h.input.add(const KeyEvent(type: KeyType.down));
      await h.pump();
      h.input.add(const KeyEvent(type: KeyType.enter));
      await h.pump();
      h.input.add(const KeyEvent(type: KeyType.enter));
      await h.pump();

      await h.finish();
      await run;

      expect(h.submitted, ['/exit']);
    },
  );

  test('model picker backspace edits the filter', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.repl.openModelMenu();
    await h.pump();
    h.input.add(const KeyEvent(char: 'b', type: KeyType.char));
    await h.pump();
    expect(h.out.toString(), contains('[Select model: b]'));

    h.input.add(const KeyEvent(type: KeyType.backspace));
    await h.pump();
    // The filter is cleared: the latest title redraw has no ': b' suffix.
    final output = h.out.toString();
    final lastTitle = output.lastIndexOf('[Select model');
    expect(lastTitle, greaterThanOrEqualTo(0));
    expect(output.substring(lastTitle, lastTitle + 14), '[Select model]');

    await h.finish();
    await run;
  });

  test('model picker escape closes the picker', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.repl.openModelMenu();
    await h.pump();
    expect(h.out.toString(), contains('[Select model]'));

    h.input.add(const KeyEvent(type: KeyType.escape));
    await h.pump();
    final lastFrame = h.out.toString().split('\x1b[?2026l').last;
    expect(lastFrame, isNot(contains('[Select model]')));

    await h.finish();
    await run;
  });

  test('model picker navigation clamps and page keys jump', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.repl.openModelMenu();
    await h.pump();
    // up at the top stays; pageDown jumps to the last item; down clamps.
    h.input.add(const KeyEvent(type: KeyType.up));
    h.input.add(const KeyEvent(type: KeyType.pageDown));
    h.input.add(const KeyEvent(type: KeyType.down));
    await h.pump();
    // pageUp + shiftTab stay at the top; down selects model-b.
    h.input.add(const KeyEvent(type: KeyType.pageUp));
    h.input.add(const KeyEvent(type: KeyType.shiftTab));
    h.input.add(const KeyEvent(type: KeyType.down));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();

    await h.finish();
    await run;

    expect(h.selectedModels, ['model-b']);
  });

  test('model picker ignores editing and unknown keys', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.repl.openModelMenu();
    await h.pump();
    for (final type in [
      KeyType.home,
      KeyType.end,
      KeyType.left,
      KeyType.right,
      KeyType.delete,
      KeyType.unknown,
    ]) {
      h.input.add(KeyEvent(type: type));
    }
    await h.pump();
    // Still open and functional.
    h.input.add(const KeyEvent(type: KeyType.down));
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();

    await h.finish();
    await run;

    expect(h.selectedModels, ['model-b']);
  });
}
