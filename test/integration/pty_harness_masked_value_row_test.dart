// Unit proof for the gh-1244 review-thread fix: `typeSecret` must
// synchronize on a STABLE screen property, not a snapshot read after a
// silently-timing-out `waitForOutput` — on a loaded runner the painted
// frame can still be mid-echo (e.g. 13 of 15 bullets). The anchor is the
// sheet's frame-closed masked value row (`maskedValueRow`): bullets are
// append-only while typing, so waiting for the full N-bullet row on the
// SCREEN is a monotone synchronization point, and the `│` guard pins the
// match to the sheet's own row — the history's tool row
// (`• request_secret · …`) is not frame-closed and must never match.
//
// Top-level and pure (like `frameContentLines`) so the row-anchor rule is
// provable without a PTY. Runs in the DEFAULT suite (no integration tag).
@TestOn('vm')
library;

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('maskedValueRow', () {
    test('finds the frame-closed bullet row among history and chrome', () {
      const screen = '''
[Model] test-model
● request_secret · to call the upstream API
┌ Credential request ──────────────┐
│ Name  MY_SERVICE_TOKEN           │
│ Value  > •••••••••••••••••       │
└──────────────────────────────────┘
''';
      expect(maskedValueRow(screen), '│ Value  > •••••••••••••••••       │');
    });

    test('ignores the history tool row — a lone bullet not frame-closed', () {
      const screen = '''
● request_secret · MY_SERVICE_TOKEN
┌ Credential request ──┐
│ Name  MY_SERVICE_TOKEN │
''';
      expect(maskedValueRow(screen), isNull);
    });

    test('a frame-closed row without bullets does not match (e.g. the '
        'name row)', () {
      const screen = '''
┌ Credential request ──┐
│ Name  MY_SERVICE_TOKEN │
│ Value  >               │
''';
      expect(maskedValueRow(screen), isNull);
    });

    test('empty screen never matches', () {
      expect(maskedValueRow(''), isNull);
    });
  });
}
