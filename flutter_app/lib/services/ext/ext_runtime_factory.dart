// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Default JS-extension engine factory for the Fa app, picked per build:
/// flutter_js on IO/mobile, the web worker on web (conditional export; the
/// web branch compiles only where `dart.library.html` holds).
library;

export 'ext_runtime_factory_stub.dart'
    if (dart.library.io) 'ext_runtime_factory_io.dart';
