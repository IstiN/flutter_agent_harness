// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Non-web no-op for the conditional export in `gemma_web_registration.dart`.
library;

/// No-op outside web: mobile registers its own platform instance
/// (`FlutterGemmaMobile`) through the normal mobile plugin registration,
/// and host tests never touch the real engine.
void ensureGemmaWebRegistered() {}
