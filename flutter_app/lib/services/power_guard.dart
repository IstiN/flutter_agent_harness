/// Sleep-prevention guard for the app (issue #325, reworked #326): one
/// power assertion whose hold lifecycle follows the `power.hold` config —
/// per-run by default (acquired when a run goes in flight, released at
/// settle), session-held as the explicit opt-in. IO platforms read
/// `power.sleepPrevention`/`power.hold` from `~/.fah/config.yaml` and
/// build the platform runner; the stub (web) returns null — no config
/// file, no helper, no assertion.
library;

export 'power_guard_stub.dart' if (dart.library.io) 'power_guard_io.dart';
