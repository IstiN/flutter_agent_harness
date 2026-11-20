// PR#2295 review (ai-teammate BLOCKING + IMPORTANT threads) — the WWDR G6
// import block in scripts/ci-sign must (a) run AFTER TMP is assigned and
// the consolidated EXIT trap is installed, and (b) skip the import only
// when the G6 generation itself is present, not any WWDR generation.
//
//   BLOCKING: the block originally sat before TMP="$(mktemp -d)", so the
//     very first guard trigger aborted `install` under `set -u`
//     ("TMP: unbound variable") — the feature was dead on arrival and
//     every cert-less host's install crashed. bash -n and ShellCheck stay
//     green on that shape (TMP is assigned later in the same case block),
//     so only a position assert guards it statically; the runtime repro
//     (stub security/curl, set -euo pipefail) is in the PR thread reply.
//   IMPORTANT: `find-certificate -a -c "Apple Worldwide Developer
//     Relations"` matches ANY generation by shared CN — a single old
//     G3/G4/G5 (even expired, e.g. dragged in by Xcode export, gh-2008
//     mechanism) permanently suppressed the G6 import. The guard now
//     compares each match's SHA-1 (-Z output) against the pinned
//     Apple-published G6 fingerprint (AppleWDRCAG6.cer, OU=G6,
//     2021-03-17 → 2036-03-19).
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final script = File('scripts/ci-sign').readAsStringSync();

  group('PR#2295 WWDR G6 guard', () {
    test('import block runs after TMP assignment and EXIT trap', () {
      final tmpAssign = script.indexOf('TMP="\$(mktemp -d)"');
      final trap = script.indexOf("trap 'rm -rf \"\$TMP\"");
      final block = script.indexOf('WWDR_G6_SHA1=');
      final tmpUse = script.indexOf('"\$TMP/wwdr.pem"');
      expect(tmpAssign, greaterThan(-1), reason: 'TMP assignment missing');
      expect(trap, greaterThan(-1), reason: 'EXIT trap missing');
      expect(
        block,
        greaterThan(tmpAssign),
        reason: 'WWDR block must sit below TMP= (set -u crash otherwise)',
      );
      expect(
        block,
        greaterThan(trap),
        reason: 'WWDR block must sit below the EXIT trap (wwdr.pem cleanup)',
      );
      expect(
        tmpUse,
        greaterThan(tmpAssign),
        reason: '"\$TMP/wwdr.pem" must never expand before TMP is set',
      );
    });

    test('idempotency guard pins the G6 SHA-1, not the shared WWDR CN', () {
      // The real fingerprint of https://www.apple.com/certificateauthority/
      // AppleWWDRCAG6.cer (OU=G6, 2021-03-17 → 2036-03-19), verified by
      // downloading the cert and hashing it (openssl x509 -fingerprint -sha1).
      const g6Sha1 = '0BE38BFE21FD434D8CC51CBE0E2BC7758DDBF97B';
      expect(
        script,
        contains('WWDR_G6_SHA1="$g6Sha1"'),
        reason: 'G6 fingerprint pin missing or wrong',
      );
      expect(
        script,
        contains(
          'security find-certificate -a -Z -c '
          '"Apple Worldwide Developer Relations"',
        ),
        reason: 'guard must list matches with -Z (SHA-1 per cert)',
      );
      // PR#2295 review: plain `grep -i >/dev/null`, NOT `grep -q` —
      // under pipefail an early-exiting grep SIGPIPEs the producer and
      // flips the guard to a false-negative (duplicate import + WARN).
      expect(
        script,
        contains('| tr -d \' :\' | grep -i "\$WWDR_G6_SHA1" >/dev/null'),
        reason:
            'guard must compare the normalized hash against the '
            'pin, draining the full listing (no grep -q SIGPIPE)',
      );
    });
  });
}
