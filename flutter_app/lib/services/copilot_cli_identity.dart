// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The host-side Copilot CLI identity install for the Flutter app
/// (gh-1606 review): the app is a second first-class PAT surface (the
/// connect sheet pastes tokens; the chat runtime streams through the
/// harness), so its boot installs the PAT-mode user-agent identity the
/// same way the CLI host does — app-side PAT requests then present
/// `copilot/<version> (<os>) term/unknown` instead of the
/// keep-working default `copilot/fa (unknown)`.
///
/// Conditional import: the OS slot needs `dart:io` on IO hosts; web
/// builds install the honest `'web'` value instead.
library;

export 'copilot_cli_identity_stub.dart'
    if (dart.library.io) 'copilot_cli_identity_io.dart';
