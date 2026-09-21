// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web stub: the browser sandbox has no `~/.fah/config.yaml`, so the
/// web app's Get banner resolves the BAKED-IN defaults — the same
/// constants the fa1.dev generator renders, one source of truth away.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'links_loader.dart';

/// Always the baked-in defaults, no notes (nothing was skipped).
AppLinksResolution resolveAppLinks({String? homeDir}) =>
    const AppLinksResolution(LinksConfig(), []);
