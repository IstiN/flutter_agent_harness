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
import 'ansi_markdown.dart' show AnsiMarkdown;
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
/// [width]. RAW text in, RAW text out — callers own the paint role
/// (the replay resume boundary paints it dim).
String tuiMessageDividerLayout(String label, int width, {int ruleWidth = 10}) {
  width = width < 1 ? 1 : width;
  final labelWidth = tuiTextWidth(label);
  final budget = width - labelWidth - 1;
  final rule = ruleWidth < budget ? ruleWidth : budget;
  if (rule < 1) return tuiFitWidth(label, width);
  return '${'─' * rule} $label';
}

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
  final styled = c.profile != null;
  String paint(String piece, String Function(String) role) =>
      styled ? role(piece) : piece;

  // Fit FIRST, paint second — painting an unfitted run would emit a head
  // wider than the card (the fitted/unfitted drift the UT pins).
  final (glyph, title) = _fitCardHead(s.title, tuiCardGlyph(phase), width);
  final headRaw = paint(glyph, (g) => c.border(_phaseStyle(c, phase), g)) +
      paint(title.isEmpty ? '' : ' $title', (t) => c.accent(t));
  final remain = width - tuiTextWidth('$glyph $title');

  final tail = _squeezeCardTail(s, remain);
  return headRaw + _paintCardTail(c, phase, tail, paint);
}

/// The width-fitted head: the glyph plus the title ellipsized to the
/// remaining budget (empty title when even the glyph can't fit).
(String, String) _fitCardHead(String title, String glyph, int width) {
  final titleBudget = width - tuiTextWidth(glyph) - 1;
  if (titleBudget < 1) return (tuiFitWidth(glyph, width), '');
  if (tuiTextWidth(title) > titleBudget) {
    return (glyph, tuiFitWidth(title, titleBudget));
  }
  return (glyph, title);
}

/// The fitted tail segments, decided on RAW widths. Squeeze drops from
/// the tail — meta first, then the badge, then the description
/// ellipsizes.
(String, String, String) _squeezeCardTail(ToolCardSegments s, int remain) {
  final descRaw = s.description.isEmpty ? '' : ': ${s.description}';
  final badgeRaw = s.badge.isEmpty ? '' : ' [${s.badge}]';
  final meta = s.meta.where((m) => m.trim().isNotEmpty).toList();
  final metaRaw = meta.isEmpty ? '' : ' ${meta.join('·')}';

  if (tuiTextWidth('$descRaw$badgeRaw$metaRaw') <= remain) {
    return (descRaw, badgeRaw, metaRaw);
  }
  if (tuiTextWidth('$descRaw$badgeRaw') <= remain) {
    return (descRaw, badgeRaw, '');
  }
  if (tuiTextWidth(descRaw) > remain) {
    return (remain > 0 ? tuiFitWidth(descRaw, remain) : '', '', '');
  }
  return (descRaw, '', '');
}

/// Paints the surviving tail in each piece's documented role
/// (ToolCardSegments): description muted — bright in the error phase,
/// #366's keep-failure-text-bright — badge in the phase color, meta dim.
String _paintCardTail(
  FaThemeController c,
  TuiCardPhase phase,
  (String, String, String) tail,
  String Function(String, String Function(String)) paint,
) {
  final (desc, badge, meta) = tail;
  return (desc.isEmpty
          ? ''
          : paint(
              desc,
              phase == TuiCardPhase.error
                  ? (t) => c.error(t)
                  : (t) => c.toolOutput(t),
            )) +
      (badge.isEmpty
          ? ''
          : paint(badge, (t) => c.border(_phaseStyle(c, phase), t))) +
      (meta.isEmpty ? '' : paint(meta, (t) => c.muted(t)));
}

/// The card tint's raw background SGR prefix ('' without a profile).
///
/// success/error/pending map to the [TuiTheme.toolSuccessBg]/
/// [TuiTheme.toolErrorBg]/[TuiTheme.toolPendingBg] tints.
String tuiCardTintSgr(TuiCardPhase phase) {
  final c = FaThemeController.instance;
  if (c.profile == null) return '';
  return switch (phase) {
    TuiCardPhase.success => c.toolSuccessBgSgr(),
    TuiCardPhase.error => c.toolErrorBgSgr(),
    _ => c.toolPendingBgSgr(),
  };
}

Style _phaseStyle(FaThemeController c, TuiCardPhase phase) => switch (phase) {
  TuiCardPhase.success => c.cardSuccessStyle,
  TuiCardPhase.error => c.cardErrorStyle,
  TuiCardPhase.pending => c.cardPendingStyle,
  TuiCardPhase.running => c.cardRunningStyle,
};

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
  // Detail rows are width-fitted BEFORE painting — an overlong line would
  // break the card's right edge (paintRow only pads short rows). The
  // header is already composed to [width] and is STYLED — fitting it with
  // [tuiFitWidth] (raw-string contract) would chop mid-SGR.
  // Padding measures VISIBLE cells — the styled row's escapes are
  // zero-width at the terminal (same contract as the view-time echo pad).
  String paintRow(String row, {bool fit = true}) {
    final fitted = fit ? tuiFitWidth(row, width) : row;
    if (tint.isEmpty) return fitted;
    final pad = width - tuiTextWidth(
      fitted.replaceAll(AnsiMarkdown.ansiSgrPattern, ''),
    );
    return '$tint$fitted${pad > 0 ? ' ' * pad : ''}\x1b[0m';
  }

  return [
    paintRow(tuiToolCardHeader(segments, phase, width), fit: false),
    ..._previewLines(detailLines, maxDetailLines).map(
      (line) => paintRow(line),
    ),
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
