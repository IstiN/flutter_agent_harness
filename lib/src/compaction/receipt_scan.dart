// gh-2237 REG-1 — the silent zero-pass auto-compact loop's regression
// signature: two consecutive `auto-compact start` diagnostics with no
// intervening terminal receipt. The field incident showed six starts over
// 21 minutes with tokens GROWING and zero pass/done receipts — the
// engine's collapsed basis under-trigger-exited receipt-free every time.
//
// Pure scanner over diagnostic-log lines (no I/O) so any CI job (and the
// E2E soak replay) can fail on the signature. A CI job running this
// detector over a run's diagnostic log blocks merge when it fires.

/// Whether [lines] contain the gh-2237 defect signature: an
/// `auto-compact start` receipt never followed by a terminal receipt
/// before the next `auto-compact start` (or the end of the log).
///
/// Terminal receipts — the lines that close a started compaction:
/// - `auto-compact done …` (any pass count, including `passes=0`);
/// - `auto-compact pass N …` (any variant — success, FAILED, no-op,
///   local-trim; a receipted pass ran, so the run is speaking);
/// - `compact retry …` (transient-error receipt — the run is speaking).
///
/// A trailing start at the end of the log also fires: a log cut mid-run
/// by a kill is indistinguishable from the defect's silence, and AC2's
/// contract ("a started compaction can never end in silence") fails both
/// ways.
bool compactionStartWithoutTerminalReceipt(Iterable<String> lines) {
  var startOpen = false;
  for (final line in lines) {
    if (line.contains('auto-compact start')) {
      if (startOpen) return true;
      startOpen = true;
    } else if (startOpen && _isTerminalReceipt(line)) {
      startOpen = false;
    }
  }
  return startOpen;
}

bool _isTerminalReceipt(String line) =>
    line.contains('auto-compact done') ||
    line.contains('auto-compact pass') ||
    line.contains('compact retry');
