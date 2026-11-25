/// `selectCompactionMode` (GOAL #2394 D4 — AC1): the EXHAUSTIVE mode
/// table of a compaction run. No other mode exists and no outcome of a
/// run switches mode (I9 — no automatic fallbacks):
///
/// | setting      | S0 valid | separate digest role | mode        |
/// |--------------|----------|----------------------|-------------|
/// | `classic`    |    —     |          —           | `classic`   |
/// | `structured` |   yes    |         no           | `merged`    |
/// | `structured` |   any    |         yes          | `standalone`|
/// | `structured` |   no     |         no           | `standalone`|
///
/// `merged` is the hand-over call over the S0 prefix; `standalone` is the
/// today's digest under `affine` routing (a host that split the digest
/// onto a cheap smol role keeps it — not a fallback, the host's choice);
/// `classic` is the user's setting. Pure.
library;

import 'compaction.dart' show CompactionEngine;

/// How a compaction run talks to the model.
enum CompactionMode {
  /// `compaction.engine: classic` — the lossy prefix compactor, no tags,
  /// no merged call (byte-identical to the pre-#2394 classic path).
  classic,

  /// ONE hand-over call over the last main request (S0) + instruction.
  merged,

  /// The standalone digest (today's checkpoint call) — only when the host
  /// configured a separate digest/smol role or no valid S0 exists.
  standalone,
}

/// The mode table (D4). [snapshotValid] = a request snapshot exists and is
/// valid for the session's model; [separateDigestRole] = the host wired a
/// digest model that differs from the session's main model.
CompactionMode selectCompactionMode({
  required CompactionEngine engine,
  required bool snapshotValid,
  required bool separateDigestRole,
}) {
  if (engine == CompactionEngine.classic) return CompactionMode.classic;
  if (snapshotValid && !separateDigestRole) return CompactionMode.merged;
  return CompactionMode.standalone;
}
