/// Web stub: no `~/.fah/config.yaml` on this platform — the app's own
/// stores keep owning every section (issue #1078 E2: absent config never
/// blocks boot, and a note about a file that cannot exist here would be
/// noise).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Always null on the web: there is no config file to read.
AppFahSections? loadAppFahConfig({String? projectDir, String? homeDir}) =>
    null;

/// Always null on the web: there is no process environment to read
/// (issue #1036) — the provider-timeout env override is desktop-only.
String? Function() faProviderTimeoutSecondsEnv = () => null;
