// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Extension-host detection and the production `chrome.runtime` port
/// binding, split per platform: the web build gets the real probe
/// (`ext_runtime_web.dart`), every other platform compiles the stub that
/// always answers "not an extension host".
library;

export 'ext_runtime_stub.dart'
    if (dart.library.js_interop) 'ext_runtime_web.dart';
