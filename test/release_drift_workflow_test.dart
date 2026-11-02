// gh-2042 — workflow + wiring shape guards.
//
// AC1: a published release is immutable for `fa-*` assets — every workflow
// attach path of an fa-* asset routes through scripts/release_asset_gate.sh
// (the only place `gh release upload` of an fa-* asset may happen), and the
// attach-or-create script routes through the gate too.
// AC2: a release-drift-watch workflow re-verifies the published assets
// against the signed SHA256SUMS after every publish AND on a schedule, and
// pages + auto re-requests release-provenance on drift.
// AC4 (REG): the gh-1832 required-assets gate, the gh-814 trust-anchor drift
// gate and the signature self-check stay exactly where they are, and the
// provenance publish point keeps its signed-manifest precondition.
//
// Static lint over the workflows/scripts — the repo's workflow-shape
// never-again pattern (see ci_release_pending_guard_test.dart).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String workflowPath) =>
    (loadYaml(read(workflowPath))['jobs']) as YamlMap;

/// `gh release upload` invocations (continuation lines joined) in a workflow.
List<String> uploadBlocks(String workflowPath) {
  final lines = read(workflowPath).split('\n');
  final blocks = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].contains('gh release upload')) continue;
    final block = <String>[lines[i]];
    while (block.last.trimRight().endsWith(r'\') && i < lines.length - 1) {
      i++;
      block.add(lines[i]);
    }
    blocks.add(block.join(' '));
  }
  return blocks;
}

