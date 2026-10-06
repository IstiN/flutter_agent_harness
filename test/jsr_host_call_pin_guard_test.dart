// gh-1341 — the flutter_app js_widget_runtime pin must resolve the
// flutter_js hostCall/capture channel fix.
//
// The flutter_js engine shipped a hand-maintained `_bridgeChannels` list
// that never learned `__jsr_host_call` / `__jsr_capture`: flutter_js drops
// messages on unregistered channels, so every `jsr.hostCall(...)` promise
// hung forever on JSC builds (iOS/macOS) — voxel-sandbox spun forever and
// fa-craft fell back to the legacy scene3d path (~2 FPS). Upstream fix:
// flutter_js_widget_runtime commit 9d57570, published as hosted 0.4.156
// (v0.4.156 = 9d57570 + the automated `[pub bump]` commit).
//
// pubspec.yaml's own override comment documents the end state: "pin the
// exact upstream commit until the hosted 0.4.154+ is out, then drop the
// override and let the constraint resolve hosted." Hosted 0.4.156 is out
// and IS the fix commit, so the git override must be GONE.
//
// Deliberately static asserts over the committed pubspec.yaml + pubspec.lock
// (the nightly_desktop_leg_guard_test.dart / ci_pub_get_retry_guard_test.dart
// pattern) so the guard runs without touching the network.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

YamlMap loadPubspec(String path) =>
    loadYaml(File(path).readAsStringSync()) as YamlMap;

/// The first hosted version carrying the 9d57570 bridge-channel fix.
const minFixedVersion = '0.4.156';

int pubVersion(String v) {
  final parts = v.split('.').map(int.parse).toList();
  return (parts[0] << 20) | (parts[1] << 10) | parts[2];
}

void main() {
  test('pubspec.yaml has no js_widget_runtime dependency_override', () {
    final overrides = loadPubspec('flutter_app/pubspec.yaml')
        ['dependency_overrides'] as YamlMap?;
    expect(
      overrides?.keys,
      isNot(contains('js_widget_runtime')),
      reason:
          'hosted 0.4.156 (= upstream 9d57570, the flutter_js '
          'hostCall/capture channel fix) is published — the git pin must go, '
          'per the documented end state in the override comment itself',
    );
  });

  test('pubspec.yaml requires js_widget_runtime >= $minFixedVersion', () {
    final deps = loadPubspec('flutter_app/pubspec.yaml')['dependencies']
        as YamlMap;
    expect(deps['js_widget_runtime'], '^$minFixedVersion');
  });

  test('committed lockfile resolves js_widget_runtime hosted >= '
      '$minFixedVersion', () {
    final entry = (loadPubspec('flutter_app/pubspec.lock')['packages']
        as YamlMap)['js_widget_runtime'] as YamlMap;
    final description = entry['description'] as YamlMap;
    expect(
      entry['source'],
      'hosted',
      reason: 'a git-sourced js_widget_runtime in the lockfile is the '
          'pre-gh-1341 pin regression (bd1e7c2 has no 9d57570 bridge fix)',
    );
    expect(description['url'], 'https://pub.dev');
    expect(
      pubVersion(entry['version'] as String),
      greaterThanOrEqualTo(pubVersion(minFixedVersion)),
      reason: 'versions before 0.4.156 ship the flutter_js engine with the '
          'stale _bridgeChannels list — jsr.hostCall/jsr.capture hang on JSC',
    );
  });
}
