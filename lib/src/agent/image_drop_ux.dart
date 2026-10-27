/// Aggregated, latched image-cap drop notices — the shared UX layer both
/// hosts consume (issue #1889 R1–R5).
///
/// The registry ([ImageDropReport], `rewriteHistoryImages`) stays a
/// stateless per-request rebuild by design; this layer holds the ONLY
/// cross-request state: a latch keyed by the dropped-set identity
/// (content keys — not the per-request `[Image N]` labels — plus the
/// effective cap and the model id). One user-facing notice per meaningful
/// change: the same dropped set on any number of later requests is
/// silence; a changed set or a recovery is exactly one updated notice.
/// Never-silent is preserved where it belongs — the debug surface: hosts
/// still log every per-image drop event (`fa.log` / `AppLog`) from the
/// same report.
///
/// Pure Dart, no `dart:io` — the CLI (`agent_cli_io.dart`) and the app
/// (`AgentService` + the chat chip) both render from here, so the two
/// surfaces can never drift.
library;

import 'image_registry.dart';

/// The user-facing notice a host should surface for one meaningful
/// drop-situation change. [line] never carries raw content-key hashes
/// (R2): keys and indexes live in the detail surface ([imageSurfaceLines]).
final class ImageDropNoticeView {
  const ImageDropNoticeView._(this.line, this.prominent);

  /// The notice text (no `[images]` prefix — hosts add their own styling).
  final String line;

  /// Whether this is the prominent current-batch warning (just-attached
  /// images capped — actionable) rather than the low-key history line.
  final bool prominent;
}

/// The shared latch + last-report projection. One instance per host
/// session; constructed fresh on new-session/resume so the first
/// post-resume request re-latches exactly once (R4 — no flood on resume).
final class ImageDropUx {
  String? _latched;

  /// The most recent request's report, kept for the detail surface
  /// (`/images` and the app panel). Null before the first report.
  ImageDropReport? lastReport;

  /// Consumes one request's report. Returns the notice to surface —
  /// null when the situation is unchanged (silence) or nothing dropped
  /// and nothing was latched.
  ImageDropNoticeView? observe(ImageDropReport report) {
    lastReport = report;
    if (report.drops.isEmpty) {
      if (_latched == null) return null;
      // Recovery (cap raised / images aged out / batch under cap): one
      // all-clear transition, then silence (AC2).
      _latched = null;
      return ImageDropNoticeView._(
        'caught up — all ${report.ridingCount} window images sent '
        '(cap ${report.cap})',
        false,
      );
    }
    final key = _latchKey(report);
    if (key == _latched) return null; // same set, cap, model — silence (R1)
    _latched = key;
    return _noticeFor(report);
  }

  /// New-session/reset: the next request latches fresh.
  void reset() {
    _latched = null;
    lastReport = null;
  }

  /// Content-keyed latch identity: the dropped keys partitioned by
  /// current-vs-history (a swap between the two severities is a real
  /// change), plus the effective cap and the model id (R1, R4 — a
  /// #1750 learned-cap change is a new situation).
  String _latchKey(ImageDropReport report) {
    List<String> keys(bool fromCurrent) => [
      for (final drop in report.drops)
        if (drop.fromCurrentMessage == fromCurrent) drop.key,
    ]..sort();
    return '${report.modelId}|${report.cap}'
        '|current:${keys(true)}|history:${keys(false)}';
  }

  ImageDropNoticeView _noticeFor(ImageDropReport report) {
    final currentDrops = report.drops.where((d) => d.fromCurrentMessage).length;
    final historyDrops = report.drops.length - currentDrops;
    final budget = _budgetLabel(report);
    if (currentDrops > 0) {
      // Prominent per-batch warning with counts + remedy (R2/AC3).
      var line =
          '$currentDrops of ${report.currentImageCount} attached images '
          'were not sent to the model — cap is ${report.cap}/request'
          '$budget; see /images or images.maxPerRequest';
      if (historyDrops > 0) line += ' (+$historyDrops older images)';
      return ImageDropNoticeView._(line, true);
    }
    // Low-key aggregated history line, no content keys (R2/AC1). A
    // byte-budget drop names the budget, not just the count cap (#1916).
    return ImageDropNoticeView._(
      '$historyDrops older images not sent this turn '
      '(cap ${report.cap}$budget) — /images for details',
      false,
    );
  }
}

/// The rendered budget fragment for notice lines: empty when the report
/// carries no byte budget (#1889 constructors), ` or ~NMB image budget`
/// otherwise. Purely byte-drops read best with the budget leading, but a
/// mixed set keeps the count cap first — one label fits both (#1916).
String _budgetLabel(ImageDropReport report) => report.maxBytes > 0
    ? ' or ~${(report.maxBytes / (1024 * 1024)).toStringAsFixed(0)}MB '
          'image budget'
    : '';

/// The shared detail-surface projection (R3/AC4): the `/images` command
/// and the app panel render EXACTLY these lines. Reads the latch's last
/// report plus the live config; content-key previews (8 hex) appear only
/// here, never in the default notice lines.
List<String> imageSurfaceLines({
  required ImageDropReport? lastReport,
  required ImageRegistryConfig config,
  required String modelId,
}) {
  if (!config.enabled) {
    return [
      'images: registry disabled (images.registry: false) — requests ride '
          'unchanged, no drops, no notices',
    ];
  }
  final cap = lastReport?.cap ?? config.maxPerRequest;
  final maxBytes = lastReport?.maxBytes ?? config.maxBytesPerRequest;
  final budget = maxBytes > 0
      ? ' · ~${(maxBytes / (1024 * 1024)).toStringAsFixed(0)}MB image budget'
      : '';
  String dropWhy(ImageDropEvent drop) => switch (drop.reason) {
    ImageDropReason.bytes =>
      '(over the ~${(maxBytes / (1024 * 1024)).toStringAsFixed(0)}MB '
          'image budget)',
    ImageDropReason.count =>
      drop.fromCurrentMessage
          ? '(this message — over the cap)'
          : '(older history — cap $cap)',
  };
  final lines = <String>[
    if (lastReport == null)
      'images: no capped request yet (cap $cap/request — '
          'images.maxPerRequest)'
    else ...[
      'images: ${lastReport.registryCount} in the window, '
          '${lastReport.ridingCount} sent, '
          '${lastReport.drops.length} not sent last request',
      for (final drop in lastReport.drops)
        '  dropped [Image ${drop.index}] '
            '${drop.keyPreview}… '
            '${dropWhy(drop)}',
    ],
    'cap: $cap per request for $modelId'
        '${config.perModel[modelId] != null ? ' (images.perModel override)' : ''}'
        '$budget',
    // #1750 interplay: a cap below every configured level was learned
    // from a provider refusal; the loop re-sends under it automatically.
    if (_looksLearned(cap, config, modelId))
      'cap was learned from a provider refusal (#1750) — it applies for '
          'the rest of the run',
    'knobs: images.maxPerRequest and images.maxBytesPerRequest in '
        '~/.fah/config.yaml; images.registry: false sends everything '
        'unrewritten (no notices)',
  ];
  return lines;
}

/// Whether [cap] is below every configured level — i.e. it can only have
/// come from the #1750 runtime latch.
bool _looksLearned(int cap, ImageRegistryConfig config, String modelId) =>
    cap < config.maxPerRequest &&
    (config.perModel[modelId] == null || cap < config.perModel[modelId]!);
