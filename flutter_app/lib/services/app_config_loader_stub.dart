// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web stub: there is no `~/.fah/config.yaml` on the web, so the owner
/// context-window cap never resolves — uncapped (null), exactly like a
/// config without the `agent:` section.
library;

/// The parsed owner cap, or null (web has no config source).
int? loadAppContextWindowCap([String? projectDir]) => null;
