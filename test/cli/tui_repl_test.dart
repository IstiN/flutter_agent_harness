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
  final writelnCalls = <String>[];
  final submitted = <String>[];
  final selectedModels = <String>[];
  final input = StreamController<dynamic>();
  late final TuiRepl repl;

  _Harness() {
    repl = TuiRepl(
      write: out.write,
      writeln: writelnCalls.add,
      prompt: 'fa> ',
      statusLine: () => '/work · 0tok · turn 0 · test-model',
      style: _NoopStyle(),
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
      buildModelMenu: () => const [
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

    expect(h.writelnCalls, contains('[Commands]'));
    expect(
      h.writelnCalls,
      contains(predicate<String>((l) => l.contains('/help'))),
    );
    expect(
      h.writelnCalls,
      contains(predicate<String>((l) => l.contains('/exit'))),
    );

    await h.finish();
    await run;
  });

  test('escape closes the command menu', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    expect(h.writelnCalls, contains('[Commands]'));

    h.input.add(const KeyEvent(type: KeyType.escape));
    await h.pump();
    expect(h.writelnCalls.last, isNot(contains('[Commands]')));

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

  test('typing /m opens the model picker', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    h.input.add(const KeyEvent(char: 'm', type: KeyType.char));
    await h.pump();

    expect(h.writelnCalls, contains('[Select model]'));
    expect(
      h.writelnCalls,
      contains(predicate<String>((l) => l.contains('model-a'))),
    );
    expect(
      h.writelnCalls,
      contains(predicate<String>((l) => l.contains('model-b'))),
    );

    await h.finish();
    await run;
  });

  test('typing after / filters the command menu', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    h.input.add(const KeyEvent(char: 'h', type: KeyType.char));
    await h.pump();

    final lastMenu = h.writelnCalls.lastIndexOf('[Commands]');
    expect(lastMenu, greaterThanOrEqualTo(0));
    final menuLines = h.writelnCalls.skip(lastMenu + 1).toList();
    expect(menuLines.any((l) => l.contains('/help')), isTrue);
    expect(menuLines.any((l) => l.contains('/exit')), isFalse);

    await h.finish();
    await run;
  });

  test('enter in the model picker selects a model', () async {
    final h = _Harness();
    final run = h.repl.run(h.input.stream);

    h.input.add(const KeyEvent(char: '/', type: KeyType.char));
    await h.pump();
    h.input.add(const KeyEvent(char: 'm', type: KeyType.char));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.down));
    await h.pump();
    h.input.add(const KeyEvent(type: KeyType.enter));
    await h.pump();

    await h.finish();
    await run;

    expect(h.selectedModels, ['model-b']);
  });
}
