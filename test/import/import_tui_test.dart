import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/src/cli/agent_cli.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

/// IT tier for the `/import` TUI flow (GOAL AC3 at the host-seam level):
/// harness picker registration + items, the session-search rows with
/// previews, CONTENT keyword search through the host rebuild callback,
/// one/all import through the same runner, and the pending-spike harness
/// behavior. The dart_tui key machinery itself is E2E tier (machine-gated).
void main() {
  late Directory home;
  late Directory project;
  late Directory faRoot;
  late LocalExecutionEnv env;
  late FakeCliIO io;

  String fixture(String name) => File(
    'test/import/fixtures/$name',
  ).readAsStringSync().replaceAll('__CWD__', project.path);

  // Local getters are invalid Dart — a local function closing over the
  // `late` temp dirs that setUp assigns.
  String ompBucket() =>
      '${home.path}/.omp/agent/sessions/--${project.path
          .replaceFirst('/', '')
          .replaceAll('/', '-')}--';

  setUp(() {
    home = Directory.systemTemp.createTempSync('fa_import_tui_home');
    project = Directory.systemTemp.createTempSync('fa_import_tui_proj');
    faRoot = Directory.systemTemp.createTempSync('fa_import_tui_fa');
    Directory(ompBucket()).createSync(recursive: true);
    File('${ompBucket()}/modern.jsonl').writeAsStringSync(
      fixture('omp_modern.jsonl'),
    );
    File('${ompBucket()}/legacy.jsonl').writeAsStringSync(
      fixture('omp_legacy.jsonl'),
    );
    env = LocalExecutionEnv(cwd: project.path);
    io = FakeCliIO();
  });

  tearDown(() {
    io.close();
    home.deleteSync(recursive: true);
    project.deleteSync(recursive: true);
    faRoot.deleteSync(recursive: true);
  });

  AgentCli cliFor() => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: faRoot.path,
      homeDir: home.path,
      providerKind: 'openai-completions',
    ),
    io: io,
    streamFunction: FakeStreamFunction([textTurn('ok')]).call,
  );

  test('the harness picker lists all four harnesses with the two spikes',
      () async {
    final cli = cliFor();
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    await cli.openImportHarnessPickerForTest();
    final keys = cli.importHarnessItemsForTest!.map((i) => i.key).toList();
    expect(keys, ['omp', 'claude', 'opencode', 'kimi']);

    io.sendLine('/exit');
    await run;
  });

  test('a pending-spike harness answers and writes nothing', () async {
    final cli = cliFor();
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    await cli.tuiPickImportHarnessForTest('kimi');
    expect(io.out.toString(), contains('pending its format discovery spike'));
    // The live boot itself creates the current-folder bucket here; the
    // contract is that the pending-spike pick writes NOTHING importer-
    // owned (same marker filter the 'selecting All' test below uses).
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: faRoot.path);
    final imported = [
      for (final session in await repo.list(cwd: project.path))
        if ((session.metadata?['importedFrom'] as Map?)?['sourceId'] != null)
          session,
    ];
    expect(imported, isEmpty);

    io.sendLine('/exit');
    await run;
  });

  test('picking omp opens rows with previews; keyword search matches '
      'session CONTENT (AC3/F10/F11)', () async {
    final cli = cliFor();
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    await cli.tuiPickImportHarnessForTest('omp');
    final rows = cli.importSessionMenuForTest('');
    // `All (<n> sessions)` first, then one row per discovered session.
    expect(rows.first.key, 'all');
    expect(rows.first.label, 'All (2 sessions)');
    final labels = rows.skip(1).map((i) => i.label).toList();
    expect(labels, contains('Fix the login flow'));
    expect(labels, contains('Legacy session'));
    // Previews carry the first/last message text, bounded at 160 chars.
    final modernRow = rows.firstWhere((r) => r.label == 'Fix the login flow');
    expect(modernRow.description, contains('first: please fix the login flow'));
    final legacyRow = rows.firstWhere((r) => r.label == 'Legacy session');
    expect(legacyRow.description, contains('first: hello from legacy'));
    expect(legacyRow.description, contains('last: legacy answer'));

    // Keyword search over CONTENT (not just titles): a query from the
    // session BODY finds it; the same query misses untitled sessions.
    final hit = cli.importSessionMenuForTest('login flow');
    expect(
      hit.map((i) => i.label),
      contains('Fix the login flow'),
    );
    final bodyHit = cli.importSessionMenuForTest('legacy answer');
    expect(bodyHit.map((i) => i.label), contains('Legacy session'));
    final miss = cli.importSessionMenuForTest('zzz-no-such-content');
    expect(miss, hasLength(1), reason: 'only the All row survives a dead query');

    io.sendLine('/exit');
    await run;
  });

  test('selecting All imports every discovered session into the store',
      () async {
    final cli = cliFor();
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    await cli.tuiPickImportHarnessForTest('omp');
    await cli.tuiPickImportSessionForTest('all');

    expect(io.out.toString(), contains('imported 1f9d2a6b'));
    expect(io.out.toString(), contains('imported legacy-0001'));
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: faRoot.path);
    // Count only importer-owned sessions — the live CLI boot may keep its
    // own (empty) session file in the same bucket.
    final imported = [
      for (final session in await repo.list(cwd: project.path))
        if ((session.metadata?['importedFrom'] as Map?)?['sourceId'] != null)
          session,
    ];
    expect(imported, hasLength(2));

    // Re-importing the same rows skips idempotently (E6 in the TUI too);
    // the skip line carries the FULL sourceId (runner format).
    await cli.tuiPickImportSessionForTest('all');
    expect(
      io.out.toString(),
      contains(
        'skipped 1f9d2a6b-9c0d-4f34-a111-000000000001 (already imported)',
      ),
    );

    io.sendLine('/exit');
    await run;
  });
}
