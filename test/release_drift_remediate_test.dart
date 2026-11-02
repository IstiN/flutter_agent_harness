// gh-2042 AC2 — release_drift_remediate.sh: when the drift check finds a
// published release whose assets no longer match the signed SHA256SUMS, the
// run must (a) auto re-request the release-provenance job for the tag (it
// re-hashes the CURRENT assets and re-signs — the same mechanism as the AC3
// v1.0.680 remediation) and (b) page a deduplicated issue so drift never
// lingers.
//
// Behavioral tests over a stubbed `gh` (run list / api jobs / run rerun /
// issue list+create+comment), following the release_hygiene_test.dart style.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory fx;
  late String bin;
  late String logPath;
  late String bodyFile;

  setUp(() {
    fx = Directory.systemTemp.createTempSync('drift-remediate-');
    bin = '${fx.path}/bin';
    Directory(bin).createSync();
    logPath = '${fx.path}/gh.log';
    bodyFile = '${fx.path}/drift.txt';
    File(bodyFile).writeAsStringSync('''
- fa-macos-arm64.tar.gz: manifest cd0eb0e1… ≠ actual 251f0c1c…
- fa-macos-arm64-mac.zip: on the release but not in the manifest
''');
    // Default: the tag run's commit carries the ci.yml flip guard, and the
    // drifted tag IS the current latest — the shapes the re-request is
    // always safe in (gh-2042 review thread 8 r2).
    File('${fx.path}/ci-at-sha.txt').writeAsStringSync('''
current_latest=\$(gh api "repos/\${GITHUB_REPOSITORY}/releases/latest" --jq .tag_name 2>/dev/null || true)
if [ "\$is_draft" = "true" ] || [ "\$current_latest" = "\${GITHUB_REF_NAME}" ]; then
  gh release edit "\${GITHUB_REF_NAME}" --draft=false --latest --repo "\${GITHUB_REPOSITORY}"
fi
''');
    File('${fx.path}/latest-tag.txt').writeAsStringSync('v1.2.3');
    File('$bin/gh').writeAsStringSync(_ghStub);
    Process.runSync('chmod', ['+x', '$bin/gh']);
  });

  tearDown(() => fx.deleteSync(recursive: true));

  RemediateRun run({Map<String, String> extra = const {}}) {
    final res = Process.runSync(
      'bash',
      ['scripts/release_drift_remediate.sh', 'v1.2.3', bodyFile],
      environment: {
        'PATH': '$bin:${Platform.environment['PATH']}',
        'GITHUB_REPOSITORY': 'OWNER/REPO',
        'GH_TOKEN': 'stub',
        'GH_LOG_FILE': logPath,
        'GH_STUB_DIR': fx.path,
        ...extra,
      },
    );
    return RemediateRun(
      res.exitCode,
      '${res.stdout}${res.stderr}',
      File(logPath).existsSync()
          ? File(logPath).readAsLinesSync()
          : const <String>[],
      File('${fx.path}/last-issue-body.md').existsSync()
          ? File('${fx.path}/last-issue-body.md').readAsStringSync()
          : null,
    );
  }

  List<String> logged(List<String> log, String needle) =>
      log.where((l) => l.contains(needle)).toList();

  test('missing remediate script fails the suite loudly', () {
    expect(
      File('scripts/release_drift_remediate.sh').existsSync(),
      isTrue,
      reason: 'scripts/release_drift_remediate.sh must exist (gh-2042 AC2)',
    );
  });

  test(
    'happy path: finds the tag run + provenance job, reruns it, files the drift issue',
    () {
      final r = run();
      expect(r.exitCode, 0, reason: r.out);
      final listCalls = logged(r.log, 'run list');
      expect(listCalls, hasLength(1));
      expect(listCalls.single, contains('--workflow ci.yml'));
      expect(listCalls.single, contains('--branch v1.2.3'));
      final jobsCalls = logged(r.log, 'actions/runs/123/jobs');
      expect(jobsCalls, hasLength(1));
      final reruns = logged(r.log, 'run rerun 123');
      expect(reruns, hasLength(1), reason: 'the re-request must happen');
      expect(
        reruns.single,
        contains('--job 77'),
        reason:
            'the rerun targets the Sign release checksums JOB, '
            'not the whole run (a full rerun would re-attach assets the '
            'immutability gate then refuses)',
      );
      expect(
        logged(r.log, 'issue create'),
        hasLength(1),
        reason: 'drift must page (an issue), not linger',
      );
      expect(r.issueBody, isNotNull);
      expect(r.issueBody!, contains('v1.2.3'));
      expect(
        r.issueBody!,
        contains('fa-macos-arm64.tar.gz'),
        reason: 'the filed issue quotes the drift details',
      );
      expect(
        r.issueBody!,
        contains('re-requested'),
        reason: 'the body records the auto-remediation',
      );
    },
  );

  test(
    'an OPEN drift issue with the same tag → comment, never a duplicate issue',
    () {
      File(
        '${fx.path}/open-issues.tsv',
      ).writeAsStringSync('13\t[release-drift] SHA256SUMS drift on v1.2.3\n');
      final r = run();
      expect(r.exitCode, 0, reason: r.out);
      expect(logged(r.log, 'issue create'), isEmpty);
      expect(logged(r.log, 'issue comment 13'), hasLength(1));
    },
  );

  test(
    'rerun request fails → the issue STILL pages, body names the failure',
    () {
      File('${fx.path}/rerun-fails').writeAsStringSync('');
      final r = run();
      expect(r.exitCode, 0, reason: r.out);
      expect(
        logged(r.log, 'issue create'),
        hasLength(1),
        reason: 'paging must not depend on the re-request succeeding',
      );
      expect(r.issueBody!, contains('re-request FAILED'));
    },
  );

  test(
    'no completed tag run found → the issue still pages (re-request impossible)',
    () {
      File('${fx.path}/no-runs').writeAsStringSync('');
      final r = run();
      expect(r.exitCode, 0, reason: r.out);
      expect(logged(r.log, 'run rerun'), isEmpty);
      expect(logged(r.log, 'issue create'), hasLength(1));
      expect(r.issueBody!, contains('no completed'));
    },
  );

  test(
    'issue filing fails → exit 1 (the only total failure the step can own)',
    () {
      File('${fx.path}/no-runs').writeAsStringSync('');
      File('${fx.path}/issue-fails').writeAsStringSync('');
      final r = run();
      expect(r.exitCode, isNot(0), reason: r.out);
      expect(r.out, contains('::error::'));
    },
  );

  // gh-2042 review thread 8 (r2): `gh run rerun --job` re-executes the job
  // with the workflow file AS IT EXISTED at the original run's commit — a
  // pre-guard tag re-runs the OLD unconditional `--draft=false --latest`
  // flip. Rerunning that job for a tag that is NOT the current latest would
  // drag the Latest badge (and every `fa update` client) backwards onto it.
  test(
    'PRE-GUARD tag run + tag NOT the current latest → re-request REFUSED, issue still pages',
    () {
      File('${fx.path}/ci-at-sha.txt').writeAsStringSync('''
gh release edit "\${GITHUB_REF_NAME}" --draft=false --latest --repo "\${GITHUB_REPOSITORY}"
''');
      File('${fx.path}/latest-tag.txt').writeAsStringSync('v9.9.9');
      final r = run();
      expect(r.exitCode, 0, reason: r.out);
      expect(
        logged(r.log, 'run rerun'),
        isEmpty,
        reason:
            'the re-request must be refused — the old workflow would '
            'drag the Latest badge backwards',
      );
      expect(
        logged(r.log, 'issue create'),
        hasLength(1),
        reason: 'refusal degrades to a human-paged instruction, never silence',
      );
      expect(r.issueBody!, contains('REFUSED'));
      expect(r.issueBody!, contains('predates the gh-2042 ci.yml flip guard'));
    },
  );

  test(
    'PRE-GUARD tag run + tag IS the current latest → re-request proceeds (old flip only re-asserts)',
    () {
      File('${fx.path}/ci-at-sha.txt').writeAsStringSync('''
gh release edit "\${GITHUB_REF_NAME}" --draft=false --latest --repo "\${GITHUB_REPOSITORY}"
''');
      File('${fx.path}/latest-tag.txt').writeAsStringSync('v1.2.3');
      final r = run();
      expect(r.exitCode, 0, reason: r.out);
      expect(
        logged(r.log, 'run rerun 123'),
        hasLength(1),
        reason:
            'safe: the legacy unconditional flip only re-asserts the '
            'badge the tag already holds',
      );
      expect(r.issueBody!, contains('re-requested'));
      expect(r.issueBody!, contains('still the current Latest'));
    },
  );
}

