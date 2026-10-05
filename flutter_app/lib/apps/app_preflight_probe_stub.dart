// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web stub of the [jsEngineBootable] probe (selected by the conditional
/// export in `app_preflight.dart` when `dart:io` is unavailable): the web
/// build ships the JS engine inside the page bundle (flutter_js web
/// backend) — there is no native library to probe, so the smoke gate is
/// always installable.
library;

/// Whether the JS engine the smoke probe boots can load its engine
/// backend on THIS host.
final bool jsEngineBootable = true;
