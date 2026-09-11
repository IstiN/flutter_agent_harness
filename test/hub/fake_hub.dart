/// In-memory DAP/1 hub for tests — the production [LocalHub] bound to an
/// ephemeral port. All semantics live in
/// `package:flutter_agent_harness/src/hub/local_hub.dart` (reachable via
/// `lib/io.dart`); this alias keeps the suite's import surface stable.
library;

import 'package:flutter_agent_harness/src/hub/local_hub.dart';

export 'package:flutter_agent_harness/src/hub/local_hub.dart' show HubJoin;

/// The test hub: a [LocalHub] on an ephemeral port. Pass [masterSecret]
/// to stand up a PASSWORD-PROTECTED hub (the e2e uses it to prove the
/// password join path: strangers get 401 on the upgrade, holders of the
/// password connect and may enroll).
class FakeHub extends LocalHub {
  FakeHub({String? masterSecret}) : super(masterSecret: masterSecret);
}
