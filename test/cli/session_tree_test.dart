import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'package:flutter_agent_harness/src/cli/session_tree.dart';
import 'agent_cli_test_support.dart';

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  Future<SessionMetadata> seedSession({
    Map<String, dynamic>? metadata,
    String cwd = '/work',
    String? name,
  }) async {
    final session = await repo.create(
      JsonlSessionCreateOptions(cwd: cwd, metadata: metadata),
    );
    if (name != null) await session.appendSessionName(name);
    return session.getMetadata();
  }

  /// One named main with two children (one named, one unnamed) and a
  /// second named main — the smallest interesting tree.
  Future<void> seedTree() async {
    final parent = await seedSession(
      metadata: {'agent': 'cli', 'model': 'm'},
      name: 'goal_builder',
    );
    await seedSession(
      metadata: {
        'agent': 'subagent',
        'id': 'ag-a',
        'parent': parent.id,
        'model': 'm',
      },
      name: 'explore',
    );
    await seedSession(
      metadata: {
        'agent': 'subagent',
        'id': 'ag-b',
        'parent': parent.id,
        'model': 'm',
      },
    );
    await seedSession(metadata: {'agent': 'app'}, name: 'mobile');
  }

  group('buildSessionListRows', () {
    test('tree mode nests child rows under their numbered parent', () async {
      await seedTree();
      final sessions = sortSessionsCurrentFolderFirst(
        await repo.list(),
        '/work',
      );
      final rows = buildSessionListRows(sessions: sessions, flat: false);
      // Mains numbered sequentially; children unnumbered and indented.
      expect(rows.where((r) => !r.isChild).map((r) => r.number).toList(), [
        1,
        2,
      ]);
      expect(rows.where((r) => r.isChild), hasLength(2));
      expect(rows.where((r) => r.agentCount > 0).map((r) => r.agentCount), [2]);
    });

    test('an orphaned child renders top-level and marked', () async {
      final parent = await seedSession(
        metadata: {'agent': 'cli'},
        name: 'main',
      );
      await seedSession(
        metadata: {'agent': 'subagent', 'parent': 'deleted-parent-id'},
      );
      await seedSession(metadata: {'agent': 'subagent', 'parent': parent.id});
      final rows = buildSessionListRows(
        sessions: await repo.list(),
        flat: false,
      );
      final orphans = rows.where((r) => r.orphaned).toList();
      expect(orphans, hasLength(1));
      expect(orphans.single.isChild, isFalse);
    });

    test('flat mode restores the legacy list: every row numbered', () async {
      await seedTree();
      final sessions = sortSessionsCurrentFolderFirst(
        await repo.list(),
        '/work',
      );
      final rows = buildSessionListRows(sessions: sessions, flat: true);
      expect(rows, hasLength(4));
      expect(rows.map((r) => r.number).toList(), [1, 2, 3, 4]);
      expect(rows.every((r) => !r.isChild), isTrue);
      expect(rows.every((r) => !r.orphaned), isTrue);
    });

    test('unnamed children get a subagent label, named keep their name', () {
      final named = SessionMetadata(
        id: 'child-named',
        createdAt: DateTime.utc(2026, 9, 12),
        cwd: '/work',
        path: '/a.jsonl',
        metadata: {'agent': 'subagent', 'parent': 'p'},
      );
      final rows = buildSessionListRows(
        sessions: [named],
        flat: false,
        names: {'child-named': 'explore'},
      );
      // An orphaned child surfaces top-level with the orphan marker,
      // but keeps its name (or the subagent label when unnamed).
      expect(rows.single.isChild, isFalse);
      expect(rows.single.orphaned, isTrue);
      expect(rows.single.label, 'explore');

      final unnamed = buildSessionListRows(sessions: [named], flat: false);
      expect(unnamed.single.label, startsWith('subagent '));
    });
  });

  group('formatSessionListLines', () {
    test(
      'parent line carries the [+N agents] suffix; children indent',
      () async {
        await seedTree();
        final sessions = sortSessionsCurrentFolderFirst(
          await repo.list(),
          '/work',
        );
        final names = await sessionDisplayNames(repo, sessions);
        final lines = formatSessionListLines(
          buildSessionListRows(sessions: sessions, flat: false, names: names),
        );
        final text = lines.join('\n');
        expect(text, contains('[+2 agents]'));
        expect(text, contains('↳'));
        // Mains show the plain name; children stay indented beneath.
        expect(text, contains('goal_builder'));
        expect(text, contains('explore'));
      },
    );

    test('the active session row is starred', () async {
      final only = await seedSession(metadata: {'agent': 'cli'});
      final lines = formatSessionListLines([
        buildSessionListRows(
          sessions: [only],
          flat: false,
          currentSessionPath: only.path,
        ).single,
      ]);
      expect(lines.single, contains('*'));
    });
  });

  group('runSessionListCliCommand (headless fa session list)', () {
    test('--json emits NDJSON rows carrying agent and parent', () async {
      await seedTree();
      final io = FakeCliIO();
      final code = await runSessionListCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: fs,
        sessionRoot: '/sessions',
        cwd: '/work',
        json: true,
        flat: false,
      );
      expect(code, 0);
      final rows = [
        for (final line in io.out.toString().split('\n'))
          if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
      ];
      expect(rows, hasLength(4));
      expect(rows.where((r) => r['agent'] == 'subagent'), hasLength(2));
      expect(
        rows.where((r) => r['agent'] == 'subagent').map((r) => r['parent']),
        everyElement(isNotNull),
      );
      expect(
        rows.where((r) => r['agent'] == 'subagent').map((r) => r['name']),
        contains('explore'),
      );
      // Additive, non-breaking: every row still carries the core fields.
      expect(rows.every((r) => r.containsKey('cwd')), isTrue);
      expect(rows.every((r) => r.containsKey('createdAt')), isTrue);
    });

    test(
      'text mode prints the tree; --flat restores the legacy view',
      () async {
        await seedTree();
        final io = FakeCliIO();
        await runSessionListCliCommand(
          write: io.write,
          writeln: io.writeln,
          env: fs,
          sessionRoot: '/sessions',
          cwd: '/work',
          json: false,
          flat: false,
        );
        expect(io.out.toString(), contains('[+2 agents]'));
        expect(io.out.toString(), contains('↳'));

        final flatIo = FakeCliIO();
        await runSessionListCliCommand(
          write: flatIo.write,
          writeln: flatIo.writeln,
          env: fs,
          sessionRoot: '/sessions',
          cwd: '/work',
          json: false,
          flat: true,
        );
        expect(flatIo.out.toString(), isNot(contains('↳')));
        expect(flatIo.out.toString(), isNot(contains('[+2 agents]')));
      },
    );
  });
}
