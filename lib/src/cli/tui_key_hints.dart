/// The keyHint grammar (omp `chrome/keybinding-hints.ts` + `hotkeys-markdown.ts`
/// parity, issue #809): ONE registry of TUI keybindings — chords, scopes,
/// descriptions — feeds every hint row (composer queue footer, picker footers,
/// prompt-sheet footers) and the `/help hotkeys` table. No per-surface
/// hand-formatted `key desc · key desc` strings anywhere else.
///
/// Pure Dart (no `dart:io`): the web-safe TUI stub compiles this file through
/// `tui_prompt.dart`. Platform awareness rides [tuiKeyHintDarwin], pinned by
/// the CLI entry point and overridable in tests.
library;

import 'dart:math' as math;

import 'tui_text_width.dart';

/// A key chord in canonical form: lowercase fa keystroke id with `+`-joined
/// modifiers (`ctrl+x`, `alt+enter`), or the bare key (`enter`, `↑`, `1`).
final class TuiChord {
  final String canonical;

  const TuiChord(this.canonical);

  /// Normalizes free-form chord text: `Ctrl-X`, `shift enter`, `↑`,
  /// `Option+P` and `ctrl+x` all parse to the same chord — per part, so
  /// modified display spellings (`ctrl+↑`, `ctrl+pgdn`) normalize too.
  factory TuiChord.parse(String text) {
    final raw = text.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '+');
    final parts = [
      for (final p in raw.split('+')) _glyphFromDisplay[p] ?? _keyAliases[p] ?? p,
    ]..removeWhere((p) => p.isEmpty);
    return TuiChord(parts.join('+'));
  }

  /// Compact hint-row form (`ctrl+x`, the `↑/↓` building block) — lowercase,
  /// arrows as glyphs, matching the historical hint-row text byte for byte.
  String get hint => _glyphs[canonical] ?? canonical;

  /// Table form: modifier/key labels cased for prose (`Ctrl+X`, `Home`,
  /// `Option+Enter` on darwin).
  String display({bool darwin = false}) {
    final parts = canonical.split('+');
    final key = parts.last;
    final mods = _modifierLabels(darwin);
    final labels = [
      for (final m in parts.take(parts.length - 1)) mods[m] ?? _titleKey(m),
      _keyLabels[key] ?? _titleKey(key),
    ];
    return labels.join('+');
  }

  @override
  bool operator ==(Object other) =>
      other is TuiChord && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => canonical;
}

/// Arrow glyphs render as themselves in every form — they ARE the label.
const _glyphs = {
  'up': '↑',
  'down': '↓',
  'left': '←',
  'right': '→',
};

/// Display glyph → canonical id (`↑` → `up`), so chord text parses like it
/// displays — bare or modified (`ctrl+↑`).
final _glyphFromDisplay = {
  for (final e in _glyphs.entries) e.value: e.key,
};

/// Free-text spellings that normalize to canonical ids (`Option+P` →
/// `alt+p`, `PgDn` → `pgdown`).
const _keyAliases = {
  'option': 'alt',
  'opt': 'alt',
  'cmd': 'super',
  'command': 'super',
  'pgdn': 'pgdown',
};

Map<String, String> _modifierLabels(bool darwin) => {
      'ctrl': 'Ctrl',
      'alt': darwin ? 'Option' : 'Alt',
      'shift': 'Shift',
      'meta': 'Meta',
      'super': darwin ? 'Cmd' : 'Super',
    };

const _keyLabels = {
  'enter': 'Enter',
  'esc': 'Esc',
  'tab': 'Tab',
  'space': 'Space',
  'backspace': 'Backspace',
  'delete': 'Delete',
  'home': 'Home',
  'end': 'End',
  'pgup': 'PgUp',
  'pgdown': 'PgDn',
  'up': '↑',
  'down': '↓',
  'left': '←',
  'right': '→',
};

String _titleKey(String k) =>
    k.length <= 1 ? k.toUpperCase() : k[0].toUpperCase() + k.substring(1);

/// One registered TUI keybinding. [scope] groups the `/help hotkeys` table;
/// [action] is the stable id hint rows reference (`queue.delete`).
final class TuiKeybinding {
  final String action;
  final String scope;
  final List<TuiChord> chords;
  final String description;

  const TuiKeybinding(this.action, this.scope, this.chords, this.description);
}

