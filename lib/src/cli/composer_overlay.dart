// Composer completion overlay for the FaTui model (issue #275): the
// cursor-anchored token scan, fuzzy ranking with match highlighting, and
// the per-keystroke menu update. Extracted from fa_tui.dart to keep the
// model file under the 2800-line gate; everything here is pure — it only
// touches FaTuiModel's public surface (copyWith, inputText, cursor,
// callbacks) so it can live in a separate library.
library;

import 'fuzzy_matcher.dart';
import 'fa_tui.dart';
import 'tui_repl.dart' show MenuItem;

/// Same indigo accent as fa_tui's `_accent2Plain` (site palette accent-2).
String _accent2Plain(String s) => '\x1b[38;2;129;140;248m$s\x1b[0m';

/// `/models <filter>` prefix — allocated once: the menu update runs on
/// EVERY keystroke and must not recompile this per keypress.
final RegExp _modelsFilterPrefix = RegExp(r'^/models\s+(.*)$');

/// Recomputes the composer overlay for [model]'s current input and cursor.
FaTuiModel updateMenuForInput(FaTuiModel model, FaTuiCallbacks callbacks) {
  final text = model.inputText;

  // `/models <filter>` opens the picker with a pre-filled filter.
  final filterMatch = _modelsFilterPrefix.firstMatch(text);
  if (filterMatch != null) {
    final filter = filterMatch.group(1)!;
    return model.copyWith(
      menuOpen: true,
      menuModelMode: true,
      modelFilter: filter,
      menuItems: callbacks.buildModelMenu(filter),
      menuSelected: 0,
      pickerId: 'models',
      pickerTitle: '',
      menuTokenStart: -1,
    );
  }

  if (text == '/models') {
    return model.copyWith(
      menuOpen: true,
      menuModelMode: true,
      modelFilter: '',
      menuItems: callbacks.buildModelMenu(''),
      menuSelected: 0,
      pickerId: 'models',
      pickerTitle: '',
      menuTokenStart: -1,
    );
  }
  if (text.startsWith('/')) {
    final items = fuzzyMenu(callbacks.buildSlashMenu(text), text);
    if (items.isEmpty) {
      return model.copyWith(menuOpen: false, menuTokenStart: -1);
    }
    return model.copyWith(
      menuOpen: true,
      menuModelMode: false,
      menuItems: items,
      menuSelected: 0,
      menuTokenStart: 0,
    );
  }
  // `@token` and shell words on a `!` line complete workspace paths
  // (issue #275 AC1): fuzzy-ranked, spliced back into place on accept.
  final token = completionToken(text, model.cursor);
  if (token != null) {
    final candidates = callbacks.pathCandidates?.call(token.$2) ?? const [];
    final items = fuzzyMenu([
      for (final path in candidates)
        MenuItem(key: path, label: path, group: 'paths'),
    ], token.$2);
    if (items.isEmpty) {
      return model.copyWith(menuOpen: false, menuTokenStart: -1);
    }
    return model.copyWith(
      menuOpen: true,
      menuModelMode: false,
      menuItems: items,
      menuSelected: 0,
      menuTokenStart: token.$1,
    );
  }
  return model.copyWith(menuOpen: false, menuTokenStart: -1);
}

/// The completion token ending at [cursor]: an `@`-token (`@` at line
/// start or after whitespace; the fragment may be empty → browse-all) or
/// the trailing shell word of a `!` line. Returns (tokenStart, fragment)
/// or null when nothing completes here.
(int, String)? completionToken(String text, int cursor) {
  if (cursor > text.length) cursor = text.length;
  final before = text.substring(0, cursor);
  bool space(String ch) => ch == ' ' || ch == '\t';
  final at = before.lastIndexOf('@');
  if (at >= 0 && (at == 0 || space(before[at - 1]))) {
    final fragment = before.substring(at + 1);
    if (!fragment.contains(RegExp(r'[\s@]'))) {
      return (at + 1, fragment);
    }
  }
  if (text.startsWith('!') && cursor >= 1 && !space(before[cursor - 1])) {
    var start = cursor;
    while (start > 1 && !space(before[start - 1])) {
      start--;
    }
    // start >= 1: the leading '!' is never part of the completed token.
    final fragment = before.substring(start);
    if (fragment.isNotEmpty) return (start, fragment);
  }
  return null;
}

/// Fuzzy-ranks [items] by how well [needle] matches their label, keeps
/// the best [limit], and rewrites labels with the matched runes
/// highlighted (issue #275 AC1: scoring, grouping, highlight).
List<MenuItem> fuzzyMenu(List<MenuItem> items, String needle, {int limit = 32}) {
  if (needle.isEmpty || needle == '/') return items.take(limit).toList();
  final scored = <(FuzzyMatch, MenuItem)>[];
  for (final item in items) {
    final match = scoreFuzzy(item.label, needle);
    if (match != null) scored.add((match, item));
  }
  scored.sort((a, b) => a.$1.compareTo(b.$1));
  return [
    for (final (match, item) in scored.take(limit))
      MenuItem(
        key: item.key,
        label: highlightMatch(item.label, match.indices),
        description: item.description,
        group: item.group.isEmpty ? groupOf(item) : item.group,
      ),
  ];
}

/// Menu section for a builder item: skill invocations vs commands.
String groupOf(MenuItem item) =>
    item.key.startsWith('/skill:') ? 'skills' : 'commands';

/// Wraps the matched [indices] runes of [label] in the indigo accent so
/// the user sees WHY each candidate matched. (Command/skill labels are
/// ASCII; paths may be wide-char — the per-code-unit scan is fine because
/// indices come from the same string.)
String highlightMatch(String label, List<int> indices) {
  if (indices.isEmpty) return label;
  final matched = {for (final i in indices) i};
  final b = StringBuffer();
  for (var i = 0; i < label.length; i++) {
    final ch = label[i];
    b.write(matched.contains(i) ? _accent2Plain(ch) : ch);
  }
  return b.toString();
}
