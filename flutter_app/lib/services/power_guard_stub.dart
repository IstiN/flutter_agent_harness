/// Web stub: no `~/.fah/config.yaml` and no helper process — the app
/// runs without sleep prevention.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Always null on the web.
PowerAssertionController? createAppPowerAssertion() => null;
