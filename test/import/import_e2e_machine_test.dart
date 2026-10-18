/// E2E tier (machine-gated, GOAL test matrix): runs against the REAL omp
/// store when one exists on this machine. Discovery and the full read are
/// read-only; nothing is ever written to the developer's own store.
/// Skipped (not failed) unless FA_IMPORT_E2E=1 and a ~/.omp store exists.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/import/foreign_session.dart';
import 'package:flutter_agent_harness/src/import/omp_adapter.dart';
import 'package:test/test.dart';

void main() {
  final home = Platform.environment['HOME'] ?? '';
  final storeReady = home.isNotEmpty &&
      Directory('$home/.omp/agent/sessions').existsSync();
  final e2eEnabled = Platform.environment['FA_IMPORT_E2E'] == '1';

  test('real omp store: discovery + full read of the newest session',
      () async {
    if (!e2eEnabled || !storeReady) {
      markTestSkipped(
        'machine-gated: requires FA_IMPORT_E2E=1 and a real '
        '~/.omp/agent/sessions store',
      );
      // markTestSkipped does NOT halt the body — return so the real-store
      // discovery/read never runs on a machine without the gate.
      return;
    }
    final env = LocalExecutionEnv(cwd: Directory.current.path);
    final adapter = OmpAdapter();
    final summaries = await adapter.discover(
      fs: env,
      cwd: Directory.current.path,
      homeDir: home,
      tempDir: Directory.systemTemp.path,
      limits: const ImportLimits(),
    );
    // The live folder may genuinely have no omp history — discovery must
    // answer that, not crash.
    if (summaries.isEmpty) return;
    summaries.sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
    final parse = await adapter.read(
      fs: env,
      summary: summaries.first,
      homeDir: home,
      limits: const ImportLimits(),
    );
    expect(parse.records, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
