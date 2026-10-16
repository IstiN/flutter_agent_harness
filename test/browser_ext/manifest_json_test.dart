import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'browser_ext/manifest.json is strict JSON (Chrome rejects comments)',
    () {
      final manifest =
          jsonDecode(File('browser_ext/manifest.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(manifest['manifest_version'], 3);
      expect(manifest['permissions'], isA<List>());
    },
  );
}
