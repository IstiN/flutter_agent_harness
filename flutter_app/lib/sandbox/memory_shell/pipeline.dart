// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/sandbox/shell_parser.dart';
import 'package:fa/sandbox/wasm_shell_builtins.dart'
    show collectStageRedirects, StageRedirects;

/// The redirect resolution of one pipeline stage (gh-1393 WS-1): a thin
/// delegate onto the SHARED resolver ([collectStageRedirects]) so the web
/// MemoryShell and the WASI shell cannot drift — `<`/`<<`/`<<<`, `>`/`>>`,
/// `2>`/`2>>`, `&>` and the `2>&1`/`>&2` fd-duplication flags (the dup
/// fields are what the local copy used to lack) resolve identically for
/// both shells, under one conformance table.
StageRedirects parseStageRedirects(List<Redirect> redirects) =>
    collectStageRedirects(redirects);
