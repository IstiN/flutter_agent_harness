// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ProviderMark renders a branded tile for every preset key', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final preset in defaultAddProviderPresets)
                ProviderMark(preset.key),
              const ProviderMark('unknown-fallback'),
            ],
          ),
        ),
      ),
    );
    expect(
      find.byType(ProviderMark),
      findsNWidgets(defaultAddProviderPresets.length + 1),
    );
    expect(tester.takeException(), isNull);
  });
}
