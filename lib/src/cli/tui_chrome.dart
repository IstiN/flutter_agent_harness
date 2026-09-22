/// omp transcript chrome (issue #807, parent #802 S4): message dividers,
/// the user-message bubble band, and phase-tinted tool cards — the omp
/// visual grammar ported to fa's theme roles.
///
/// Reference shapes are pinned to oh-my-pi's source (can1357/oh-my-pi,
/// MIT): the divider reproduces `chrome/message-divider.ts` exactly
/// (`ruleWidth = min(10, width - labelWidth - 1)`, blank rows around), the
/// bubble reproduces `chat/user-message.ts` (full-width `userMessageBg`
/// band, padding 1×1), and the tool card composes `render/status-line.ts`'s
/// header grammar with `render/utils.ts`'s `getStateBgColor` tints. Where
/// the issue text and omp's pinned source disagree (the issue's
/// `max(10, …)` divider formula), the SOURCE wins — parity is measured
/// against omp, not the prose.
///
/// Rules inherited from the repo's theming contract:
/// - Width/layout math runs on RAW strings (#279 E1); paint happens at
///   emit time through [FaThemeController], so a mid-session `/theme`
///   switch repaints the next frame.
/// - No profile (`NO_COLOR`/`TERM=dumb`) degrades deterministically:
///   structure (band rows, rules, glyphs) stays, every escape drops.
/// - Bubble rows are emitted PRE-STYLED (bg SGR prefix) under the same
///   contract as the live echo: the view-time markdown pass re-pads and
///   repaints them from the CURRENT theme, so stored lines never freeze
///   a stale palette.
library;

import 'package:dart_tui/src/bubbles/style.dart' show Style;
import 'tui_text_width.dart';
import 'tui_theme.dart';

/// Master switch for the omp transcript chrome (issue #807). Flipping this
/// off restores the legacy transcript bytes (`tui.classic` kill switch,
/// umbrella decision D1 — the config key lands with the config-story
/// sibling; until then tests and the classic REG guard flip this flag).
var tuiChromeEnabled = true;

/// A tool card's lifecycle phase (issue #807): picks the status glyph, the
/// title/glyph color, and the card tint — omp's `ToolCardPhase` narrowed to
/// the states fa's transcript actually renders.
enum TuiCardPhase { pending, running, success, error }

/// Status glyphs per omp's `theme/symbols.ts` defaults (`status.*`).
String tuiCardGlyph(TuiCardPhase phase) => switch (phase) {
  TuiCardPhase.pending => '⏳',
  TuiCardPhase.running => '⟳',
  TuiCardPhase.success => '✔',
  TuiCardPhase.error => '✘',
};

/// The divider's raw layout (omp `#renderDivider`): a short left rule, a
/// space, then the label. `ruleWidth = min([ruleWidth], width - labelWidth
/// - 1)`; below one rule cell the label alone renders, truncated to
/// [width]. RAW text in, RAW text out — paint via [tuiMessageDivider].
String tuiMessageDividerLayout(String label, int width, {int ruleWidth = 10}) {
  width = width < 1 ? 1 : width;
  final labelWidth = tuiTextWidth(label);
  final budget = width - labelWidth - 1;
  final rule = ruleWidth < budget ? ruleWidth : budget;
  if (rule < 1) return tuiFitWidth(label, width);
  return '${'─' * rule} $label';
}

/// The painted divider row: rule and label in the dim role (omp defaults:
/// ruleColor `dim`, transcript call sites pass muted/dim labels).
String tuiMessageDivider(String label, int width, {int ruleWidth = 10}) {
  final raw = tuiMessageDividerLayout(label, width, ruleWidth: ruleWidth);
  if (FaThemeController.instance.profile == null) return raw;
  return tuiDim(raw);
}

/// The divider block: omp caches `["", divider, ""]` — a blank row above
/// and below so turn groups breathe.
List<String> tuiMessageDividerBlock(String label, int width, {int ruleWidth = 10}) =>
    ['', tuiMessageDivider(label, width, ruleWidth: ruleWidth), ''];

/// The user-message bubble (omp `chat/user-message.ts`): the message body
/// on the full-width [TuiTheme.userMessageBg] band, one blank band row
/// above and below (padding 1×1), one leading space per content row
/// (paddingX 1). Rows are emitted PRE-STYLED so the view-time formatter
/// pads them to the then-current width and repaints from the current
/// theme; without a profile they degrade to plain rows (leading space
/// kept — the band's ghost of structure).
List<String> tuiUserBubble(List<String> contentLines) => [
  tuiUserMessageLine(''),
  for (final line in contentLines) tuiUserMessageLine(' $line'),
  tuiUserMessageLine(''),
];

/// Header fields for one tool card (omp `StatusLineOptions`, narrowed).
final class ToolCardSegments {
  const ToolCardSegments({
    required this.title,
    this.description = '',
    this.badge = '',
    this.meta = const [],
  });

  /// The tool label (`bash`, `read`, …) — painted in the accent role.
  final String title;

