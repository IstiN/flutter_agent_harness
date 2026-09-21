// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IO implementation: reads the user `~/.fah/config.yaml` `links:`
/// section through the SAME core loader the CLI boot uses
/// ([loadCliConfig] — its `links:` parse is strict, so a bad shape
/// surfaces here as a fallback-to-defaults note, never a crash: the app
/// is not the CLI, `fa config check` is the loud surface).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'app_log.dart';
import '../sandbox/env_factory_io.dart' show desktopHomeDir;
import 'links_loader.dart';

/// Resolves the effective links for the app banner surfaces.
/// [homeDir] overrides the user-home lookup (tests inject a temp dir;
/// default: [desktopHomeDir]). Absent file/section → the baked-in
/// defaults; unreadable/invalid → the defaults + a note.
AppLinksResolution resolveAppLinks({String? homeDir}) {
  final home = homeDir ?? desktopHomeDir();
  if (home == null) return const AppLinksResolution(LinksConfig(), []);
  try {
    final config = loadCliConfig(home);
    final notes = [for (final note in config.links.notes) 'links: $note'];
    return AppLinksResolution(config.links, notes);
  } on Object catch (error) {
    final note =
        'links: config unreadable ($error) — store links fell '
        'back to the defaults; run `fa config check` for the named error';
    AppLog.i('links', note);
    return AppLinksResolution(const LinksConfig(), [note]);
  }
}