/// The fa TUI keybinding registry — the single source behind every hint row
/// and the `/help hotkeys` table (issue #809 AC6.2: adding a keybinding here
/// updates the table; nothing hand-written to keep in sync).
///
/// Scopes in table order: `composer`, `run` (run & queue), `picker`, `prompt`.
const kTuiKeybindings = <TuiKeybinding>[
  // ── Composer / editor ────────────────────────────────────────────────
  TuiKeybinding('editor.send', 'composer', [TuiChord('enter')], 'send message'),
  TuiKeybinding(
    'editor.newline',
    'composer',
    [
      TuiChord('shift+enter'),
      TuiChord('alt+enter'),
      TuiChord('ctrl+o'),
      TuiChord('ctrl+j'),
    ],
    'insert newline',
  ),
  TuiKeybinding('editor.submit', 'composer', [TuiChord('ctrl+s')],
      'submit without Shift+Enter support'),
  TuiKeybinding('editor.lineStart', 'composer',
      [TuiChord('ctrl+a'), TuiChord('home')], 'start of line'),
  TuiKeybinding('editor.lineEnd', 'composer', [TuiChord('ctrl+e'),
      TuiChord('end')], 'end of line'),
  TuiKeybinding('editor.cursor', 'composer', [TuiChord('left'),
      TuiChord('right')], 'move cursor'),
  TuiKeybinding('editor.wordBack', 'composer', [TuiChord('alt+left')],
      'one word back'),
  TuiKeybinding('editor.wordForward', 'composer', [TuiChord('alt+right')],
      'one word forward'),
  TuiKeybinding('editor.killToLineStart', 'composer', [TuiChord('ctrl+u')],
      'kill to line start'),
  TuiKeybinding('editor.killToLineEnd', 'composer', [TuiChord('ctrl+k')],
      'kill to line end'),
  TuiKeybinding('editor.killWordBack', 'composer', [TuiChord('ctrl+w')],
      'delete word before cursor'),
  TuiKeybinding('editor.deleteForward', 'composer', [TuiChord('delete')],
      'delete character forward'),
  TuiKeybinding('editor.yank', 'composer', [TuiChord('ctrl+y')],
      'yank last kill (repeat walks the ring)'),
  TuiKeybinding('editor.transpose', 'composer', [TuiChord('ctrl+t')],
      'transpose characters'),
  TuiKeybinding('editor.undo', 'composer', [TuiChord('ctrl+z')], 'undo edit'),
  TuiKeybinding('editor.historyPrev', 'composer', [TuiChord('up')],
      'previous sent message (idle) / edit last queued row (busy)'),
  TuiKeybinding('editor.historyNext', 'composer', [TuiChord('down')],
      'next sent message'),
  TuiKeybinding('editor.scroll', 'composer',
      [TuiChord('pgup'), TuiChord('pgdown')], 'scroll transcript'),
  TuiKeybinding('editor.complete', 'composer', [TuiChord('tab')],
      'path completion / accept menu item'),
  TuiKeybinding('editor.pasteImage', 'composer', [TuiChord('ctrl+v')],
      'attach clipboard image'),
  TuiKeybinding('editor.commands', 'composer', [TuiChord('/')],
      'slash commands'),
  TuiKeybinding('editor.shell', 'composer', [TuiChord('!')],
      'run shell command'),
  // ── Run & queue ──────────────────────────────────────────────────────
  TuiKeybinding('run.interrupt', 'run', [TuiChord('esc')],
      'abort the streaming run'),
  TuiKeybinding('app.exit', 'run', [TuiChord('ctrl+c')], 'quit fa'),
  TuiKeybinding('run.queue', 'run', [TuiChord('enter')],
      'queue message while a run streams'),
  TuiKeybinding('queue.pop', 'run', [TuiChord('up')],
      'pop last queued message for editing'),
  TuiKeybinding('queue.delete', 'run', [TuiChord('ctrl+x')],
      'delete last queued message'),
  TuiKeybinding('queue.steer', 'run', [TuiChord('ctrl+s')],
      'steer queued messages into the running turn'),
  // ── Pickers ──────────────────────────────────────────────────────────
  TuiKeybinding('picker.navigate', 'picker',
      [TuiChord('up'), TuiChord('down')], 'move selection'),
  TuiKeybinding('picker.select', 'picker',
      [TuiChord('enter'), TuiChord('tab')], 'accept selection'),
  TuiKeybinding('picker.close', 'picker', [TuiChord('esc')], 'close picker'),
  TuiKeybinding('picker.filter', 'picker', [TuiChord('type')],
      'filter the list'),
  // ── Prompt sheets (ask / approval / secret) ──────────────────────────
  TuiKeybinding('prompt.confirm', 'prompt', [TuiChord('enter')], 'confirm'),
  TuiKeybinding('prompt.cancel', 'prompt', [TuiChord('esc')],
      'cancel / deny'),
  TuiKeybinding('prompt.nextField', 'prompt', [TuiChord('tab')],
      'next field / free text'),
  TuiKeybinding('prompt.reveal', 'prompt', [TuiChord('ctrl+r')],
      'show / hide secret value'),
  TuiKeybinding('prompt.kill', 'prompt', [TuiChord('ctrl+u')],
      'clear note / name field'),
  TuiKeybinding('prompt.selector', 'prompt',
      [TuiChord('up'), TuiChord('down')], 'move selector'),
  TuiKeybinding(
    'prompt.answer',
    'prompt',
    [
      TuiChord('1'),
      TuiChord('2'),
      TuiChord('3'),
      TuiChord('y'),
      TuiChord('a'),
      TuiChord('n'),
    ],
    'answer approval',
  ),
];

