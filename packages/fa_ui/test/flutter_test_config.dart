// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Package-wide test bootstrap.
///
/// Loads the bundled MaterialIcons font (via `uses-material-design`) in
/// the real async zone BEFORE any test body runs. Font loading uses real
/// file I/O, which can never complete inside a `testWidgets` FakeAsync
/// zone — done here, goldens render real icon glyphs instead of
/// placeholder boxes. See `trajectory/golden/golden_test_setup.dart`.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'trajectory/golden/golden_test_setup.dart';

Future<void> testExecutable(FutureOr<void> Function() testBody) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadGoldenFonts();
  await testBody();
}
