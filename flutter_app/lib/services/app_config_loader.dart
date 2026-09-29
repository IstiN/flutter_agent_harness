// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Resolves the app's owner context-window cap (`agent.contextWindowCap`,
/// gh-1077) — the same global < project chain the CLI honors: project
/// `.fah/config.yaml` wins over `~/.fah/config.yaml`, null when neither
/// states one (uncapped). IO platforms read the real config; the stub
/// (web) always answers null.
library;

export 'app_config_loader_stub.dart'
    if (dart.library.io) 'app_config_loader_io.dart';
