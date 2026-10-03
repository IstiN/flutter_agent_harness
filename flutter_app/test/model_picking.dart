// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared widget-test helper: driving the provider editor's model row
/// through the shared selector (issue #1020 — boarding flows must pick a
/// chat model). Free-text entry always works; the `/models` endpoint
/// fetch is silent on failure.
library;

import 'package:fa_ui/fa_ui.dart' show MediaSlotModelPage;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

extension ModelPicking on WidgetTester {
  /// Opens the editor's model row, types [modelId] into the selector's
  /// free-text field, and saves — back on the editor with the row filled.
  Future<void> pickModel(String modelId) async {
    await tap(find.text('Model id'));
    await pumpAndSettle();
    expect(find.byType(MediaSlotModelPage), findsOneWidget);
    await enterText(find.widgetWithText(TextField, 'Model id'), modelId);
    await tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpAndSettle();
  }
}
