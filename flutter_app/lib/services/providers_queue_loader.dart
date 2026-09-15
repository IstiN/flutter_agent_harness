// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Resolves (and persists) the provider queue for the app (issue #418) —
/// the same three scopes the CLI honors: `FA_PROVIDERS_QUEUE` (read-only
/// in the app: a sandboxed UI cannot edit the environment, and the env
/// always wins at boot), project `.fah/config.yaml` `providersQueue:`,
/// and user `~/.fah/config.yaml` `providersQueue:`. Resolution goes
/// through the CORE [resolveProviderQueueScopes] so the app never shows
/// a different winner than the next CLI boot applies; writes are
/// surgical, whole-section-validated upserts through [upsertYamlPath]
/// (the #221 lesson — never a whole-file rewrite). The editor section
/// joins the #391-#397 settings-hub series. IO platforms read the real
/// config; the stub (web) reports an unset queue and refuses writes.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

export 'providers_queue_loader_stub.dart'
    if (dart.library.io) 'providers_queue_loader_io.dart';
