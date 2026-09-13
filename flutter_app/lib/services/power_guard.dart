/// Sleep-prevention guard for the app (issue #325, oh-my-pi port): one
/// power assertion held while an app session is live, so long-running
/// sessions survive machine idle/sleep. IO platforms read
/// `power.sleepPrevention` from `~/.fah/config.yaml` and build the
/// platform runner; the stub (web) returns null — no config file, no
/// helper, no assertion.
library;

export 'power_guard_stub.dart' if (dart.library.io) 'power_guard_io.dart';
