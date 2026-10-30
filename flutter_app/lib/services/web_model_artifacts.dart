// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Conditional export for the web storage seam of the gema leftover
/// cleanup (gh-2004): the OPFS-backed store on web, an unavailable stub
/// everywhere else (the cleanup's IO walk covers those platforms).
library;

export 'package:fa/services/web_model_artifacts_stub.dart'
    if (dart.library.js_interop) 'web_model_artifacts_web.dart';
