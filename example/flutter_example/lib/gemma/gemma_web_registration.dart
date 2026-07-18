// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Conditional export: the web-only manual registration of the
/// flutter_gemma platform instance (see `gemma_web_registration_web.dart`
/// for why it is needed); a no-op on every other platform.
library;

export 'gemma_web_registration_stub.dart'
    if (dart.library.js_interop) 'gemma_web_registration_web.dart';
