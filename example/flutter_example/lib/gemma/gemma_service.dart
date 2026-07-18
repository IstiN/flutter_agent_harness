// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Conditional export: the real `flutter_gemma`-backed engine on IO
/// platforms (iOS/Android), the unavailable stub everywhere else (same
/// pattern as `secrets_store.dart` in this app). Web builds never see the
/// plugin import, so `flutter build web` stays clean.
library;

export 'gemma_service_stub.dart' if (dart.library.io) 'gemma_service_io.dart';
