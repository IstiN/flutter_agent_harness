// Golden coverage for the "Load unpacked" flow's dialogs (gh-1616):
// the capability/replace confirmation and the named-issues error dialog.
//
// The dialogs are the user's decision points — the load grant (the
// exfiltration gate) and the validator's verbatim rejections — so the
// frames pin their real fonts, spacing and copy.
library;

import 'dart:typed_data';

import 'package:fa/apps/unpacked_load_flow.dart';
import 'package:fa/apps/unpacked_loader.dart';
import 'package:fa/apps/widget_payload_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('load confirmation with a declared network capability', (
    tester,
  ) async {
    await pumpGolden(
      tester,
      UnpackedLoadConfirmDialog(
        id: 'fa-agents',
        name: 'FA Agents',
        version: '0.3.0',
        network: true,
      ),
      size: goldenSizeTall,
    );
    await expectGolden(tester, 'unpacked_load_confirm_network');
  });

  testWidgets('load confirmation warns when an existing id is replaced', (
    tester,
  ) async {
    await pumpGolden(
      tester,
      const UnpackedLoadConfirmDialog(
        id: 'focus-timer',
        name: 'Focus Timer',
        version: '0.3.0',
        existingSource: 'catalog',
        existingVersion: '2.0.0',
      ),
      size: goldenSizeTall,
    );
    await expectGolden(tester, 'unpacked_load_confirm_replace');
  });

  testWidgets('load confirmation names an agent-created app as the source', (
    tester,
  ) async {
    // An existing app with NO install record (agent-created): the replace
    // warning fires with the honest "created by the agent" provenance.
    await pumpGolden(
      tester,
      const UnpackedLoadConfirmDialog(
        id: 'focus-timer',
        name: 'Focus Timer',
        version: '0.3.0',
        existingSource: UnpackedWidgetLoader.agentCreatedSource,
        existingVersion: '0.2.0',
      ),
      size: goldenSizeTall,
    );
    await expectGolden(tester, 'unpacked_load_confirm_replace_agent');
  });

  testWidgets('the named-issues dialog lists the validator errors', (
    tester,
  ) async {
    final validation = const WidgetPayloadValidator()
        .validate(<String, Uint8List>{
          'manifest.json': Uint8List.fromList(
            '{"id": "BAD ID", "name": "X"}'.codeUnits,
          ),
          'widget.js': Uint8List(0),
        });
    await pumpGolden(
      tester,
      UnpackedLoadIssuesDialog(issues: validation.errors),
      size: goldenSizeTall,
    );
    await expectGolden(tester, 'unpacked_load_issues');
  });
}
