// Model-level mouse tests (issue #278): composer click→caret, queue-row
// click→drop, the /mouse toggle (AC4/E4) and the REG guarantees — wheel
// behavior unchanged with regions present, capture off silences regions.
import 'package:dart_tui/dart_tui.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart'
    show MenuItem, QueuedMessage;
import 'package:test/test.dart';

void main() {
  FaTuiCallbacks callbacks() => FaTuiCallbacks(
    onSubmit: (_) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => 'test',
    prompt: 'fa> ',
  );

  FaTuiModel send(FaTuiModel m, Msg msg) => m.update(msg).$1 as FaTuiModel;

  Mouse mouseAt(int x, int y) => Mouse(x: x, y: y, button: MouseButton.left);

  List<String> frameLines(FaTuiModel m) => m.view().content.split('\n');

  FaTuiModel inputModel(String text) => FaTuiModel(
    callbacks: callbacks(),
    isExited: () => false,
    termHeight: 12,
  ).copyWith(inputText: text);

  int rowOf(List<String> lines, String needle) {
    final y = lines.indexWhere((l) => l.contains(needle));
    expect(y, greaterThanOrEqualTo(0), reason: 'no "$needle" in frame');
    return y;
  }

  group('composer hit-region', () {
    test('click moves the caret to the clicked cell', () {
      var model = inputModel('hello world');
      final lines = frameLines(model);
      final y = rowOf(lines, 'hello world');
      final x = lines[y].indexOf('world');
      model = send(model, MouseClickMsg(mouseAt(x, y)));
      model = send(model, MouseReleaseMsg(mouseAt(x, y)));
      expect(model.cursor, 6);
    });

    test('clicking past the line end snaps the caret to the end', () {
      var model = inputModel('hi');
      final y = rowOf(frameLines(model), 'hi');
      model = send(model, MouseClickMsg(mouseAt(9, y)));
      model = send(model, MouseReleaseMsg(mouseAt(9, y)));
      expect(model.cursor, 2);
    });

    test('click on a wrapped second row lands mid-line', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termWidth: 10,
        termHeight: 12,
      ).copyWith(inputText: 'aaaaaaaaaabbbb');
      final y = rowOf(frameLines(model), 'bbbb');
      final x = frameLines(model)[y].indexOf('bbbb');
      model = send(model, MouseClickMsg(mouseAt(x, y)));
      model = send(model, MouseReleaseMsg(mouseAt(x, y)));
      expect(model.cursor, 10); // start of 'bbbb', the second wrap chunk
    });

    test('click on the trailing empty row of a multiline input snaps to '
        'the line end', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termWidth: 10,
        termHeight: 12,
      ).copyWith(inputText: 'aaa\n');
      final inputY = rowOf(frameLines(model), 'aaa');
      model = send(model, MouseClickMsg(mouseAt(0, inputY + 1)));
      model = send(model, MouseReleaseMsg(mouseAt(0, inputY + 1)));
      expect(model.cursor, 3);
    });

    test('a press survives an interleaved model copy (spinner tick)', () {
      var model = inputModel('abc');
      final y = rowOf(frameLines(model), 'abc');
      model = send(model, MouseClickMsg(mouseAt(1, y)));
      // Any event that copies the model between press and release must not
      // lose the press — the router is input plumbing carried by copyWith.
      model = model.copyWith(spinnerFrame: model.spinnerFrame + 1);
      model = send(model, MouseReleaseMsg(mouseAt(1, y)));
      expect(model.cursor, 1);
    });
  });

  group('queue row hit-region', () {
    test('clicking a queued message drops it', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termHeight: 12,
      ).copyWith(queue: const [QueuedMessage('first message'), QueuedMessage('second message')]);
      final y = rowOf(frameLines(model), 'second message');
      model = send(model, MouseClickMsg(mouseAt(3, y)));
      model = send(model, MouseReleaseMsg(mouseAt(3, y)));
      expect(model.queue.map((q) => q.text), ['first message']);
    });
  });

  group('REG: wheel auto-detect unchanged with regions present', () {
    test('wheel still scrolls after view() registered regions', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termHeight: 12,
      );
      for (var i = 0; i < 30; i++) {
        model = send(model, OutputMsg('line $i', newline: true));
      }
      final bottom = model.scrollOffset;
      model.view(); // registers the frame's hit regions
      model = send(
        model,
        MouseWheelMsg(const Mouse(x: 0, y: 0, button: MouseButton.wheelUp)),
      );
      expect(model.scrollOffset, bottom - 3);
      expect(model.followTail, isFalse);
    });
  });

  group('REG: capture off silences region handling', () {
    test('clicks change nothing when capture is off', () {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        mouseCapture: false,
        termHeight: 12,
      ).copyWith(inputText: 'abc', queue: const [QueuedMessage('q1')]);
      model = send(model, MouseClickMsg(mouseAt(1, 1)));
      model = send(model, MouseReleaseMsg(mouseAt(1, 1)));
      expect(model.cursor, 0);
      expect(model.inputText, 'abc');
      expect(model.queue.map((q) => q.text), ['q1']);
    });
  });

  group('/mouse command (AC4/E4)', () {
    Future<FaTuiModel> submit(FaTuiModel model, String line) async {
      var m = model.copyWith(inputText: line);
      m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      return m;
    }

    test('off prints the degrade hint once and disables capture', () async {
      var model = await submit(
        FaTuiModel(callbacks: callbacks(), isExited: () => false),
        '/mouse off',
      );
      expect(model.mouseCapture, isFalse);
      expect(model.view().mouseMode, MouseMode.none);
      expect(model.view().content, contains('mouse capture off'));
      // Second off: no duplicate hint (E4).
      model = await submit(model, '/mouse off');
      expect(
        'mouse capture off'.allMatches(model.view().content),
        hasLength(1),
      );
    });

    test('on re-enables capture and regions', () async {
      var model = await submit(
        FaTuiModel(
          callbacks: callbacks(),
          isExited: () => false,
          mouseCapture: false,
        ),
        '/mouse on',
      );
      expect(model.mouseCapture, isTrue);
      expect(model.view().mouseMode, MouseMode.cellMotion);
      // Regions are active again: a click moves the caret.
      model = inputModel('abc');
      final y = rowOf(frameLines(model), 'abc');
      model = send(model, MouseClickMsg(mouseAt(2, y)));
      model = send(model, MouseReleaseMsg(mouseAt(2, y)));
      expect(model.cursor, 2);
    });

    test('unknown argument prints usage, capture unchanged', () async {
      final model = await submit(
        FaTuiModel(callbacks: callbacks(), isExited: () => false),
        '/mouse sideways',
      );
      expect(model.view().content, contains('usage: /mouse'));
      expect(model.mouseCapture, isTrue);
    });
  });

  group('menuRow routing (E1)', () {
    // click+release, running the returned Cmd (accept effects are async).
    Future<FaTuiModel> click(FaTuiModel m, int x, int y) async {
      var (next, cmd) = m.update(MouseClickMsg(mouseAt(x, y)));
      await cmd?.call();
      (next, cmd) = next.update(MouseReleaseMsg(mouseAt(x, y)));
      await cmd?.call();
      return next as FaTuiModel;
    }

    FaTuiCallbacks slashCb() => FaTuiCallbacks(
      onSubmit: (_) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [
        MenuItem(key: '/exit', label: '/exit', description: 'quit'),
        MenuItem(key: '/model', label: '/model', description: 'model'),
      ],
      buildModelMenu: (_, _) => const [
        MenuItem(key: 'glm', label: 'glm', description: 'x'),
      ],
      statusLine: () => 'test',
      prompt: 'fa> ',
    );

    test('click on a plain slash menu row inserts the item, not the '
        'picker accept', () async {
      var model = FaTuiModel(
        callbacks: slashCb(),
        isExited: () => false,
        termHeight: 12,
      ).copyWith(
        inputText: '/',
        menuOpen: true,
        menuTokenStart: 0,
        menuItems: slashCb().buildSlashMenu('/'),
      );
      final y = rowOf(frameLines(model), '/exit');
      model.view(); // register this frame's regions
      model = await click(model, 3, y);
      // Picker-accept would have cleared the input to '' and fired the
      // (empty) onPickerSelected — the slash path fills the command.
      expect(model.inputText, '/exit');
      expect(model.menuOpen, isFalse);
    });

    test('a closed model picker leaves no stale picker id behind', () async {
      var selected = false;
      FaTuiCallbacks cb() => FaTuiCallbacks(
        onSubmit: (_) async {},
        onModelSelected: (_) async => selected = true,
        buildSlashMenu: (_) => const [
          MenuItem(key: '/help', label: '/help', description: 'help'),
          MenuItem(key: '/model', label: '/model', description: 'model'),
        ],
        buildModelMenu: (_, _) => const [
          MenuItem(key: 'glm', label: 'glm', description: 'x'),
        ],
        statusLine: () => 'test',
        prompt: 'fa> ',
      );
      var model = FaTuiModel(
        callbacks: cb(),
        isExited: () => false,
        termHeight: 12,
      ).copyWith(
        inputText: '/',
        menuOpen: true,
        menuTokenStart: 0,
        menuItems: cb().buildSlashMenu('/'),
      );
      // Click the /model row -> opens the models picker (pickerId set).
      final yModel = rowOf(frameLines(model), '/model');
      model.view();
      model = await click(model, 3, yModel);
      expect(model.pickerId, 'models');

      // Esc closes the picker; the id must reset (stale id would route a
      // later plain-slash click into onPickerSelected('models', …)).
      model = send(model, KeyPressMsg(const TeaKey(code: KeyCode.escape)));
      expect(model.pickerId, isEmpty);

      // A slash click after the close takes the plain-menu path again.
      model = model.copyWith(
        inputText: '/',
        menuOpen: true,
        menuTokenStart: 0,
        menuItems: cb().buildSlashMenu('/'),
      );
      final yHelp = rowOf(frameLines(model), '/help');
      model.view();
      model = await click(model, 3, yHelp);
      expect(model.inputText, '/help');
      expect(selected, isFalse);
    });

    test('clicking a picker row still resolves via onModelSelected',
        () async {
      var selected = '';
      FaTuiCallbacks cb() => FaTuiCallbacks(
        onSubmit: (_) async {},
        onModelSelected: (key) async => selected = key,
        buildSlashMenu: (_) => const [],
        buildModelMenu: (_, _) => const [
          MenuItem(key: 'glm', label: 'glm', description: 'x'),
        ],
        statusLine: () => 'test',
        prompt: 'fa> ',
      );
      var model = FaTuiModel(
        callbacks: cb(),
        isExited: () => false,
        termHeight: 12,
      ).copyWith(
        menuOpen: true,
        menuModelMode: true,
        pickerId: 'models',
        menuItems: const [
          MenuItem(key: 'glm', label: 'glm', description: 'x'),
        ],
      );
      final y = rowOf(frameLines(model), 'glm');
      model.view();
      model = await click(model, 3, y);
      expect(selected, 'glm');
      expect(model.pickerId, isEmpty);
    });
  });


  group('/mouse off wires the terminal down (AC4)', () {
    Future<FaTuiModel> submit(FaTuiModel model, String line) async {
      var m = model.copyWith(inputText: line);
      m = send(m, KeyPressMsg(const TeaKey(code: KeyCode.enter)));
      return m;
    }

    test('wheel bytes arriving after off do not scroll', () async {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termHeight: 12,
      );
      for (var i = 0; i < 30; i++) {
        model = send(model, OutputMsg('line $i', newline: true));
      }
      final bottom = model.scrollOffset;
      model = await submit(model, '/mouse off');
      expect(model.mouseCapture, isFalse);
      model = send(
        model,
        MouseWheelMsg(
          const Mouse(x: 0, y: 0, button: MouseButton.wheelUp),
        ),
      );
      // The hint promises a keyboard-only session — honor it even for
      // bytes a not-yet-disarmed terminal still sends.
      expect(model.scrollOffset, bottom);
    });
  });
}
