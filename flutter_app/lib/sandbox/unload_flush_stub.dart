// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/sandbox/persistent_web_env.dart';

/// Non-web fallback: there is no page-unload signal outside the browser,
/// so there is nothing to bind. Selected unless `dart.library.html` is
/// available (see the conditional export in `unload_flush.dart`).
void bindUnloadFlush(PersistentWebExecutionEnv env) {}
