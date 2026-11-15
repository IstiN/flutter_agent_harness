/// The gh-1832 landing deep-link contract, pinned statically (offline).
///
/// The CI `release-asset-smoke` job probes every
/// `releases/(latest/)?download/…` URL the landing page exposes with a live
/// ranged GET — but only on the tag train, so a PR can land a `latest`
/// deep link to an asset the tag train never guarantees and the breakage
/// only surfaces hours later as a red release run (gh-2194: v1.0.729 was
/// the first tag carrying `releases/latest/download/fa-app-windows-x64.*`
/// buttons; no release carries those assets — they belong to the daily
/// windows-app leg, a clobber-refresher class the required-set doctrine
/// deliberately keeps out of every tag).
///
/// This test mirrors the same contract offline: every `latest/download`
/// deep link in `site/index.html` must name an asset from
/// `scripts/release_required_assets.txt` — the single source of truth for
/// what the tag train guarantees on every release. Version-pinned links
/// (`releases/download/v1.0.636/…`) are frozen history the live probe
/// already HEAD-checks; the rot risk is `latest`, so that is what is
/// pinned here. Daily-leg app assets (DMGs, APKs, `fa-app-windows-*`)
/// must be reached through the release PAGE link (the macOS-button
/// pattern), never through a `latest/download` deep link.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final index = File('site/index.html').readAsStringSync();
  final requiredFile = File('scripts/release_required_assets.txt');

  /// Same extraction contract as scripts/assert_release_assets.sh
  /// --landing: URL stops at whitespace, quotes, angle/close parens,
  /// plus, comma.
  final deepLinks = RegExp(
    r'https://[^"'
    ' <>()+,\t]*/releases/latest/download/[^"'
    ' <>()+,\t]+',
  ).allMatches(index).map((m) => m.group(0)!).toSet();

  final guaranteed = requiredFile
      .readAsLinesSync()
      .map((line) {
        // Strip the comment tail the same way the gate does ('#' starts a
        // comment) — the index is reused for slicing, not containment.
        final hash = line.indexOf('#');
        return (hash == -1 ? line : line.substring(0, hash)).trim();
      })
      .where((line) => line.isNotEmpty)
      .toSet();

  test(
    'every latest/download deep link names a tag-train-guaranteed asset',
    () {
      expect(
        deepLinks,
        isNotEmpty,
        reason:
            'the landing page shape changed — revisit this contract '
            '(mirrors the gh-1832 --landing link-check)',
      );
      final offenders = <String>[];
      for (final url in deepLinks) {
        final asset = url.split('/download/').last;
        if (!guaranteed.contains(asset)) {
          offenders.add(
            '$url (not in release_required_assets.txt — '
            'the tag train does not guarantee it on every release)',
          );
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'a latest/download deep link to a non-guaranteed asset 404s '
            'whenever latest is a train-cut release without that asset '
            '(the gh-2194/v1.0.729 breakage). Reach daily-leg assets '
            'through the release page link instead.',
      );
    },
  );
}