  /// The human detail (command, path, question) — muted, absorbs squeeze.
  final String description;

  /// Bracketed status badge (e.g. `exit 1`) — painted in the phase color.
  final String badge;

  /// Dot-joined dim meta fragments (elapsed, line counts).
  final List<String> meta;
}

/// The painted card header (omp `renderStatusLine`):
/// `glyph title: description [badge] meta·meta`, fitted to [width] cells.
/// Squeeze drops from the tail — meta first, then the badge, then the
/// description ellipsizes; the glyph+title always fit (ellipsized only
/// past that).
String tuiToolCardHeader(
  ToolCardSegments s,
  TuiCardPhase phase,
  int width,
) {
  final c = FaThemeController.instance;
  final glyph = tuiCardGlyph(phase);
  final styled = c.profile != null;
  String paint(String piece, String Function(String) role) =>
      styled ? role(piece) : piece;

  var head = '$glyph ${s.title}';
  if (tuiTextWidth(head) > width) head = tuiFitWidth(head, width);
  final headRaw = paint(
        glyph,
        (g) => c.border(_phaseStyle(c, phase), g),
      ) +
      paint(' ${s.title}', (t) => c.accent(t));
  var remain = width - tuiTextWidth(head);

  final descRaw = s.description.isEmpty ? '' : ': ${s.description}';
  final badgeRaw = s.badge.isEmpty ? '' : ' [${s.badge}]';
  final meta = s.meta.where((m) => m.trim().isNotEmpty).toList();
  final metaRaw = meta.isEmpty ? '' : ' ${meta.join('·')}';

  var tail = descRaw;
  if (tuiTextWidth('$descRaw$badgeRaw$metaRaw') <= remain) {
    tail = '$descRaw$badgeRaw$metaRaw';
  } else if (tuiTextWidth('$descRaw$badgeRaw') <= remain) {
    tail = '$descRaw$badgeRaw';
  } else if (tuiTextWidth(descRaw) > remain) {
    tail = remain > 0 ? tuiFitWidth(descRaw, remain) : '';
  }

  return headRaw +
      paint(tail, (t) {
        // The tail mixes muted description, phase badge and dim meta; the
        // muted role paints the whole fitted run (omp's description role —
        // badge/meta deviations are the first squeeze victims anyway).
        return c.toolOutput(t);
      });
}

/// The card tint's raw background SGR prefix ('' without a profile).
///
/// success/error map to the existing [TuiTheme.toolSuccessBg]/
/// [TuiTheme.toolErrorBg] tints. pending/running ride [TuiTheme.highlight]
/// until S1 lands the `toolPendingBg` role — the swap is one line here
/// (`_current.toolPendingBg`), documented on the S1 seam.
String tuiCardTintSgr(TuiCardPhase phase) {
  final c = FaThemeController.instance;
  if (c.profile == null) return '';
  final tint = switch (phase) {
    TuiCardPhase.success => c.current.toolSuccessBg,
    TuiCardPhase.error => c.current.toolErrorBg,
    _ => c.current.highlight, // ponytail: S1's toolPendingBg completes this
  };
  return c.sgrPrefix(tint);
}

Style _phaseStyle(FaThemeController c, TuiCardPhase phase) => switch (phase) {
  TuiCardPhase.success => c.current.success,
  TuiCardPhase.error => c.current.error,
  TuiCardPhase.pending => c.current.muted,
  TuiCardPhase.running => c.current.accent,
};

final _sgrEscapeRe = RegExp(r'\x1b\[[0-9;]*m');

/// The bordered tool card (omp's generic tinted card + status header):
/// the header row, up to [maxDetailLines] tinted detail rows padded to
/// [width], and a `… N more lines` footer when detail was cut (omp's
/// `buildStatusFooter` hidden-line count, hint suffix dropped — fa cards
/// are not ctrl+o-expandable yet). Each row carries the phase tint as a
/// background; without a profile the card degrades to plain rows.
List<String> tuiToolCard(
  ToolCardSegments segments,
  TuiCardPhase phase,
  int width, {
  List<String> detailLines = const [],
  int maxDetailLines = 3,
}) {
  final tint = tuiCardTintSgr(phase);
  // Padding measures VISIBLE cells — the styled row's escapes are
  // zero-width at the terminal (same contract as the view-time echo pad).
  final paintRow = tint.isEmpty
      ? (String row) => row
      : (String row) {
          final pad = width - tuiTextWidth(row.replaceAll(_sgrEscapeRe, ''));
          return '$tint$row${pad > 0 ? ' ' * pad : ''}\x1b[0m';
        };
  return [
    paintRow(tuiToolCardHeader(segments, phase, width)),
    ..._previewLines(detailLines, maxDetailLines).map(paintRow),
  ];
}

/// Collapses [lines] to at most [maxLines] rows, appending omp's
/// `… N more lines` footer when something was cut.
List<String> _previewLines(List<String> lines, int maxLines) {
  if (lines.length <= maxLines) return lines;
  return [
    ...lines.take(maxLines),
    '… ${lines.length - maxLines} more lines',
  ];
}
