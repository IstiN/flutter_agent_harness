// gh-2042 — release asset immutability gate (scripts/release_asset_gate.sh).
//
// The v1.0.680 incident: the daily build-macos train re-attached fresh
// fa-macos-arm64 assets to the ALREADY-PUBLISHED release ~2-3h AFTER the
// signed SHA256SUMS was attached — the manifest never re-ran, and every
// `fa update` provenance check on the train failed. Contract (AC1): a
// PUBLISHED release is immutable for `fa-*` assets — a post-publish attach
// must skip already-attached assets, refuse unattached fa-* assets loudly,
// and still allow the non-fa clobber-refresh (store AAB/IPA/APK artifacts
// are deliberately not provenance-covered, scripts/release_required_assets.txt).
// Drafts (and missing releases — the caller creates the draft first) attach
// exactly as before.
//
// Behavioral coverage follows release_hygiene_test.dart's style: a stubbed
// `gh` on PATH answering from fixture files, every invocation logged.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'release_hygiene_test_support.dart';

void main() {
  GateRun runGate(
    String name, {
    String? releaseState,
    List<String> attachedNames = const [],
    List<String> assets = const ['fa-linux-x64.tar.gz'],
    List<String> viewSeq = const [],
    Map<String, String> env = const {},
  }) {
    final dir = Directory(
      '${hygieneFixtureRoot.path}/gate-$name-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final bin = stubGh(dir.path);
    if (releaseState != null) {
      File('${dir.path}/release-state.txt').writeAsStringSync('$releaseState\n');
    }
    if (attachedNames.isNotEmpty) {
      File(
        '${dir.path}/asset-names.txt',
      ).writeAsStringSync('${attachedNames.join('\n')}\n');
    }
    if (viewSeq.isNotEmpty) {
      File('${dir.path}/view-seq.txt').writeAsStringSync(
        '${viewSeq.join('\n')}\n',
      );
    }
    for (final asset in assets) {
      File('${dir.path}/$asset').writeAsStringSync('bytes of $asset');
    }
    File('${dir.path}/log').writeAsStringSync('');
    final res = Process.runSync('bash', [
      File('scripts/release_asset_gate.sh').absolute.path,
      'v1.2.3',
      ...assets,
    ], environment: {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/log',
      'GH_TOKEN': 'stub',
      ...env,
    });
    return GateRun(
      res.exitCode,
      '${res.stdout}${res.stderr}',
      File('${dir.path}/log').readAsLinesSync(),
    );
  }

  test('missing gate script fails the suite loudly', () {
    expect(File('scripts/release_asset_gate.sh').existsSync(), isTrue,
        reason: 'scripts/release_asset_gate.sh must exist (gh-2042 AC1)');
  });

  test('draft release → attach: every asset uploaded --clobber, exit 0', () {
    // Default fixture state (no release-state.txt) = draft: the pre-gate
    // behavior every existing release test pins must be untouched.
    final run = runGate('draft', assets: ['fa-linux-x64.tar.gz', 'a.zip']);
    expect(run.exitCode, 0, reason: run.out);
    expect(
      run.log,
      contains('release upload v1.2.3 fa-linux-x64.tar.gz --clobber --repo OWNER/REPO'),
    );
    expect(
      run.log,
      contains('release upload v1.2.3 a.zip --clobber --repo OWNER/REPO'),
    );
    expect(run.log.where((l) => l.contains('release edit')), isEmpty,
        reason: 'the gate never publishes — provenance owns the flip');
  });

  test('published release + fa-* NOT attached → loud refusal, NOTHING uploaded', () {
    // The v1.0.680 shape: re-attaching an unattached fa-* asset to a
    // published release invalidates the signed manifest. Refuse before any
    // upload — a red leg, never silent drift.
    final run = runGate('published-fa', releaseState: 'false',
        attachedNames: ['fa-web-spa.zip'], assets: ['fa-macos-arm64.tar.gz']);
    expect(run.exitCode, isNot(0), reason: run.out);
    expect(run.out, contains('::error::'));
    expect(run.out, contains('fa-macos-arm64.tar.gz'));
    expect(run.out.toLowerCase(), contains('published'),
        reason: 'the refusal must name the immutability contract');
    expect(
      run.log.where((l) => l.contains('release upload')),
      isEmpty,
      reason: 'a refused attach uploads nothing',
    );
    expect(run.log.where((l) => l.contains('release edit')), isEmpty);
  });

  test('published release + fa-* ALREADY attached → immutable skip, exit 0, no upload', () {
    // The release-twin binaries re-run: same tag commit, asset already on
    // the published release. Skip — rebuilding + clobbering would drift the
    // manifest for the minutes until provenance re-signs (and the re-request
    // is a job rerun away anyway).
    final run = runGate('published-skip', releaseState: 'false',
        attachedNames: ['fa-linux-x64.tar.gz', 'SHA256SUMS', 'SHA256SUMS.sig'],
        assets: ['fa-linux-x64.tar.gz']);
    expect(run.exitCode, 0, reason: run.out);
    expect(run.log.where((l) => l.contains('release upload')), isEmpty,
        reason: 'an already-attached asset on a published release is skipped');
    expect(run.log.where((l) => l.contains('release edit')), isEmpty);
    expect(run.out.toLowerCase(), contains('skip'));
  });

  test('published release + non-fa asset → clobber-refresh stays allowed', () {
    // Store artifacts (AAB/IPA/APK) and DMG refreshers are deliberately not
    // provenance-covered (release_required_assets.txt scope note) — the
    // daily mobile leg keeps refreshing them.
    final run = runGate('published-nonfa', releaseState: 'false',
        attachedNames: ['fa-linux-x64.tar.gz'],
        assets: ['app-release.aab']);
    expect(run.exitCode, 0, reason: run.out);
    expect(
      run.log,
      contains('release upload v1.2.3 app-release.aab --clobber --repo OWNER/REPO'),
    );
  });

  test('published release + mixed list (one unattached fa-*) → refuse ALL, nothing uploaded', () {
    // Loop/collection contract: one bad asset must refuse the WHOLE list —
    // a partial attach would still drift the manifest.
    final run = runGate('published-mixed', releaseState: 'false',
        attachedNames: ['fa-linux-x64.tar.gz'],
        assets: ['fa-linux-x64.tar.gz', 'fa-macos-arm64.tar.gz', 'app-release.aab']);
    expect(run.exitCode, isNot(0), reason: run.out);
    expect(run.out, contains('fa-macos-arm64.tar.gz'));
    expect(run.log.where((l) => l.contains('release upload')), isEmpty,
        reason: 'a mixed refusal uploads nothing — no partial mutation');
  });

  // ── gh-2050: the pre-stage policy (RELEASE_GATE_PUBLISHED_SKIP=1) ──────
  //
  // The daily build-macos leg is a next-tag-draft PRE-STAGER (its DMGs/zips/
  // latest-mac.yml are clobber-refresher assets, not publish blockers —
  // release_required_assets.txt). When the sibling train publishes the
  // derived tag while the serialized self-hosted macOS builds are still
  // running (run 41583268061: draft 05:22:46, published 05:44:52, mac leg
  // attached 06:28:53), the leg's attach arrives at a PUBLISHED release and
  // the default verdict refuses — a red leg + a discarded build. Under the
  // caller-declared policy that verdict becomes a whole-call loud skip: the
  // immutability contract holds (nothing uploads, nothing mutates), and the
  // next daily leg pre-stages the NEXT version's draft with fresh assets.

  test('gh-2050 policy: published + unattached fa-* → loud whole-call skip, exit 0, NOTHING uploaded', () {
    // THE gh-2050 reproduction: without the policy this verdict is the
    // ::error:: refusal above (red leg); with it the leg goes green.
    final run = runGate('policy-published-fa', releaseState: 'false',
        attachedNames: ['fa-web-spa.zip'],
        assets: ['fa-macos-arm64-1.0.685.dmg', 'latest-mac.yml'],
        env: {'RELEASE_GATE_PUBLISHED_SKIP': '1'});
    expect(run.exitCode, 0, reason: run.out);
    expect(run.out, contains('::warning::'),
        reason: 'the skip must stay loud — a green run annotation, not silence');
    expect(run.out, contains('fa-macos-arm64-1.0.685.dmg'),
        reason: 'the skip names what it refused to attach');
    expect(run.out.toLowerCase(), contains('published'));
    expect(run.log.where((l) => l.contains('release upload')), isEmpty,
        reason: 'a skipped attach uploads nothing — gh-2042 AC1 still holds');
    expect(run.log.where((l) => l.contains('release edit')), isEmpty);
  });

  test('gh-2050 policy: mixed list skips the WHOLE call — even the uploadable non-fa asset', () {
    // latest-mac.yml must never land alone on a release whose zips were
    // skipped: electron-updater would fetch a feed of missing files. The
    // skip is all-or-nothing, mirroring the refusal's per-call contract.
    final run = runGate('policy-mixed', releaseState: 'false',
        attachedNames: ['fa-linux-x64.tar.gz'],
        assets: ['fa-linux-x64.tar.gz', 'fa-macos-arm64.tar.gz', 'app-release.aab'],
        env: {'RELEASE_GATE_PUBLISHED_SKIP': '1'});
    expect(run.exitCode, 0, reason: run.out);
    expect(run.out, contains('::warning::'));
    expect(run.log.where((l) => l.contains('release upload')), isEmpty,
        reason: 'no partial mutation on the skip path either');
  });

  test('gh-2050 policy never touches the draft path — drafts attach exactly as before', () {
    final run = runGate('policy-draft', assets: ['fa-linux-x64.tar.gz'],
        env: {'RELEASE_GATE_PUBLISHED_SKIP': '1'});
    expect(run.exitCode, 0, reason: run.out);
    expect(run.out, isNot(contains('::warning::')));
    expect(
      run.log,
      contains('release upload v1.2.3 fa-linux-x64.tar.gz --clobber --repo OWNER/REPO'),
    );
  });

  test('gh-2050 policy: published + all already attached → unchanged immutable skip', () {
    final run = runGate('policy-published-attached', releaseState: 'false',
        attachedNames: ['fa-linux-x64.tar.gz', 'SHA256SUMS', 'SHA256SUMS.sig'],
        assets: ['fa-linux-x64.tar.gz'],
        env: {'RELEASE_GATE_PUBLISHED_SKIP': '1'});
    expect(run.exitCode, 0, reason: run.out);
    expect(run.out, isNot(contains('::warning::')),
        reason: 'nothing was refused — the ordinary immutable skip, not a policy skip');
    expect(run.log.where((l) => l.contains('release upload')), isEmpty);
    expect(run.out.toLowerCase(), contains('skip'));
  });

  test('gh-2050 policy is opt-in: any value but exactly "1" keeps the loud refusal', () {
    // Fail-closed discipline: a loose truthiness ('true', 'yes', stray '0')
    // would let a typo silently re-arm post-publish attaches repo-wide.
    for (final value in ['', 'true', 'yes', '0', 'on']) {
      final run = runGate('policy-optin-$value', releaseState: 'false',
          attachedNames: ['fa-web-spa.zip'], assets: ['fa-macos-arm64.tar.gz'],
          env: {'RELEASE_GATE_PUBLISHED_SKIP': value});
      expect(run.exitCode, isNot(0), reason: 'value "$value" must not enable the skip: ${run.out}');
      expect(run.out, contains('::error::'));
      expect(run.log.where((l) => l.contains('release upload')), isEmpty);
    }
  });

  test('the daily release-macos attach step declares the gh-2050 pre-stage policy', () {
    // The behavioral tests above pin the gate; this pins the CALLER: the
    // daily mac desktop pre-stage attach opts into the policy, so removing
    // the env (and silently re-red-ing the leg) fails tests, not the 06:28
    // daily train.
    final job = jobsOf('.github/workflows/build-macos.yml')['release-macos'] as YamlMap;
    final step = (job['steps'] as YamlList).firstWhere(
      (s) => s is YamlMap && s['name'] == 'Create or update GitHub Release',
    ) as YamlMap;
    final env = step['env'] as YamlMap?;
    expect(env, isNotNull, reason: 'the attach step carries env config');
    expect(env!['RELEASE_GATE_PUBLISHED_SKIP']?.toString(), '1',
        reason: 'the pre-stage attach must opt into the gh-2050 published-skip policy');
  });

  test('missing release → allow (the caller lazy-drafts first; upload surfaces real errors)', () {
    final run = runGate('missing', viewSeq: ['missing'],
        assets: ['fa-linux-x64.tar.gz']);
    expect(run.exitCode, 0, reason: run.out);
    expect(
      run.log,
      contains('release upload v1.2.3 fa-linux-x64.tar.gz --clobber --repo OWNER/REPO'),
    );
  });

  test('API blip (view fails without a not-found verdict) → fail CLOSED, no upload', () {
    final run = runGate('blip', viewSeq: ['error'], assets: ['fa-linux-x64.tar.gz']);
    expect(run.exitCode, isNot(0), reason: run.out);
    expect(run.out, contains('::error::'));
    expect(run.log.where((l) => l.contains('release upload')), isEmpty,
        reason: 'an undeterminable release state must never upload');
  });

  test('garbage state verdict (unparseable isDraft) → fail CLOSED, no upload', () {
    final run = runGate('garbage', releaseState: 'garbage',
        assets: ['fa-linux-x64.tar.gz']);
    expect(run.exitCode, isNot(0), reason: run.out);
    expect(run.out, contains('::error::'));
    expect(run.log.where((l) => l.contains('release upload')), isEmpty);
  });

  test('zero assets → loud refusal (caller bug, mirror of the gh-1801 refusal)', () {
    final dir = Directory(
      '${hygieneFixtureRoot.path}/gate-empty-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final bin = stubGh(dir.path);
    File('${dir.path}/log').writeAsStringSync('');
    final res = Process.runSync('bash', [
      File('scripts/release_asset_gate.sh').absolute.path,
      'v1.2.3',
    ], environment: {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_STUB_DIR': dir.path,
      'GH_LOG_FILE': '${dir.path}/log',
      'GH_TOKEN': 'stub',
    });
    expect(res.exitCode, isNot(0));
    expect('${res.stdout}${res.stderr}', contains('::error::'));
  });
}

class GateRun {
  GateRun(this.exitCode, this.out, this.log);
  final int exitCode;
  final String out;
  final List<String> log;
}
