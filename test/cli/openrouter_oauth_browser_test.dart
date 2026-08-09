// Coverage for the top-level `openBrowser` in openrouter_oauth_server.dart
// (CRAP ratchet: 0%-covered helper tripped the gate). Only failure paths
// are exercised — a success call would pop a real browser/Finder window on
// the host.

import 'package:flutter_agent_harness/src/cli/openrouter_oauth_server.dart';
import 'package:test/test.dart';

void main() {
  group('openBrowser', () {
    test('a nonexistent file URL returns false', () async {
      expect(
        await openBrowser('file:///definitely/missing/path-xyz-123'),
        isFalse,
      );
    });

    test('a malformed URL returns false (launcher rejects it)', () async {
      expect(await openBrowser(':://not a url::'), isFalse);
    });
  });
}
