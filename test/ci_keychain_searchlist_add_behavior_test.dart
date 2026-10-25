// gh-1866 review thread 4 — a FAILED `security list-keychains -d user
// -s <union>` write (transient `security` error, keychain file
// momentarily unavailable) used to kill scripts/keychain_searchlist_add.sh
// immediately under `set -euo pipefail`: raw exit code, no retry, no
// `::error::` annotation, no gh-1866 breadcrumb in the log. Only the
// *write-succeeded-but-was-clobbered* (eviction) case was retried.
//
// Behavioral guard (TDD RED before the fix): the helper is executed
// with a MOCKED `security` on PATH that (a) fails the fixed-list write a
// bounded number of times, then succeeds — the helper must converge and
// exit 0 — and (b) fails the write persistently — the helper must exit
// 1 with a loud `::error::` line naming gh-1866, not `security`'s raw
// exit code. The keychain paths are fake (the helper never opens the
// keychain file itself; create/import live in the calling workflow).
@TestOn('posix')
library;

import 'dart:io';

import 'package:test/test.dart';

/// A `security` stub: state file = the current user search list (one
/// path per line). `list-keychains -d user` prints it back padded and
/// quoted like the real tool; `list-keychains -d user -s <paths...>`
/// REPLACES it, failing with exit 1 while the `SEC_MOCK_FAILS_LEFT`
/// counter is positive.
final _mockSecurity = r'''
#!/bin/bash
set -u
STATE="$SEC_MOCK_STATE"
if [ "$1" = "list-keychains" ] && [ "$2" = "-d" ] && [ "$3" = "user" ]; then
  if [ "$#" -eq 3 ]; then
    if [ -f "$STATE" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && printf '    "%s"\n' "$line"
      done < "$STATE"
    fi
    exit 0
  fi
  if [ -n "${SEC_MOCK_FAILS:-}" ] && [ -f "$SEC_MOCK_FAILS" ] && [ "$(cat "$SEC_MOCK_FAILS")" -gt 0 ]; then
    echo $(( $(cat "$SEC_MOCK_FAILS") - 1 )) > "$SEC_MOCK_FAILS"
    echo "security: transient failure (mock)" >&2
    exit 1
  fi
  : > "$STATE"
  for p in "${@:4}"; do printf '%s\n' "$p" >> "$STATE"; done
  exit 0
fi
echo "mock security: unsupported invocation: $*" >&2
exit 2
''';

final _helperPath = 'scripts/keychain_searchlist_add.sh';

/// Runs the helper with the mock `security` first on PATH. Returns the
/// completed process.
ProcessResult _runHelper(Directory mockDir, {required String keychain}) {
  final env = Map<String, String>.from(Platform.environment)
    ..['PATH'] =
        // POSIX PATH-list separator (the tests are @TestOn('posix')).
        '${mockDir.path}:${Platform.environment['PATH']}'
    ..['SEC_MOCK_STATE'] = '${mockDir.path}/search-list.txt'
    ..['SEC_MOCK_FAILS'] = '${mockDir.path}/fails-left.txt'
    ..['KSLA_RETRY_DELAY'] = '0'; // keep the bounded-retry paths fast
  return Process.runSync('bash', [_helperPath, keychain], environment: env);
}

void main() {
  late Directory mockDir;

  setUp(() {
    mockDir = Directory.systemTemp.createTempSync('kc-add-mock-');
    final mockSecurity = File('${mockDir.path}/security')
      ..writeAsStringSync(_mockSecurity);
    Process.runSync('chmod', <String>['755', mockSecurity.path]);
    File('${mockDir.path}/fails-left.txt').writeAsStringSync('0');
  });

  tearDown(() => mockDir.deleteSync(recursive: true));

  test('transient write failure is retried and converges (exit 0, '
      'keychain present in the final list)', () {
    File('${mockDir.path}/fails-left.txt').writeAsStringSync('1');
    final keychain = '${mockDir.path}/job.keychain-db';
    final result = _runHelper(mockDir, keychain: keychain);

    expect(
      result.exitCode,
      0,
      reason:
          'the helper must treat a failed (non-clobbered) write like an '
          'eviction and spend one of its bounded attempts on it — a '
          'single transient `security` error must not kill the step '
          '(gh-1866 review thread 4). stderr: ${result.stderr}',
    );
    final finalList =
        File('${mockDir.path}/search-list.txt').readAsStringSync();
    expect(
      finalList.split('\n'),
      containsAll(<String>[keychain]),
      reason:
          'after the retry the union must contain the requested '
          'keychain. Final list:\n$finalList',
    );
    expect(
      (result.stderr as String).toLowerCase(),
      contains('write failed'),
      reason:
          'a failed write must be logged as such so the retry is '
          'visible in the job log, not silent.',
    );
  });

  test('persistent write failure exits 1 with a loud ::error:: '
      'annotation naming gh-1866 — not security\'s raw exit code', () {
    // Fails_left stays effectively infinite: 5 attempts exhaust it.
    File('${mockDir.path}/fails-left.txt').writeAsStringSync('99');
    final result = _runHelper(mockDir, keychain: 'job.keychain-db');

    expect(
      result.exitCode,
      1,
      reason:
          'when the write keeps failing the helper must give up '
          'loudly (bounded), not propagate `security`\'s raw exit '
          'code from an immediate `set -e` death. stderr: '
          '${result.stderr}',
    );
    expect(
      result.stderr,
      contains('::error::'),
      reason:
          'the persistent-failure path must annotate the log with '
          '::error:: so the step is flagged red with context '
          '(gh-1866 review thread 4). stderr: ${result.stderr}',
    );
    expect(
      result.stderr,
      contains('gh-1866'),
      reason:
          'the failure annotation must carry the gh-1866 breadcrumb '
          'for incident forensics. stderr: ${result.stderr}',
    );
  });

  test('write failure path also honors the survival verify: a mock '
      'that accepts writes but drops the entry is still caught '
      '(regression: eviction path unchanged)', () {
    // Mock variant: writes "succeed" but never persist the requested
    // keychain — simulates an external fixed-list stomper racing every
    // write. The helper must retry bounded and fail loudly.
    final stomper = File('${mockDir.path}/security');
    stomper.writeAsStringSync('''
#!/bin/bash
set -u
STATE="\$SEC_MOCK_STATE"
if [ "\$1" = "list-keychains" ] && [ "\$2" = "-d" ] && [ "\$3" = "user" ]; then
  if [ "\$#" -eq 3 ]; then
    printf '%s\\n' "\$HOME/Library/Keychains/login.keychain-db"
    exit 0
  fi
  exit 0
fi
exit 2
''');
    Process.runSync('chmod', <String>['755', stomper.path]);
    final result = _runHelper(mockDir, keychain: 'job.keychain-db');
    expect(result.exitCode, 1);
    expect(result.stderr, contains('::error::'));
  });
}