/// Chords registered for [action] (`queue.delete`); empty when unregistered.
List<TuiChord> tuiChordsFor(String action) {
  for (final b in kTuiKeybindings) {
    if (b.action == action) return b.chords;
  }
  return const [];
}

/// Compact join for a chord list: `↑/↓`, `enter/tab`.
String formatKeyHints(List<TuiChord> chords) =>
    [for (final c in chords) c.hint].join('/');

/// One hint-row segment: the chords to show (from a registry [action] via
/// [hintAction], raw chords, or keyless prose) plus the description text.
typedef TuiKeyHint = ({List<TuiChord> keys, String description});

/// Segment whose chords come from the registry — the omp `keyHint(action,
/// description)` shape. Throws on an unregistered action: a typo must fail
/// loudly at construction, not render a wrong hint.
TuiKeyHint hintAction(String action, String description) {
  final chords = tuiChordsFor(action);
  if (chords.isEmpty) {
    throw ArgumentError.value(action, 'action', 'unregistered keybinding');
  }
  return (keys: chords, description: description);
}

/// Segment from explicit chords (state-split bindings like `↑`).
TuiKeyHint hintChords(List<TuiChord> keys, String description) =>
    (keys: keys, description: description);

/// Keyless prose segment (`type to filter`).
TuiKeyHint hintText(String text) => (keys: const [], description: text);

/// The hint row text: `key desc · key desc` (compact lowercase chords),
/// the single formatter behind every TUI hint surface. Plain text — callers
/// style it through the theme emitters (`tuiDim`) at write time, which also
/// owns the `NO_COLOR` / profile degradation (rule #279).
String tuiKeyHintRow(List<TuiKeyHint> hints) => [
      for (final h in hints)
        h.keys.isEmpty
            ? h.description
            : '${formatKeyHints(h.keys)} ${h.description}',
    ].join(' · ');

/// Platform pin for chord display: true = darwin labels (`Option`, `Cmd`).
/// The CLI entry point sets it from `Platform.isMacOS` at boot; tests pass
/// [tuiHotkeyTableLines]' `darwin` explicitly.
bool tuiKeyHintDarwin = false;

const _scopeTitles = {
  'composer': 'Composer',
  'run': 'Run & queue',
  'picker': 'Pickers',
  'prompt': 'Prompt sheets',
};

/// The `/help hotkeys` table, generated from [kTuiKeybindings] (issue #809
/// AC6.2). Two renderings of the same rows:
///
/// - [markdown] `true` (TUI): markdown shape — `**Scope**` headers and
///   `` | `Key` | Action | `` rows — the transcript markdown renderer turns
///   it into a box-grid table with theme colors (which degrade under
///   `NO_COLOR`).
/// - `false` (line mode): plain ASCII — `[Scope]` headers and a fixed
///   key column, no markup, no escapes.
///
/// Pass [bindings] to render a custom row set (test seam); defaults to
/// [kTuiKeybindings].
List<String> tuiHotkeyTableLines({
  bool markdown = false,
  bool? darwin,
  List<TuiKeybinding> bindings = kTuiKeybindings,
}) {
  final isDarwin = darwin ?? tuiKeyHintDarwin;
  final rows = [
    for (final b in bindings)
      (
        binding: b,
        keys: [for (final c in b.chords) c.display(darwin: isDarwin)].join(' / '),
      ),
  ];

  final lines = <String>[
    markdown ? '**Key bindings**' : '[Key bindings]',
    '',
  ];
  // Plain mode pads the key column to the widest entry of the whole table —
  // computed up front in display cells (a wide key under-pads its row when
  // measured in UTF-16 units; ambiguous-width arrows stay terminal-dependent
  // in line mode by design), so descriptions align across sections.
  // `tuiPadRight` uses the same measurement.
  final keyColumn =
      rows.fold<int>(0, (w, r) => math.max(w, tuiTextWidth(r.keys)));
  var lastScope = '';
  for (final r in rows) {
    if (r.binding.scope != lastScope) {
      lastScope = r.binding.scope;
      final title = _scopeTitles[lastScope] ?? lastScope;
      lines
        ..add('')
        ..add(markdown ? '**$title**' : title);
      if (markdown) {
        lines
          ..add('| Key | Action |')
          ..add('|-----|--------|');
      }
    }
    lines.add(
      markdown
          ? '| `${r.keys}` | ${r.binding.description} |'
          : '  ${tuiPadRight(r.keys, keyColumn)}  ${r.binding.description}',
    );
  }
  return lines;
}