class RemediateRun {
  RemediateRun(this.exitCode, this.out, this.log, this.issueBody);
  final int exitCode;
  final String out;
  final List<String> log;
  final String? issueBody;
}

const String _ghStub = '''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
case "\$1 \$2" in
  "run list")
    if [ -f "\$GH_STUB_DIR/no-runs" ]; then canned='[]'; else canned='[{"databaseId": 123, "conclusion": "success", "headSha": "deadbeefcafe"}, {"databaseId": 99, "conclusion": null, "headSha": "fefe"}]'; fi
    # Emulate gh's --jq: forward the filter the caller passed so the stub
    # survives script-side filter changes.
    jq_filter=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "--jq" ] && jq_filter="\$a"
      prev="\$a"
    done
    printf '%s' "\$canned" | jq -r "\$jq_filter"
    ;;
  "run rerun")
    if [ -f "\$GH_STUB_DIR/rerun-fails" ]; then
      echo "gh: rerun rejected (stub)" >&2
      exit 1
    fi
    ;;
  "api "*)
    if printf '%s' "\$*" | grep -q '/jobs'; then
      printf '%s' '{"jobs":[{"name":"Build native binaries","id":1},{"name":"Sign release checksums","id":77}]}' \\
        | jq '.jobs[] | select(.name == "Sign release checksums") | .id'
    elif printf '%s' "\$*" | grep -q 'contents/.github/workflows/ci.yml'; then
      # The workflow file AS IT EXISTED at the run's commit (base64 content).
      base64 < "\$GH_STUB_DIR/ci-at-sha.txt"
    elif printf '%s' "\$*" | grep -q 'releases/latest'; then
      cat "\$GH_STUB_DIR/latest-tag.txt"
    fi
    ;;
  "issue "*)
    if [ "\$2" = "list" ]; then
      # Emulate gh's --json number,title + --jq title-match: answer the
      # number of an OPEN issue whose title matches --arg t exactly.
      if [ -f "\$GH_STUB_DIR/open-issues.tsv" ]; then
        want=""
        capture=0
        title=""
        for a in "\$@"; do
          if [ "\$capture" = "1" ]; then title="\$a"; capture=0; fi
          [ "\$prev" = "--arg" ] && [ "\$a" = "t" ] && capture=1
          prev="\$a"
        done
        awk -F '\\t' -v t="\$title" '\$2 == t { print \$1 }' "\$GH_STUB_DIR/open-issues.tsv"
      fi
      exit 0
    fi
    if [ "\$2" = "create" ]; then
      if [ -f "\$GH_STUB_DIR/issue-fails" ]; then
        echo "gh: issue create rejected (stub)" >&2
        exit 1
      fi
      while [ \$# -gt 0 ]; do
        if [ "\$1" = "--body-file" ]; then
          cp "\$2" "\$GH_STUB_DIR/last-issue-body.md"
        fi
        shift
      done
      echo "https://github.com/OWNER/REPO/issues/42"
      exit 0
    fi
    if [ "\$2" = "comment" ]; then
      if [ -f "\$GH_STUB_DIR/issue-fails" ]; then
        echo "gh: issue comment rejected (stub)" >&2
        exit 1
      fi
      while [ \$# -gt 0 ]; do
        if [ "\$1" = "--body-file" ]; then
          cp "\$2" "\$GH_STUB_DIR/last-issue-body.md"
        fi
        shift
      done
      exit 0
    fi
    ;;
esac
exit 0
''';
