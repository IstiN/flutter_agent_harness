/// Run-unique loopback port claims for tests (gh-936).
///
/// The old allocation shape — bind an ephemeral port, close it, hand the
/// NUMBER to the real consumer later ("bind-close dance") — races any
/// other process allocating ephemeral ports in the same window. Two
/// overlapping runs of the same suite started together walk the OS's
/// sequential ephemeral counter in lockstep, so they pick the SAME port,
/// and the loser hard-fails on bind (or, worse, dials a FOREIGN hub).
///
/// [claimTestPort] hands out numbers from a per-process random slice of
/// a range BELOW the OS ephemeral floors (Linux 32768+, macOS 49152+),
/// so the only way to collide is for two processes to draw the same
/// slice (1 in [testPortSlices]) AND the same slot within it. Combined
/// with the hub's shared bind + retry (`LocalHub.start`, gh-936) the
/// residual collision degrades calmly instead of reding a leg.
///
/// The claim binds NOTHING — it only reserves a number per process.
/// Consumers that need the port to be genuinely DEAD (a "no hub here"
/// probe) should verify refusal with a client connect; consumers that
/// bind it themselves get the hub's shared/retry safety net.
library;

import 'dart:math';

/// The lowest port the allocator hands out (above the privileged range).
const int testPortBase = 21000;

/// Ports per slice: enough for any one suite file's claims, small enough
/// that two same-slice processes rarely reach the same offset.
const int testPortSliceSpan = 64;

/// How many disjoint slices the range offers (1-in-this odds of two
/// processes drawing the same slice).
const int testPortSlices = 220;

int? _sliceBase;
int _next = 0;
final Random _random = Random.secure();

/// Claims the next test port for this process. Sequential within the
/// process's slice; wraps inside the slice after [testPortSliceSpan]
/// claims (a wrap reuses this process's own early claims — safe once
/// their consumers stopped, and no suite claims that many).
int claimTestPort() {
  final base = _sliceBase ??= testPortBase +
      _random.nextInt(testPortSlices) * testPortSliceSpan;
  if (_next >= testPortSliceSpan) _next = 0;
  return base + _next++;
}
