// Regression gate for the "Unable to load asset" TestFlight failure: every
// bundled demo id in [AppsStore.demoAppIds] must be declared as an asset
// directory in pubspec.yaml — Flutter bundles only what is listed, so a
// demo added to the list without a pubspec entry ships an app whose
// seeding dies with "Unable to load asset" on device (fitness-trainer /
// english-teacher, build 77). Pure Dart, no bundling involved.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fa/apps/apps_store.dart';

void main() {
  test('every bundled demo id is declared in pubspec.yaml assets', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final missing = <String>[];
    for (final id in AppsStore.demoAppIds) {
      final entry = '- ${AppsStore.bundledAssetRoot}/$id/';
      if (!pubspec.contains(entry)) missing.add(id);
    }
    expect(
      missing,
      isEmpty,
      reason:
          'demo ids missing from pubspec.yaml assets (their apps will fail '
          'to seed on device): $missing',
    );
  });

  test('every bundled demo id ships manifest.json + widget.js', () {
    final missing = <String>[];
    for (final id in AppsStore.demoAppIds) {
      for (final file in const ['manifest.json', 'widget.js']) {
        final path = '${AppsStore.bundledAssetRoot}/$id/$file';
        if (!File(path).existsSync()) missing.add(path);
      }
    }
    expect(missing, isEmpty, reason: 'missing demo asset files: $missing');
  });
}
