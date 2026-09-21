// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Resolves the `links:` config section for the app (issue #691): the
/// SAME section the CLI and the fa1.dev generator read — the app's Get
/// banner (web/macOS) never hard-codes a store URL, so a link changes
/// in ONE place (`~/.fah/config.yaml`) and every surface flips. IO
/// platforms read the real user config; the web stub reports the
/// baked-in defaults (the browser sandbox has no `~/.fah`).
///
/// Unlike the CLI boot (strict — a bad section is a named error), the
/// app NEVER bricks on config problems: an unreadable or invalid
/// section falls back to the defaults with a log note, and
/// `fa config check` remains the loud surface for the error.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

export 'links_loader_stub.dart' if (dart.library.io) 'links_loader_io.dart';

/// The effective app links — always a value (defaults when no config
/// states a choice), plus the load notes for surfaces that want them
/// (the banner logs them; `banner: false` hides every banner surface).
final class AppLinksResolution {
  const AppLinksResolution(this.links, this.notes);

  /// The effective `links:` section.
  final LinksConfig links;

  /// Load notes: what fell back and why (empty on a clean load).
  final List<String> notes;
}
