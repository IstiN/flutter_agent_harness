// Regression guard for store-metadata run 42496489910: the Apple legs read
// the committed 0.0.0-dev pubspec placeholder and then called a nonexistent
// Spaceship::ConnectAPI::App#create_app_store_version method. The workflow
// must receive an explicit release version, and version creation must use
// the supported ConnectAPI.post_app_store_version endpoint.
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

  test('version creation uses the supported Spaceship endpoint', () {
    expect(fastfile, contains('Spaceship::ConnectAPI.post_app_store_version('));
    expect(fastfile, isNot(contains('app.create_app_store_version(')));
  });
}
