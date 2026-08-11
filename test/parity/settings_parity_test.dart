/// Cross-platform settings parity guard: every [SharedSetting] declared in
/// `lib/src/parity/settings_registry.dart` must have a matching reference in
/// BOTH the CLI (`lib/src/cli/`) and the Flutter app (`flutter_app/lib/`),
/// unless explicitly exempted in [cliOnlySettings] / [appOnlySettings].
///
/// This test reads source files from disk (it is a VM-only test).
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  /// Recursively collects every `.dart` file under [dir] as a single string.
  Future<String> readAllDart(String dir) async {
    final buf = StringBuffer();
    final entities = Directory(dir).list(recursive: true);
    await for (final entity in entities) {
      if (entity is File && entity.path.endsWith('.dart')) {
        buf.writeln(await entity.readAsString());
      }
    }
    return buf.toString();
  }

  group('settings parity', () {
    late String cliSource;
    late String appSource;

    setUpAll(() async {
      cliSource = await readAllDart('lib/src/cli');
      appSource = await readAllDart('flutter_app/lib');
    });

    test('every SharedSetting is present in the CLI unless exempted', () {
      for (final setting in SharedSetting.values) {
        if (cliOnlySettings.contains(setting)) continue;
        final meta = sharedSettingMetadata[setting]!;
        expect(
          cliSource,
          contains(meta.cliRef),
          reason:
              '${setting.name}: CLI reference "${meta.cliRef}" not found in '
              'lib/src/cli/. ${meta.description}',
        );
      }
    });

    test('every SharedSetting is present in the app unless exempted', () {
      for (final setting in SharedSetting.values) {
        if (appOnlySettings.contains(setting)) continue;
        final meta = sharedSettingMetadata[setting]!;
        final appRef = meta.appRef;
        if (appRef == null) continue; // explicitly exempted via null appRef
        expect(
          appSource,
          contains(appRef),
          reason:
              '${setting.name}: app reference "$appRef" not found in '
              'flutter_app/lib/. ${meta.description}',
        );
      }
    });

    test('cliOnlySettings entries have no appRef (truly CLI-only)', () {
      for (final setting in cliOnlySettings) {
        final meta = sharedSettingMetadata[setting]!;
        expect(
          meta.appRef,
          isNull,
          reason:
              '${setting.name} is in cliOnlySettings but still has an appRef '
              '— either implement it in the app or remove the appRef.',
        );
      }
    });

    test('appOnlySettings entries have a cliRef that is absent from CLI', () {
      // appOnlySettings should genuinely NOT appear in the CLI.
      for (final setting in appOnlySettings) {
        final meta = sharedSettingMetadata[setting]!;
        expect(
          cliSource,
          isNot(contains(meta.cliRef)),
          reason:
              '${setting.name} is in appOnlySettings but "${meta.cliRef}" '
              'was found in the CLI — remove it from appOnlySettings.',
        );
      }
    });

    test('media slot ids are shared between CLI and app', () {
      // The canonical list lives in lib/src/model_roles/media_model_slots.dart
      // and both platforms must reference it.
      expect(
        cliSource,
        contains('mediaModelSlotIds'),
        reason: 'CLI must reference mediaModelSlotIds from the shared schema.',
      );
      expect(
        appSource,
        contains('MediaSlot.all'),
        reason:
            'App must reference MediaSlot.all (which equals mediaModelSlotIds).',
      );
    });

    test('approval mode enum is referenced by both platforms', () {
      expect(
        cliSource,
        contains('ApprovalMode'),
        reason: 'CLI must reference the shared ApprovalMode enum.',
      );
      expect(
        appSource,
        contains('ApprovalMode'),
        reason: 'App must reference the shared ApprovalMode enum.',
      );
    });

    test('interactive tool factories are called by both platforms', () {
      // askTool and requestSecretTool are the two interactive tools that
      // require a host callback. Both platforms must register them.
      expect(
        cliSource,
        contains('askTool('),
        reason: 'CLI must register askTool.',
      );
      expect(
        cliSource,
        contains('requestSecretTool('),
        reason: 'CLI must register requestSecretTool.',
      );
      expect(
        appSource,
        contains('askTool('),
        reason: 'App must register askTool.',
      );
      expect(
        appSource,
        contains('requestSecretTool('),
        reason: 'App must register requestSecretTool.',
      );
    });
  });
}
