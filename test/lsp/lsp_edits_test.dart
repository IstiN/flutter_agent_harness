@Timeout(Duration(seconds: 10))
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  LspTextEdit edit(
    int startLine,
    int startChar,
    int endLine,
    int endChar,
    String newText,
  ) => LspTextEdit(
    range: LspRange(
      start: LspPosition(line: startLine, character: startChar),
      end: LspPosition(line: endLine, character: endChar),
    ),
    newText: newText,
  );

  group('applyTextEditsToString', () {
    test('single-line replacement', () {
      final result = applyTextEditsToString('hello world', [
        edit(0, 6, 0, 11, 'dart'),
      ]);
      expect(result, 'hello dart');
    });

    test('multi-line splice', () {
      final result = applyTextEditsToString('ab\ncd\nef', [
        edit(0, 1, 2, 1, 'X'),
      ]);
      expect(result, 'aXf');
    });

    test('two edits apply bottom-to-top without shifting', () {
      final result = applyTextEditsToString('one\ntwo\nthree', [
        edit(0, 0, 0, 3, 'ONE'),
        edit(2, 0, 2, 5, 'THREE'),
      ]);
      expect(result, 'ONE\ntwo\nTHREE');
    });

    test('inserts at the same position land in array order', () {
      final result = applyTextEditsToString('x', [
        edit(0, 1, 0, 1, 'A'),
        edit(0, 1, 0, 1, 'B'),
      ]);
      // Bottom-up application: later array entries apply first, so the
      // result preserves the array order (LSP spec).
      expect(result, 'xAB');
    });

    test('duplicate identical edits collapse', () {
      final result = applyTextEditsToString('hello world', [
        edit(0, 6, 0, 11, 'dart'),
        edit(0, 6, 0, 11, 'dart'),
      ]);
      expect(result, 'hello dart');
    });

    test('overlapping edits throw', () {
      expect(
        () => applyTextEditsToString('hello', [
          edit(0, 0, 0, 3, 'A'),
          edit(0, 2, 0, 5, 'B'),
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('overlapping LSP edits'),
          ),
        ),
      );
    });

    test('out-of-bounds edits throw', () {
      expect(
        () => applyTextEditsToString('one line', [edit(4, 0, 4, 1, 'x')]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('out of bounds'),
          ),
        ),
      );
    });
  });

  group('LspWorkspaceEdit.fromJson', () {
    test('parses the legacy changes map', () {
      final parsed = LspWorkspaceEdit.fromJson({
        'changes': {
          'file:///ws/a.dart': [
            {
              'range': {
                'start': {'line': 0, 'character': 0},
                'end': {'line': 0, 'character': 3},
              },
              'newText': 'new',
            },
          ],
        },
      });
      expect(parsed, isNotNull);
      expect(parsed!.textEdits['file:///ws/a.dart'], hasLength(1));
      expect(parsed.skippedResourceOps, 0);
    });

    test('parses documentChanges with versions', () {
      final parsed = LspWorkspaceEdit.fromJson({
        'documentChanges': [
          {
            'textDocument': {'uri': 'file:///ws/a.dart', 'version': 7},
            'edits': [
              {
                'range': {
                  'start': {'line': 1, 'character': 0},
                  'end': {'line': 1, 'character': 2},
                },
                'newText': 'x',
              },
            ],
          },
          {'kind': 'create', 'uri': 'file:///ws/new.dart'},
        ],
      });
      expect(parsed!.textEdits['file:///ws/a.dart'], hasLength(1));
      expect(parsed.documentVersions['file:///ws/a.dart'], 7);
      expect(parsed.skippedResourceOps, 1);
    });

    test('returns null for non-map input', () {
      expect(LspWorkspaceEdit.fromJson('nope'), isNull);
      expect(LspWorkspaceEdit.fromJson(null), isNull);
    });
  });

  group('applyWorkspaceEdit', () {
    late MemoryExecutionEnv env;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/ws');
    });

    LspWorkspaceEdit workspaceEdit(Map<String, List<LspTextEdit>> edits) =>
        LspWorkspaceEdit(
          textEdits: {
            for (final entry in edits.entries)
              fileToUri(entry.key): entry.value,
          },
        );

    test('applies edits across files and reports counts', () async {
      await env.writeFile('/ws/a.dart', 'hello world\n');
      await env.writeFile('/ws/b.dart', 'foo bar\n');

      final applied = await applyWorkspaceEdit(
        env,
        workspaceEdit({
          '/ws/a.dart': [edit(0, 6, 0, 11, 'dart')],
          '/ws/b.dart': [edit(0, 0, 0, 3, 'baz')],
        }),
      );

      expect(
        (await env.readTextFile('/ws/a.dart')).valueOrNull,
        'hello dart\n',
      );
      expect((await env.readTextFile('/ws/b.dart')).valueOrNull, 'baz bar\n');
      expect(applied, hasLength(2));
      final a = applied.firstWhere((c) => c.path == '/ws/a.dart');
      expect(a.editCount, 1);
      expect(a.format('/ws'), 'Applied 1 edit(s) to a.dart');
    });

    test(
      'is atomic: a conflict in one file leaves every file untouched',
      () async {
        await env.writeFile('/ws/a.dart', 'hello world\n');
        await env.writeFile('/ws/b.dart', 'foo bar\n');

        await expectLater(
          applyWorkspaceEdit(
            env,
            workspaceEdit({
              '/ws/a.dart': [edit(0, 6, 0, 11, 'dart')],
              '/ws/b.dart': [
                edit(0, 0, 0, 3, 'x'),
                edit(0, 2, 0, 5, 'y'), // overlaps the previous edit
              ],
            }),
          ),
          throwsA(isA<StateError>()),
        );

        expect(
          (await env.readTextFile('/ws/a.dart')).valueOrNull,
          'hello world\n',
        );
        expect((await env.readTextFile('/ws/b.dart')).valueOrNull, 'foo bar\n');
      },
    );

    test('a missing target file fails before any write', () async {
      await env.writeFile('/ws/a.dart', 'hello world\n');
      await expectLater(
        applyWorkspaceEdit(
          env,
          workspaceEdit({
            '/ws/a.dart': [edit(0, 6, 0, 11, 'dart')],
            '/ws/gone.dart': [edit(0, 0, 0, 1, 'x')],
          }),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await env.readTextFile('/ws/a.dart')).valueOrNull,
        'hello world\n',
      );
    });

    test('version guard rejects a stale edit before any write', () async {
      await env.writeFile('/ws/a.dart', 'hello world\n');
      final stale = LspWorkspaceEdit(
        textEdits: {
          fileToUri('/ws/a.dart'): [edit(0, 6, 0, 11, 'dart')],
        },
        documentVersions: {fileToUri('/ws/a.dart'): 3},
      );
      await expectLater(
        applyWorkspaceEdit(
          env,
          stale,
          openFileVersions: {fileToUri('/ws/a.dart'): 5},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('stale LSP edit'),
          ),
        ),
      );
      expect(
        (await env.readTextFile('/ws/a.dart')).valueOrNull,
        'hello world\n',
      );
    });

    test('version guard passes when versions match or are unknown', () async {
      await env.writeFile('/ws/a.dart', 'hello world\n');
      final matching = LspWorkspaceEdit(
        textEdits: {
          fileToUri('/ws/a.dart'): [edit(0, 6, 0, 11, 'dart')],
        },
        documentVersions: {fileToUri('/ws/a.dart'): 5},
      );
      final applied = await applyWorkspaceEdit(
        env,
        matching,
        openFileVersions: {fileToUri('/ws/a.dart'): 5},
      );
      expect(applied, hasLength(1));
    });
  });
}
