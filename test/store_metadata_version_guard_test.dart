// Regression guard for store-metadata run 42496489910: the Apple legs read
// the committed 0.0.0-dev pubspec placeholder and then called a nonexistent
// Spaceship::ConnectAPI::App#create_app_store_version method. The workflow
// must receive an explicit release version, and version creation must use
// the supported App#ensure_version! endpoint. The latter also covers the
// rejected macOS 1.0 version from run 42498061545: Apple rejects a second
// version while that editable one exists, so its version string is reused.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final workflowText = File(
    '.github/workflows/store-metadata.yml',
  ).readAsStringSync();
  final fastfile = File('flutter_app/fastlane/Fastfile').readAsStringSync();
  final workflow = loadYaml(workflowText) as YamlMap;
  final trigger = workflow['on'] ?? workflow[true];
  final dispatch = (trigger as YamlMap)['workflow_dispatch'] as YamlMap;
  final inputs = dispatch['inputs'] as YamlMap;

  test('store screenshots dispatch requires an explicit release version', () {
    expect(inputs, contains('version'));
    final version = inputs['version'] as YamlMap;
    expect(version['required'], isTrue);
    expect(version['type'], 'string');
  });

  test('both Apple deploy legs receive BUILD_NAME from that version', () {
    expect(
      RegExp(
        r'BUILD_NAME: \$\{\{ inputs\.version \}\}',
      ).allMatches(workflowText).length,
      2,
    );
  });

  test('version sync reuses an editable version or creates a missing one', () {
    expect(
      fastfile,
      contains('app.ensure_version!(version, platform: platform)'),
    );
    expect(fastfile, isNot(contains('app.create_app_store_version(')));
    expect(
      fastfile,
      isNot(contains('Spaceship::ConnectAPI.post_app_store_version(')),
      reason:
          'A direct POST cannot reuse the rejected macOS version; '
          'App#ensure_version! handles both update and create.',
    );
  });
}
