import 'package:flutter_agent_harness/src/cli/tui_key_hints.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

void main() {
  group('TuiChord parse/display round-trips', () {
    test('parse normalizes case, hyphens, spaces and glyphs', () {
      expect(TuiChord.parse('ctrl+x'), const TuiChord('ctrl+x'));
      expect(TuiChord.parse('Ctrl-X'), const TuiChord('ctrl+x'));
      expect(TuiChord.parse('CTRL  X'), const TuiChord('ctrl+x'));
      expect(TuiChord.parse('shift+enter'), const TuiChord('shift+enter'));
      expect(TuiChord.parse('Shift Enter'), const TuiChord('shift+enter'));
      expect(TuiChord.parse('↑'), const TuiChord('up'));
      expect(TuiChord.parse('Enter'), const TuiChord('enter'));
    });

    test('hint form is compact lowercase with arrow glyphs', () {
      expect(const TuiChord('ctrl+x').hint, 'ctrl+x');
      expect(const TuiChord('up').hint, '↑');
      expect(const TuiChord('shift+enter').hint, 'shift+enter');
    });

    test('display form is prose-cased and platform-aware', () {
      expect(const TuiChord('ctrl+x').display(), 'Ctrl+X');
      expect(const TuiChord('enter').display(), 'Enter');
      expect(const TuiChord('pgup').display(), 'PgUp');
      expect(const TuiChord('alt+enter').display(), 'Alt+Enter');
      expect(const TuiChord('alt+enter').display(darwin: true), 'Option+Enter');
      expect(const TuiChord('ctrl+a').display(darwin: true), 'Ctrl+A');
      expect(const TuiChord('up').display(), '↑');
      expect(const TuiChord('1').display(), '1');
      expect(const TuiChord('ctrl+home').display(), 'Ctrl+Home');
    });

    test('parse(display) round-trips for every registry chord', () {
      for (final binding in kTuiKeybindings) {
        for (final chord in binding.chords) {
          final canonical = chord.canonical;
          for (final darwin in [false, true]) {
            final reparsed = TuiChord.parse(chord.display(darwin: darwin));
            expect(
              reparsed.canonical,
              canonical,
              reason: '${binding.action}: "${chord.display(darwin: darwin)}" '
                  'must reparse to "$canonical"',
            );
          }
          // Parse is idempotent on the canonical form itself.
          expect(TuiChord.parse(canonical).canonical, canonical);
        }
      }
    });

    test('equality is canonical-form based', () {
      expect(TuiChord.parse('Ctrl+X'), const TuiChord('ctrl+x'));
      expect(const TuiChord('up').hashCode, TuiChord.parse('↑').hashCode);
    });
  });

  group('registry covers the issue #809 bindings', () {
    test('queue/steer/dequeue hint chords', () {
      expect(tuiChordsFor('queue.pop').map((c) => c.canonical), ['up']);
      expect(tuiChordsFor('queue.delete').map((c) => c.canonical), ['ctrl+x']);
      expect(tuiChordsFor('queue.steer').map((c) => c.canonical), ['ctrl+s']);
      expect(tuiChordsFor('run.queue').map((c) => c.canonical), ['enter']);
    });

    test('picker footer chords', () {
      expect(
        tuiChordsFor('picker.navigate').map((c) => c.canonical),
        ['up', 'down'],
      );
      expect(
        tuiChordsFor('picker.select').map((c) => c.canonical),
        containsAll(['enter', 'tab']),
      );
      expect(tuiChordsFor('picker.close').map((c) => c.canonical), ['esc']);
    });

    test('prompt-sheet chords (tab cycle, ctrl+R reveal, ctrl+U kill)', () {
      expect(tuiChordsFor('prompt.nextField').map((c) => c.canonical),
          ['tab']);
      expect(tuiChordsFor('prompt.reveal').map((c) => c.canonical),
          ['ctrl+r']);
      expect(tuiChordsFor('prompt.kill').map((c) => c.canonical), ['ctrl+u']);
      expect(
        tuiChordsFor('prompt.answer').map((c) => c.canonical),
        containsAll(['1', '3', 'y', 'a', 'n']),
      );
    });

    test('run/app keys: interrupt, exit, submit, newline family', () {
      expect(tuiChordsFor('run.interrupt').map((c) => c.canonical), ['esc']);
      expect(tuiChordsFor('app.exit').map((c) => c.canonical), ['ctrl+c']);
      expect(tuiChordsFor('editor.send').map((c) => c.canonical), ['enter']);
      expect(
        tuiChordsFor('editor.newline').map((c) => c.canonical),
        containsAll(['shift+enter', 'alt+enter', 'ctrl+o', 'ctrl+j']),
      );
    });

    test('every chord list is non-empty and described', () {
      for (final b in kTuiKeybindings) {
        expect(b.chords, isNotEmpty, reason: '${b.action} has no chords');
        expect(b.description, isNotEmpty, reason: '${b.action} has no desc');
        expect(_scopeTitles.contains(b.scope), isTrue,
            reason: '${b.action} has an untitled scope "${b.scope}"');
      }
    });
  });

  group('hint rows', () {
    test('one formatter renders every hint row shape', () {
      expect(
        tuiKeyHintRow([
          hintAction('queue.pop', 'edit'),
          hintAction('queue.delete', 'delete'),
          hintAction('queue.steer', 'send immediately'),
        ]),
        '↑ edit · ctrl+x delete · ctrl+s send immediately',
      );
      expect(
        tuiKeyHintRow([
          hintAction('picker.navigate', 'select'),
          hintAction('picker.select', 'switch'),
          hintText('type to filter'),
          hintAction('picker.close', 'close'),
        ]),
        '↑/↓ select · enter/tab switch · type to filter · esc close',
      );
    });

    test('unregistered action fails loudly, not as a wrong hint', () {
      expect(() => hintAction('queue.deleete', 'delete'), throwsArgumentError);
    });

    test('plain text carries no escapes; styling is the caller\'s emitter',
        () {
      final row = tuiKeyHintRow([hintAction('run.interrupt', 'interrupt')]);
      expect(row, 'esc interrupt');
      expect(row.contains('\x1b'), isFalse);
    });

    test('NO_COLOR: the theme emitter renders hint rows unstyled', () {
      final controller = FaThemeController.instance;
      final wasProfile = controller.profile;
      addTearDown(() => controller.profile = wasProfile);
      controller.profile = null; // what detectThemeProfile returns under NO_COLOR
      const row = 'esc interrupt';
      expect(tuiDim(row), row);
    });
  });

  group('/help hotkeys table', () {
    test('derives every row from the registry — nothing hand-written', () {
      final table = tuiHotkeyTableLines().join('\n');
      for (final b in kTuiKeybindings) {
        expect(
          table,
          contains(b.description),
          reason: '${b.action} (${b.description}) missing from the table',
        );
        for (final chord in b.chords) {
          expect(
            table,
            contains(chord.display()),
            reason: '${b.action} chord ${chord.canonical} missing',
          );
        }
      }
    });

    test('markdown shape (TUI): sections, pipe rows, no alignment padding',
        () {
      final lines = tuiHotkeyTableLines(markdown: true);
      expect(lines.first, '**Key bindings**');
      expect(lines, contains('| Key | Action |'));
      expect(lines, contains('|-----|--------|'));
      final sections = [
        '**Composer**',
        '**Run & queue**',
        '**Pickers**',
        '**Prompt sheets**',
      ];
      final indexes = [for (final t in sections) lines.indexOf(t)];
      expect(indexes.every((i) => i >= 0), isTrue,
          reason: 'missing section: ${[
            for (var i = 0; i < sections.length; i++)
              if (indexes[i] < 0) sections[i],
          ]}');
      expect([...indexes]..sort(), indexes,
          reason: 'sections must appear in registry scope order');
      expect(
        lines.join('\n'),
        contains('| `Enter` | send message |'),
      );
      // Section titles are markdown bold, not the plain bracket form.
      expect(lines.join('\n').contains('[Key bindings]'), isFalse);
    });

    test('line-mode rendering stays plain ASCII (no markup, no escapes)', () {
      final lines = tuiHotkeyTableLines(markdown: false);
      final text = lines.join('\n');
      expect(text.contains('\x1b'), isFalse, reason: 'raw ANSI escape');
      expect(text.contains('`'), isFalse, reason: 'markdown backtick');
      expect(text.contains('**'), isFalse, reason: 'markdown bold');
      expect(text.contains('|'), isFalse, reason: 'markdown table pipe');
      expect(text.startsWith('[Key bindings]'), isTrue);
      // Fixed key column: every description starts at the same column.
      final startCols = <int>{};
      for (final line in lines) {
        for (final b in kTuiKeybindings) {
          final i = line.indexOf(b.description);
          if (i >= 0) startCols.add(i);
        }
      }
      expect(startCols.length, 1, reason: 'descriptions must align: $startCols');
    });

    test('platform-aware: darwin renders Option labels', () {
      final mac = tuiHotkeyTableLines(markdown: true, darwin: true).join('\n');
      expect(mac, contains('Option+Enter'));
      final other =
          tuiHotkeyTableLines(markdown: true, darwin: false).join('\n');
      expect(other, contains('Alt+Enter'));
      expect(other.contains('Option'), isFalse);
    });

    test('darwin flag defaults to the pinned platform global', () {
      final wasDarwin = tuiKeyHintDarwin;
      addTearDown(() => tuiKeyHintDarwin = wasDarwin);
      tuiKeyHintDarwin = true;
      expect(
        tuiHotkeyTableLines().join('\n'),
        contains('Option+Enter'),
      );
    });
  });
}

// Mirrors the private scope-title map: the guard above pins every registry
// scope to a titled section so a new scope cannot render untitled.
const _scopeTitles = {'composer', 'run', 'picker', 'prompt'};