void main() {
  group('AC1 — every fa-* attach path routes through the immutability gate', () {
    test('scripts/release_asset_gate.sh exists and uploads with --clobber', () {
      final gate = read('scripts/release_asset_gate.sh');
      expect(
        gate,
        contains('--clobber'),
        reason: 'the gate performs the attach (or the immutable skip)',
      );
      expect(
        gate,
        contains('isDraft'),
        reason: 'the gate decides on the draft/published state',
      );
      expect(
        gate,
        contains('fa-'),
        reason: 'the immutability class is exactly the fa-* asset set',
      );
    });

    test('release_attach_or_create.sh routes uploads through the gate', () {
      final attach = read('scripts/release_attach_or_create.sh');
      expect(
        attach,
        contains('release_asset_gate.sh'),
        reason:
            'the attach-or-create upload path is the v1.0.680 hole — '
            'every upload must pass the gate',
      );
    });

    test(
      'ci.yml + build-macos.yml: bare `gh release upload` lines are SHA256SUMS-only (provenance)',
      () {
        // The provenance manifest upload is the ONLY raw upload allowed in
        // these workflows: SHA256SUMS(.sig) is not an fa-* asset, and
        // re-uploading it is the sanctioned post-publish remediation
        // (re-running release-provenance for the tag).
        // The provenance manifest upload is the ONLY raw upload allowed:
        // SHA256SUMS(.sig) is not an fa-* asset, and re-uploading it is the
        // sanctioned post-publish remediation (re-running release-provenance
        // for the tag, gh-2042 AC3). build-macos.yml has no provenance job —
        // it must have NO raw upload at all.
        {
          final uploads = uploadBlocks('.github/workflows/build-macos.yml');
          expect(
            uploads,
            isEmpty,
            reason:
                'build-macos.yml: raw `gh release upload` must not exist — '
                'every fa-* attach routes through scripts/release_asset_gate.sh',
          );
        }
        {
          final uploads = uploadBlocks('.github/workflows/ci.yml');
          expect(
            uploads,
            isNotEmpty,
            reason: 'ci.yml keeps its provenance upload',
          );
          for (final line in uploads) {
            expect(
              line,
              contains('SHA256SUMS'),
              reason:
                  'ci.yml: "$line" uploads an fa-* asset raw — route it through '
                  'scripts/release_asset_gate.sh (gh-2042 AC1: a published '
                  'release is immutable for fa-* assets)',
            );
          }
        }
      },
    );

    test(
      'every fa-* upload call site invokes the gate (ci.yml binaries/web-spa/extension, build-macos legs)',
      () {
        for (final wf in [
          '.github/workflows/ci.yml',
          '.github/workflows/build-macos.yml',
        ]) {
          expect(
            read(wf),
            contains('release_asset_gate.sh'),
            reason: '$wf attaches fa-* assets — the gate must guard them',
          );
        }
      },
    );
  });

  group('AC2 — the release drift watch workflow', () {
    const wfPath = '.github/workflows/release-drift-watch.yml';

    test('workflow exists with publish + schedule + dispatch triggers', () {
      expect(
        File(wfPath).existsSync(),
        isTrue,
        reason: '$wfPath must exist (gh-2042 AC2)',
      );
      final y = loadYaml(read(wfPath)) as YamlMap;
      final on = y['on'] as YamlMap;
      expect(
        (on['release'] as YamlMap)['types'].toString(),
        contains('published'),
        reason: 'after every release publish',
      );
      expect(
        on['schedule'],
        isNotNull,
        reason: 'and on a schedule — drift must not linger',
      );
      expect(
        (on['workflow_dispatch'] as YamlMap)['inputs'],
        isNotNull,
        reason: 'dispatch is the manual remediation vehicle (any tag)',
      );
    });

    test(
      'the job is bounded, least-privileged, and runs the check + remediation',
      () {
        final jobs = jobsOf(wfPath);
        expect(jobs, hasLength(1));
        final job = jobs.values.first as YamlMap;
        expect(
          job['timeout-minutes'],
          isNotNull,
          reason: 'every job carries an explicit ceiling',
        );
        final perms = job['permissions'] as YamlMap;
        expect(
          perms['contents'].toString(),
          contains('read'),
          reason: 'downloads the release assets',
        );
        expect(
          perms['actions'].toString(),
          contains('write'),
          reason: 'the drift auto re-request reruns the provenance job',
        );
        expect(
          perms['issues'].toString(),
          contains('write'),
          reason: 'drift pages via a deduplicated issue',
        );
        final steps = (job['steps'] as YamlList)
            .map((s) => s.toString())
            .join('\n');
        expect(
          steps,
          contains('if: failure()'),
          reason: 'remediation fires exactly on a red check',
        );
        expect(
          steps,
          contains('release_drift_check.sh'),
          reason:
              'the re-download + digest diff live in the repo-owned script '
              '(asserted behaviorally in release_drift_check_test.dart)',
        );
        expect(
          steps,
          contains('release_drift_remediate.sh'),
          reason: 'the drift path pages + re-requests provenance',
        );
        expect(
          steps,
          contains('if: failure()'),
          reason: 'remediation fires exactly on a red check',
        );
      },
    );
  });

  group('gh-2042 review rework — repo hygiene + shell-injection posture', () {
    const wfPath = '.github/workflows/release-drift-watch.yml';

    List<String> runBlocks(String workflowPath) {
      final jobs = jobsOf(workflowPath);
      final blocks = <String>[];
      for (final job in jobs.values) {
        for (final step in (job as YamlMap)['steps'] as YamlList) {
          final run = (step as YamlMap)['run'];
          if (run != null) blocks.add(run.toString());
        }
      }
      return blocks;
    }

    test(
      'no committed test-run residue at the repo root (release-notes.md / drift-details.txt)',
      () {
        // Both files are CWD artifacts of the release scripts run with
        // fixture values — they were committed by accident and regenerated
        // byte-identical on every `dart test` run. The branch must not track
        // them, and .gitignore must keep them from coming back.
        final gitignore = read('.gitignore');
        for (final artifact in ['release-notes.md', 'drift-details.txt']) {
          expect(
            File(artifact).existsSync(),
            isFalse,
            reason: '$artifact is test-run residue — delete it from the branch',
          );
          expect(
            RegExp(
              '^/?${RegExp.escape(artifact)}'
              r'\s*$',
              multiLine: true,
            ).hasMatch(gitignore),
            isTrue,
            reason:
                '$artifact must be gitignored (a CWD artifact of the release scripts)',
          );
        }
      },
    );

    test(
      'no untrusted template interpolation into run: shells — env indirection (gh-2042 review thread 4)',
      () {
        // A tag value carrying shell metacharacters must never reach a run:
        // block via ${{ }} — inputs.tag, github.event.release.tag_name and
        // step outputs ride env vars (the GitHub Actions security-hardening
        // guide's env-var indirection pattern).
        for (final block in runBlocks(wfPath)) {
          expect(
            block.contains('{{ inputs.'),
            isFalse,
            reason:
                'inputs.tag must be env-indirected, not interpolated '
                'into the shell: "${block.substring(0, block.length.clamp(0, 120))}"',
          );
          expect(
            block.contains('{{ github.event.release.'),
            isFalse,
            reason: 'github.event.release.tag_name must be env-indirected',
          );
          expect(
            block.contains('{{ steps.target.outputs.'),
            isFalse,
            reason:
                r'step outputs must be env-indirected (env: TAG: ... → "$TAG")',
          );
        }
        // The indirection itself must exist.
        final wf = read(wfPath);
        expect(
          wf,
          contains(r'DISPATCH_TAG: ${{ inputs.tag }}'),
          reason: 'the dispatch input rides an env var',
        );
        expect(
          wf,
          contains(r'RELEASE_EVENT_TAG: ${{ github.event.release.tag_name }}'),
          reason: 'the release-event tag rides an env var',
        );
        expect(
          wf,
          contains(r'TAG: ${{ steps.target.outputs.tag }}'),
          reason: 'the resolved tag reaches the check/remediate steps via env',
        );
      },
    );

    test(
      'the remediation step pages ONLY on a non-empty drift details file (gh-2042 review thread 6)',
      () {
        // An infra/transport failure (drift-check exit 2) writes NO details
        // file — the run stays red but must NOT file a drift issue or
        // re-request provenance for a release whose provenance is intact.
        final jobs = jobsOf(wfPath);
        final pageStep = ((jobs.values.first as YamlMap)['steps'] as YamlList)
            .whereType<YamlMap>()
            .firstWhere((s) => (s['name']?.toString() ?? '').contains('Page'));
        final body = pageStep['run'].toString();
        expect(
          body,
          contains('[ -s'),
          reason: 'the page/re-request is gated on a non-empty details file',
        );
        expect(
          body,
          contains('drift-details.txt'),
          reason: 'the gated file is the check script\'s details output',
        );
      },
    );
  });

  group('AC4 (REG) — the existing release gates stay exactly where they are', () {
    test(
      'gh-1832 required-assets gate stays a publish-blocking provenance step',
      () {
        final prov =
            jobsOf('.github/workflows/ci.yml')['release-provenance'] as YamlMap;
        final steps = (prov['steps'] as YamlList)
            .map((s) => s['name']?.toString() ?? '')
            .toList();
        expect(
          steps,
          contains('Assert required release assets (gh-1832 gate)'),
          reason: 'no path publishes assets without the required set',
        );
      },
    );

    test(
      'gh-814 trust-anchor drift gate + signature self-check stay in the sign step',
      () {
        final prov =
            jobsOf('.github/workflows/ci.yml')['release-provenance'] as YamlMap;
        final signStep = (prov['steps'] as YamlList)
            .whereType<YamlMap>()
            .firstWhere((s) => s['name'] == 'Build and sign SHA256SUMS');
        final body = signStep['run'].toString();
        expect(
          body,
          contains('openssl dgst -sha256 -verify'),
          reason: 'the signature self-check stays',
        );
        expect(
          body,
          contains('site/install.sh'),
          reason: 'the gh-814 trust-anchor drift gate stays',
        );
      },
    );

    test(
      'the provenance publish point keeps its signed-manifest precondition',
      () {
        final prov =
            jobsOf('.github/workflows/ci.yml')['release-provenance'] as YamlMap;
        final uploadStep = (prov['steps'] as YamlList)
            .whereType<YamlMap>()
            .firstWhere((s) => s['name'] == 'Upload provenance assets');
        final body = uploadStep['run'].toString();
        expect(body, contains('SHA256SUMS'));
        expect(
          body,
          contains('--draft=false --latest'),
          reason: 'the flip stays provenance-owned (gh-1801)',
        );
      },
    );

    test(
      'the provenance flip never drags `latest` backwards (gh-2042 BLOCKING review thread)',
      () {
        // The drift remediation re-requests the "Sign release checksums" job
        // for an OLD drifted tag; a rerun re-executes this step with the
        // original run's ref. An unconditional `--latest` would re-flag that
        // older release as Latest — pointing every `fa update` client DOWN at
        // it (the re-signed manifest makes the downgrade pass provenance).
        // The flip must carry --latest ONLY when the release is still a draft
        // (the normal publish point) or is already the current latest.
        final prov =
            jobsOf('.github/workflows/ci.yml')['release-provenance'] as YamlMap;
        final uploadStep = (prov['steps'] as YamlList)
            .whereType<YamlMap>()
            .firstWhere((s) => s['name'] == 'Upload provenance assets');
        final body = uploadStep['run'].toString();
        expect(
          body,
          contains('isDraft'),
          reason: 'the --latest flip is gated on the draft state',
        );
        expect(
          body,
          contains('releases/latest'),
          reason: 'and on the tag actually being the current latest',
        );
        expect(
          RegExp(r'--draft=false --repo').hasMatch(body),
          isTrue,
          reason:
              'a non-latest published tag must be re-signed/published '
              'WITHOUT --latest (the fallback branch exists)',
        );
        expect(
          body,
          contains('gh-2042'),
          reason: 'the guard names the incident it prevents',
        );
      },
    );

    test(
      'naming consistency: the immutability suite is spelled immutability',
      () {
        // gh-2042 review thread 10: the publish-immutability suite landed as
        // `release_publish_imutability_test.dart` (one t). Naming is part of
        // the PR's contract surface — the verify command, review replies and
        // docs all name this file — so the misspelling must not come back.
        expect(
          File('test/release_publish_immutability_test.dart').existsSync(),
          isTrue,
          reason: 'the suite lives at the correctly-spelled path',
        );
        expect(
          File('test/release_publish_imutability_test.dart').existsSync(),
          isFalse,
          reason: 'the one-t misspelled filename must not exist',
        );
      },
    );
  });
}
