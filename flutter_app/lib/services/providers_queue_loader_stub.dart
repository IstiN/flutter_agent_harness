// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web stub (issue #418): there is no `~/.fah/config.yaml` on the web
/// and the browser cannot read `FA_PROVIDERS_QUEUE`, so the loader
/// reports an UNSET queue (the legacy boot path applies), the editor
/// section is unsupported ([appProviderQueueConfigSupported] is false —
/// it renders disabled with a note), and writes throw
/// [UnsupportedError] instead of pretending to persist.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';


/// Always unset on the web: no yaml scopes and no environment access.
ProviderQueueResolution resolveAppProviderQueue({
  String? projectDir,
  String? homeDir,
}) => const ProviderQueueResolution(
  scope: ProviderQueueScope.user,
  entries: [],
  notices: [],
);

/// Web has no config yaml to write — refuse instead of pretending.
Future<String> writeAppProviderQueue(
  List<ProviderQueueEntry> entries, {
  required ProviderQueueScope layer,
  String? projectDir,
  String? homeDir,
}) => throw UnsupportedError(
  'providersQueue cannot be persisted on the web (no config yaml)',
);
