// Byte-equality between the publishable registry copies of the bundled
// crap-guard extension (js-ext-registry/crap-guard/) and the compiled-in
// Dart consts (issue #32): a catalog zip must ship exactly the bytes the
// binary runs, so the registry files are generated FROM the consts and this
// test fails the moment they drift.
import 'dart:io';

import 'package:flutter_agent_harness/src/js_ext/bundled/crap_guard.dart';
import 'package:test/test.dart';

void main() {
  test('registry manifest.json == kCrapGuardManifestJson byte-for-byte', () {
    final file = File('js-ext-registry/crap-guard/manifest.json');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run `dart test` from the package root',
    );
    expect(file.readAsStringSync(), kCrapGuardManifestJson);
  });

  test('registry main.js == kCrapGuardMainJs byte-for-byte', () {
    final file = File('js-ext-registry/crap-guard/main.js');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run `dart test` from the package root',
    );
    expect(file.readAsStringSync(), kCrapGuardMainJs);
  });
}
