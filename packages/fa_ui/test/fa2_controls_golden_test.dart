// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Control-family goldens: a switch/radio/checkbox/slider row shot in
/// every Fa 2.0 direction × brightness, so the token-themed controls
/// (custom [FaSwitch] capsule, themed radios/checkboxes/sliders) are
/// locked pixel-by-pixel in light AND dark. Fonts are loaded by the
/// package test bootstrap (`test/flutter_test_config.dart`).
library;

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final direction in FaVisualDirection.values) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'controls row ${direction.name} ${brightness.name}',
        (tester) async {
          tester.view.physicalSize = const Size(420, 320);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              // The bundled Inter preset: the package golden env registers
              // Inter (not the platform faces the system preset requests),
              // and this golden locks control styling, not type.
              theme: buildFaTheme(
                direction: direction,
                brightness: brightness,
                fontPreset: FaFontPreset.inter,
              ),
              home: Scaffold(
                body: Center(child: _ControlsRow(direction: direction)),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile(
              'goldens/fa2_controls_${direction.name}_${brightness.name}.png',
            ),
          );
        },
      );
    }
  }
}

class _ControlsRow extends StatelessWidget {
  const _ControlsRow({required this.direction});

  final FaVisualDirection direction;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return FaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Row(
            label: 'Switch',
            child: Row(
              children: [
                const FaSwitch(value: true, onChanged: _noop),
                const SizedBox(width: 10),
                const FaSwitch(value: false, onChanged: _noop),
                const SizedBox(width: 10),
                const FaSwitch(value: true, onChanged: null),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _Row(
            label: 'Radio',
            child: Row(
              children: [
                RadioGroup<bool>(
                  groupValue: true,
                  onChanged: (_) {},
                  child: const Row(
                    children: [
                      Radio<bool>(value: true),
                      Radio<bool>(value: false),
                    ],
                  ),
                ),
                // The single disabled specimen: the Radio-group API has no
                // per-radio disabled slot, so this one rides the legacy
                // state-based constructor.
                // ignore: deprecated_member_use
                Radio<bool>(value: true, groupValue: true, onChanged: null),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _Row(
            label: 'Checkbox',
            child: Row(
              children: [
                Checkbox(value: true, onChanged: (_) {}),
                Checkbox(value: false, onChanged: (_) {}),
                Checkbox(value: true, onChanged: null),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _Row(
            label: 'Slider',
            child: SizedBox(
              width: 220,
              child: FaSlider(value: .65, onChanged: _noopDouble),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${direction.name} · ${tokens.brightness.name}',
            style: TextStyle(color: tokens.ink3, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(color: tokens.ink2, fontSize: 12),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

void _noop(bool _) {}
void _noopDouble(double _) {}
