import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:image/image.dart';
import 'package:test/test.dart';

String _text(ToolExecutionResult result) {
  return result.content.whereType<TextContent>().map((b) => b.text).join();
}

/// A [Shell] returning a scripted result and recording its invocations.
class _FakeShell implements Shell {
  _FakeShell(this.result);

  Result<ShellExecResult, ExecutionError> result;
  String? lastCommand;
  ShellExecOptions? lastOptions;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    lastCommand = command;
    lastOptions = options;
    return result;
  }
}

void main() {
  group('builtinTools', () {
    test('creates the pi-shaped tools', () {
      final tools = builtinTools(MemoryExecutionEnv());
      expect(tools.map((t) => t.name), ['read', 'write', 'edit', 'ls', 'bash']);
      for (final tool in tools) {
        expect(tool.description, isNotEmpty);
        expect(tool.parameters['type'], 'object');
      }
    });
  });

  group('readFileTool', () {
    late MemoryExecutionEnv env;
    late AgentTool tool;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      tool = readFileTool(env);
    });

    test('reads a whole small file', () async {
      await env.writeFile('notes.txt', 'line one\nline two\n');
      final result = await tool.execute({'path': 'notes.txt'}, null, null);
      expect(_text(result), 'line one\nline two\n');
    });

    test('honors offset and limit with a continuation notice', () async {
      await env.writeFile('f.txt', 'a\nb\nc\nd\ne');
      final result = await tool.execute(
        {'path': 'f.txt', 'offset': 2, 'limit': 2},
        null,
        null,
      );
      expect(
        _text(result),
        'b\nc\n\n[2 more lines in file. Use offset=4 to continue.]',
      );
    });

    test('reads the tail without a notice when limit reaches EOF', () async {
      await env.writeFile('f.txt', 'a\nb\nc');
      final result = await tool.execute(
        {'path': 'f.txt', 'offset': 2, 'limit': 10},
        null,
        null,
      );
      expect(_text(result), 'b\nc');
    });

    test('throws when the offset is beyond end of file', () async {
      await env.writeFile('f.txt', 'a\nb');
      expect(
        tool.execute({'path': 'f.txt', 'offset': 5}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Offset 5 is beyond end of file (2 lines total)'),
          ),
        ),
      );
    });

    test('throws for a missing file', () async {
      expect(
        tool.execute({'path': 'nope.txt'}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('truncates at 2000 lines with a continuation notice', () async {
      final content = List.generate(2001, (i) => 'l${i + 1}').join('\n');
      await env.writeFile('big.txt', content);
      final result = await tool.execute({'path': 'big.txt'}, null, null);
      final text = _text(result);
      expect(text, contains('l1\n'));
      expect(text, isNot(contains('l2001')));
      expect(
        text,
        endsWith(
          '\n\n[Showing lines 1-2000 of 2001. Use offset=2001 to continue.]',
        ),
      );
    });

    test('truncates at 50KB with a byte-limit notice', () async {
      final line = 'x' * 30000;
      await env.writeFile('big.txt', '$line\n$line\n$line');
      final result = await tool.execute({'path': 'big.txt'}, null, null);
      expect(
        _text(result),
        endsWith(
          '\n\n[Showing lines 1-1 of 3 (50.0KB limit). '
          'Use offset=2 to continue.]',
        ),
      );
    });

    test('reports a first line that alone exceeds the byte limit', () async {
      await env.writeFile('big.txt', 'x' * 60000);
      final result = await tool.execute({'path': 'big.txt'}, null, null);
      expect(
        _text(result),
        "[Line 1 is 58.6KB, exceeds 50.0KB limit. "
        "Use bash: sed -n '1p' big.txt | head -c 51200]",
      );
    });

    test('throws when the cancel token is already cancelled', () {
      final source = CancelTokenSource()..cancel();
      expect(
        tool.execute({'path': 'f.txt'}, source.token, null),
        throwsA(isA<CancelledException>()),
      );
    });

    test('validates arguments through the registry', () async {
      final registry = ToolRegistry([tool]);
      expect(
        registry.executor(
          ToolCall(id: '1', name: 'read', arguments: const {}),
          null,
          null,
        ),
        throwsA(isA<ToolValidationException>()),
      );
      await env.writeFile('f.txt', 'a\nb\nc');
      // 'offset' arrives as a string and is coerced to an integer.
      final ok = await registry.executor(
        ToolCall(
          id: '2',
          name: 'read',
          arguments: const {'path': 'f.txt', 'offset': '2'},
        ),
        null,
        null,
      );
      expect(_text(ok), 'b\nc');
    });
  });

  group('writeFileTool', () {
    late MemoryExecutionEnv env;
    late AgentTool tool;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      tool = writeFileTool(env);
    });

    test('writes content, creating parent directories', () async {
      final result = await tool.execute(
        {'path': 'a/b/c.txt', 'content': 'hello'},
        null,
        null,
      );
      expect(_text(result), 'Successfully wrote 5 bytes to a/b/c.txt');
      expect((await env.readTextFile('/work/a/b/c.txt')).valueOrNull, 'hello');
    });

    test('counts UTF-8 bytes, not characters', () async {
      final result = await tool.execute(
        {'path': 'u.txt', 'content': 'héllo'},
        null,
        null,
      );
      expect(_text(result), 'Successfully wrote 6 bytes to u.txt');
    });

    test('requires path and content', () async {
      final registry = ToolRegistry([tool]);
      expect(
        registry.executor(
          ToolCall(id: '1', name: 'write', arguments: const {'path': 'x.txt'}),
          null,
          null,
        ),
        throwsA(isA<ToolValidationException>()),
      );
    });
  });

  group('editFileTool', () {
    late MemoryExecutionEnv env;
    late AgentTool tool;

    setUp(() async {
      env = MemoryExecutionEnv(cwd: '/work');
      tool = editFileTool(env);
      await env.writeFile('main.dart', 'void main() {\n  print("hello");\n}\n');
    });

    test('replaces a unique occurrence', () async {
      final result = await tool.execute(
        {
          'path': 'main.dart',
          'oldText': 'print("hello");',
          'newText': 'print("world");',
        },
        null,
        null,
      );
      expect(_text(result), contains('Edited main.dart'));
      expect(
        (await env.readTextFile('/work/main.dart')).valueOrNull,
        'void main() {\n  print("world");\n}\n',
      );
    });

    test('replaces a multiline block exactly once', () async {
      final result = await tool.execute(
        {
          'path': 'main.dart',
          'oldText': 'void main() {\n  print("hello");\n}',
          'newText': 'void main() {\n  print("a");\n  print("b");\n}',
        },
        null,
        null,
      );
      expect(_text(result), contains('Edited main.dart'));
      expect(
        (await env.readTextFile('/work/main.dart')).valueOrNull,
        'void main() {\n  print("a");\n  print("b");\n}\n',
      );
    });

    test('errors when the text is missing, with an actionable message', () {
      expect(
        tool.execute(
          {'path': 'main.dart', 'oldText': 'print("nope");', 'newText': 'x'},
          null,
          null,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('No exact match found'),
          ),
        ),
      );
    });

    test('errors when the text is ambiguous', () async {
      await env.writeFile('dup.txt', 'x\nx\n');
      expect(
        tool.execute(
          {'path': 'dup.txt', 'oldText': 'x', 'newText': 'y'},
          null,
          null,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('ambiguous'),
          ),
        ),
      );
    });

    test('errors for a missing file', () {
      expect(
        tool.execute(
          {'path': 'missing.txt', 'oldText': 'a', 'newText': 'b'},
          null,
          null,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('deletes text when newText is empty', () async {
      final result = await tool.execute(
        {'path': 'main.dart', 'oldText': '  print("hello");\n', 'newText': ''},
        null,
        null,
      );
      expect(_text(result), contains('Edited main.dart'));
      expect(
        (await env.readTextFile('/work/main.dart')).valueOrNull,
        'void main() {\n}\n',
      );
    });

    test('throws when the cancel token is already cancelled', () {
      final source = CancelTokenSource()..cancel();
      expect(
        tool.execute(
          {'path': 'main.dart', 'oldText': 'hello', 'newText': 'bye'},
          source.token,
          null,
        ),
        throwsA(anything),
      );
    });
  });

  group('readFileTool hashline mode', () {
    late MemoryExecutionEnv env;
    late HashlineSnapshotStore store;
    late AgentTool tool;

    setUp(() async {
      env = MemoryExecutionEnv(cwd: '/work');
      store = HashlineSnapshotStore();
      tool = readFileTool(env, snapshots: store);
      await env.writeFile('notes.txt', 'one\ntwo\nthree\n');
    });

    test('prefixes lines and prepends the [path#TAG] header', () async {
      final result = await tool.execute(
        {'path': 'notes.txt', 'hashline': true},
        null,
        null,
      );
      final tag = computeFileHash('one\ntwo\nthree\n');
      expect(_text(result), '[notes.txt#$tag]\n1:one\n2:two\n3:three\n4:');
    });

    test('legacy output is unchanged when the flag is off', () async {
      final result = await tool.execute({'path': 'notes.txt'}, null, null);
      expect(_text(result), 'one\ntwo\nthree\n');
      expect(store.head('/work/notes.txt'), isNull);
    });

    test('records the full file text plus displayed lines', () async {
      await tool.execute(
        {'path': 'notes.txt', 'hashline': true, 'offset': 2, 'limit': 2},
        null,
        null,
      );
      final snapshot = store.head('/work/notes.txt');
      expect(snapshot, isNotNull);
      expect(snapshot!.text, 'one\ntwo\nthree\n');
      expect(snapshot.seenLines, {2, 3});
    });

    test('offset/limit numbering stays 1-indexed to the file', () async {
      final result = await tool.execute(
        {'path': 'notes.txt', 'hashline': true, 'offset': 2, 'limit': 2},
        null,
        null,
      );
      expect(_text(result), contains('2:two\n3:three'));
    });

    test('a full read marks every line as seen', () async {
      await tool.execute({'path': 'notes.txt', 'hashline': true}, null, null);
      expect(store.head('/work/notes.txt')!.seenLines, {1, 2, 3, 4});
    });

    test('re-reading identical content fuses onto one tag', () async {
      final first = await tool.execute(
        {'path': 'notes.txt', 'hashline': true, 'limit': 1},
        null,
        null,
      );
      final second = await tool.execute(
        {'path': 'notes.txt', 'hashline': true, 'offset': 2},
        null,
        null,
      );
      final headerLine = _text(first).split('\n').first;
      expect(_text(second).split('\n').first, headerLine);
      expect(store.head('/work/notes.txt')!.seenLines, {1, 2, 3, 4});
    });
  });

  group('editFileTool hashline mode', () {
    late MemoryExecutionEnv env;
    late HashlineSnapshotStore store;
    late AgentTool readTool;
    late AgentTool editTool;

    setUp(() async {
      env = MemoryExecutionEnv(cwd: '/work');
      store = HashlineSnapshotStore();
      readTool = readFileTool(env, snapshots: store);
      editTool = editFileTool(env, snapshots: store);
      await env.writeFile('main.dart', 'void main() {\n  print("hello");\n}\n');
    });

    /// Reads [path] in hashline mode and returns the `[path#TAG]` header the
    /// model would cite.
    Future<String> readHeader(String path) async {
      final result = await readTool.execute(
        {'path': path, 'hashline': true},
        null,
        null,
      );
      return _text(result).split('\n').first;
    }

    test('applies a patch and answers with the fresh header', () async {
      final header = await readHeader('main.dart');
      final result = await editTool.execute(
        {'patch': '$header\nSWAP 2.=2:\n+  print("world");'},
        null,
        null,
      );
      expect(_text(result), startsWith('[main.dart#'));
      expect(_text(result), contains('First change at line 2.'));
      expect(
        (await env.readTextFile('main.dart')).valueOrNull,
        'void main() {\n  print("world");\n}\n',
      );
    });

    test(
      'the response tag chains into the next edit without a re-read',
      () async {
        final header = await readHeader('main.dart');
        final first = await editTool.execute(
          {'patch': '$header\nSWAP 2.=2:\n+  print("a");'},
          null,
          null,
        );
        final secondHeader = _text(first).split('\n').first;
        final second = await editTool.execute(
          {'patch': '$secondHeader\nINS.TAIL:\n+// done'},
          null,
          null,
        );
        expect(_text(second), startsWith('[main.dart#'));
        expect(
          (await env.readTextFile('main.dart')).valueOrNull,
          'void main() {\n  print("a");\n}\n// done\n',
        );
      },
    );

    test('path is optional in hashline mode (header carries it)', () async {
      final header = await readHeader('main.dart');
      expect(
        editTool.execute({'patch': '$header\nDEL 1'}, null, null),
        completes,
      );
    });

    test('rejects mixed patch + oldText/newText arguments', () {
      expect(
        editTool.execute(
          {
            'path': 'main.dart',
            'patch': '[main.dart#1A2B]\nDEL 1',
            'oldText': 'a',
            'newText': 'b',
          },
          null,
          null,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not both'),
          ),
        ),
      );
    });

    test('rejects calls with neither mode fully specified', () {
      expect(
        editTool.execute({'path': 'main.dart'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Missing arguments'),
          ),
        ),
      );
      expect(
        editTool.execute({'path': 'main.dart', 'oldText': 'a'}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('a stale tag rejects the edit with drift context', () async {
      final header = await readHeader('main.dart');
      await env.writeFile('main.dart', 'void main() {\n  print("drift");\n}\n');
      expect(
        editTool.execute({'patch': '$header\nDEL 2'}, null, null),
        throwsA(
          isA<HashlineMismatchError>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('file changed between read and edit'),
              contains('*2:  print("drift");'),
            ),
          ),
        ),
      );
      // Nothing was written by the rejected edit.
      expect(
        (await env.readTextFile('main.dart')).valueOrNull,
        'void main() {\n  print("drift");\n}\n',
      );
    });

    test('a byte-identical body returns the no-change diagnostic', () async {
      final header = await readHeader('main.dart');
      final result = await editTool.execute(
        {'patch': '$header\nSWAP 2.=2:\n+  print("hello");'},
        null,
        null,
      );
      expect(_text(result), contains('produced no change'));
      expect(
        (await env.readTextFile('main.dart')).valueOrNull,
        'void main() {\n  print("hello");\n}\n',
      );
    });

    test('unsupported ops surface a focused error', () {
      expect(
        editTool.execute({'patch': '[main.dart#1A2B]\nREM'}, null, null),
        throwsA(
          isA<HashlineFormatException>().having(
            (e) => e.message,
            'message',
            contains('not supported'),
          ),
        ),
      );
    });

    test('malformed patches surface a parse error', () {
      expect(
        editTool.execute({'patch': 'DEL 1'}, null, null),
        throwsA(isA<HashlineFormatException>()),
      );
    });

    test('multi-section patches apply all-or-nothing', () async {
      await env.writeFile('other.dart', 'one\ntwo\n');
      final headerA = await readHeader('main.dart');
      final headerB = await readHeader('other.dart');
      final result = await editTool.execute(
        {'patch': '$headerA\nDEL 1\n$headerB\nSWAP 1.=1:\n+ONE'},
        null,
        null,
      );
      expect(_text(result), contains('[main.dart#'));
      expect(_text(result), contains('[other.dart#'));
      expect(
        (await env.readTextFile('main.dart')).valueOrNull,
        '  print("hello");\n}\n',
      );
      expect((await env.readTextFile('other.dart')).valueOrNull, 'ONE\ntwo\n');
    });

    test(
      'edits on lines a partial read never displayed are rejected',
      () async {
        await readTool.execute(
          {'path': 'main.dart', 'hashline': true, 'limit': 1},
          null,
          null,
        );
        final header = await readHeader('main.dart');
        // Re-read only line 1 so lines 2+ are unseen under the CURRENT tag...
        // (the full readHeader above re-fused; craft the seen set directly.)
        final tag = header.substring(
          header.indexOf('#') + 1,
          header.indexOf(']'),
        );
        store.head('/work/main.dart')!.seenLines!
          ..clear()
          ..add(1);
        expect(
          editTool.execute({'patch': '[main.dart#$tag]\nDEL 3'}, null, null),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('never displayed'),
            ),
          ),
        );
      },
    );
  });

  group('hashline round-trip', () {
    late MemoryExecutionEnv env;
    late List<AgentTool> tools;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      tools = builtinTools(env);
    });

    AgentTool toolNamed(String name) => tools.firstWhere((t) => t.name == name);

    test('read with hashes → edit by anchors → content correct', () async {
      await env.writeFile(
        'greet.py',
        'def greet(name):\n'
            '    msg = "Hello, " + name\n'
            '    print(msg)\n'
            'greet("world")\n',
      );
      final read = toolNamed('read');
      final edit = toolNamed('edit');

      final readResult = await read.execute(
        {'path': 'greet.py', 'hashline': true},
        null,
        null,
      );
      final output = _text(readResult);
      final header = output.split('\n').first;
      expect(header, matches(RegExp(r'^\[greet\.py#[0-9A-F]{4}\]$')));
      expect(output, contains('2:    msg = "Hello, " + name'));

      // The model anchors on the numbered lines it just saw.
      final editResult = await edit.execute(
        {
          'patch':
              '$header\n'
              'INS.POST 1:\n'
              '+    if not name: name = "stranger"\n'
              'SWAP 2.=2:\n'
              '+    greeting = "Hi"\n'
              '+    msg = f"{greeting}, {name}"\n'
              'DEL 4',
        },
        null,
        null,
      );
      expect(_text(editResult), startsWith('[greet.py#'));
      expect(
        (await env.readTextFile('greet.py')).valueOrNull,
        'def greet(name):\n'
        '    if not name: name = "stranger"\n'
        '    greeting = "Hi"\n'
        '    msg = f"{greeting}, {name}"\n'
        '    print(msg)\n',
      );
    });

    test(
      'external drift between read and edit reports the stale lines',
      () async {
        await env.writeFile('doc.md', 'alpha\nbeta\ngamma\n');
        final read = toolNamed('read');
        final edit = toolNamed('edit');
        final readResult = await read.execute(
          {'path': 'doc.md', 'hashline': true},
          null,
          null,
        );
        final header = _text(readResult).split('\n').first;

        await env.writeFile('doc.md', 'alpha\nCHANGED\ngamma\n');
        expect(
          edit.execute({'patch': '$header\nSWAP 2.=2:\n+BETA'}, null, null),
          throwsA(
            isA<HashlineMismatchError>().having(
              (e) => e.toString(),
              'message',
              allOf(
                contains('file changed between read and edit'),
                contains('*2:CHANGED'),
              ),
            ),
          ),
        );
        expect(
          (await env.readTextFile('doc.md')).valueOrNull,
          'alpha\nCHANGED\ngamma\n',
        );
      },
    );

    test(
      'the tools created by builtinTools share one snapshot store',
      () async {
        await env.writeFile('a.txt', 'x\ny\n');
        final read = toolNamed('read');
        final edit = toolNamed('edit');
        final readResult = await read.execute(
          {'path': 'a.txt', 'hashline': true},
          null,
          null,
        );
        final header = _text(readResult).split('\n').first;
        // If read and edit did not share a store, this anchored edit would
        // still pass the content check — so verify the store path too: a
        // second tag for DIFFERENT content minted by edit must be resolvable.
        final editResult = await edit.execute(
          {'patch': '$header\nSWAP 1.=1:\n+X'},
          null,
          null,
        );
        final newHeader = _text(editResult).split('\n').first;
        expect(newHeader, isNot(header));
        // Chained edit against the edit-minted tag works out of the box.
        final second = await edit.execute(
          {'patch': '$newHeader\nDEL 2'},
          null,
          null,
        );
        expect(_text(second), startsWith('[a.txt#'));
        expect((await env.readTextFile('a.txt')).valueOrNull, 'X\n');
      },
    );
  });

  group('listDirTool', () {
    late MemoryExecutionEnv env;
    late AgentTool tool;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      tool = listDirTool(env);
    });

    test('lists entries sorted, directories suffixed with /', () async {
      await env.writeFile('b.txt', '');
      await env.writeFile('sub/inner.txt', '');
      await env.writeFile('a.txt', '');
      final result = await tool.execute({}, null, null);
      expect(_text(result), 'a.txt\nb.txt\nsub/');
    });

    test('lists an explicit subdirectory', () async {
      await env.writeFile('sub/inner.txt', '');
      final result = await tool.execute({'path': 'sub'}, null, null);
      expect(_text(result), 'inner.txt');
    });

    test('caps entries at the limit with a notice', () async {
      for (var i = 0; i < 5; i++) {
        await env.writeFile('f$i.txt', '');
      }
      final result = await tool.execute({'limit': 3}, null, null);
      expect(
        _text(result),
        'f0.txt\nf1.txt\nf2.txt\n\n'
        '[3 entries limit reached. Use limit=6 for more]',
      );
    });

    test('reports an empty directory', () async {
      await env.createDir('empty');
      final result = await tool.execute({'path': 'empty'}, null, null);
      expect(_text(result), '(empty directory)');
    });

    test('returns the file name when the path is a file', () async {
      await env.writeFile('f.txt', '');
      final result = await tool.execute({'path': 'f.txt'}, null, null);
      expect(_text(result), 'f.txt');
    });

    test('throws for a missing path', () async {
      expect(
        tool.execute({'path': 'nope'}, null, null),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('shellTool', () {
    late _FakeShell shell;
    late MemoryExecutionEnv env;
    late AgentTool tool;

    setUp(() {
      shell = _FakeShell(
        const Ok(ShellExecResult(stdout: 'out', stderr: '', exitCode: 0)),
      );
      env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      tool = shellTool(env);
    });

    test('returns stdout of a successful command', () async {
      final result = await tool.execute({'command': 'ls'}, null, null);
      expect(_text(result), 'out');
      expect(shell.lastCommand, 'ls');
    });

    test('appends stderr after stdout', () async {
      shell.result = const Ok(
        ShellExecResult(stdout: 'out', stderr: 'err', exitCode: 0),
      );
      final result = await tool.execute({'command': 'x'}, null, null);
      expect(_text(result), 'out\nerr');
    });

    test('reports (no output) for silent success', () async {
      shell.result = const Ok(
        ShellExecResult(stdout: '', stderr: '', exitCode: 0),
      );
      final result = await tool.execute({'command': 'x'}, null, null);
      expect(_text(result), '(no output)');
    });

    test('throws with output and exit code on failure', () async {
      shell.result = const Ok(
        ShellExecResult(stdout: 'partial', stderr: '', exitCode: 3),
      );
      expect(
        tool.execute({'command': 'x'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'partial\n\nCommand exited with code 3',
          ),
        ),
      );
    });

    test('throws a timeout message when the shell times out', () {
      shell.result = const Err(
        ExecutionError(ExecutionErrorCode.timeout, 'killed'),
      );
      expect(
        tool.execute({'command': 'x', 'timeout': 5}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Command timed out after 5 seconds'),
          ),
        ),
      );
    });

    test('throws an aborted message when the shell is cancelled', () {
      shell.result = const Err(
        ExecutionError(ExecutionErrorCode.aborted, 'killed'),
      );
      expect(
        tool.execute({'command': 'x'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Command aborted'),
          ),
        ),
      );
    });

    test('surfaces shell-unavailable errors', () {
      shell.result = const Err(
        ExecutionError(
          ExecutionErrorCode.shellUnavailable,
          'No shell is available in this environment',
        ),
      );
      expect(
        tool.execute({'command': 'x'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('No shell is available'),
          ),
        ),
      );
    });

    test('passes timeout and cancel token to the shell', () async {
      final source = CancelTokenSource();
      await tool.execute({'command': 'x', 'timeout': 2.5}, source.token, null);
      expect(shell.lastOptions?.timeout, const Duration(milliseconds: 2500));
      expect(shell.lastOptions?.cancelToken, source.token);
    });

    test('rejects non-positive timeouts', () {
      expect(
        tool.execute({'command': 'x', 'timeout': 0}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Invalid timeout'),
          ),
        ),
      );
    });

    test('rejects timeouts above the maximum', () {
      expect(
        tool.execute({'command': 'x', 'timeout': 999999999}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Invalid timeout: maximum is 2147483.647 seconds'),
          ),
        ),
      );
    });

    test('keeps the last 2000 lines of long output', () async {
      final stdout = List.generate(2001, (i) => 'o${i + 1}').join('\n');
      shell.result = Ok(
        ShellExecResult(stdout: stdout, stderr: '', exitCode: 0),
      );
      final result = await tool.execute({'command': 'x'}, null, null);
      final text = _text(result);
      expect(text, isNot(contains('o1\n')));
      expect(text, contains('o2001'));
      expect(text, endsWith('\n\n[Showing lines 2-2001 of 2001.]'));
    });
  });

  group('Image support in readFileTool', () {
    late MemoryExecutionEnv env;
    late ToolRegistry registry;

    setUp(() {
      env = MemoryExecutionEnv();
      registry = ToolRegistry()
        ..registerAll([readFileTool(env), writeFileTool(env)]);
    });

    Uint8List makePng(int width, int height) {
      final img = Image(width: width, height: height)..getPixel(0, 0).r = 255;
      return Uint8List.fromList(encodePng(img));
    }

    /// Deterministic noise: barely compressible, so the PNG blows past the
    /// 4.5MB base64 budget even after the dimension clamp.
    Uint8List makeNoisyPng(int width, int height) {
      final img = Image(width: width, height: height);
      var seed = 42;
      for (final pixel in img) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        pixel
          ..r = seed & 0xFF
          ..g = (seed >> 8) & 0xFF
          ..b = (seed >> 16) & 0xFF;
      }
      return Uint8List.fromList(encodePng(img));
    }

    test('returns ImageContent for a PNG and resizes large images', () async {
      await env.writeBinaryFile('/work/huge.png', makePng(3000, 2000));
      final tool = registry.lookup('read')!;
      final result = await tool.execute({'path': '/work/huge.png'}, null, null);
      final note = _text(result);
      expect(note, contains('3000x2000'));
      expect(note, contains('resized to 2000x1333'));
      final images = result.content.whereType<ImageContent>().toList();
      expect(images, hasLength(1));
      expect(images.first.mimeType, 'image/png');
      expect(images.first.data, isNotEmpty);
      expect(base64Decode(images.first.data), isNotEmpty);
    });

    test('resize hint carries the coordinate scale factor', () async {
      await env.writeBinaryFile('/work/huge.png', makePng(3000, 2000));
      final tool = registry.lookup('read')!;
      final result = await tool.execute({'path': '/work/huge.png'}, null, null);
      final note = _text(result);
      expect(
        note,
        contains(
          '[Image: original 3000x2000, displayed at 2000x1333. '
          'Multiply coordinates by 1.50 to map to original image.]',
        ),
      );
    });

    test('huge noisy PNG is degraded below the 4.5MB base64 budget', () async {
      final noisy = makeNoisyPng(2100, 1600);
      // Sanity: the fixture itself exceeds the budget.
      expect(base64Encode(noisy).length, greaterThan(4718592));
      await env.writeBinaryFile('/work/noisy.png', noisy);
      final tool = registry.lookup('read')!;
      final result = await tool.execute(
        {'path': '/work/noisy.png'},
        null,
        null,
      );
      final images = result.content.whereType<ImageContent>().toList();
      expect(images, hasLength(1));
      expect(images.first.data.length, lessThan(4718592));
      final note = _text(result);
      expect(note, contains('Multiply coordinates by'));
      // The payload still decodes, at or below the dimension clamp.
      final decoded = decodeImage(base64Decode(images.first.data))!;
      expect(decoded.width, lessThanOrEqualTo(2000));
      expect(decoded.height, lessThanOrEqualTo(2000));
    });

    test('returns ImageContent unchanged for a small image', () async {
      final png = makePng(100, 50);
      await env.writeBinaryFile('/work/small.png', png);
      final tool = registry.lookup('read')!;
      final result = await tool.execute(
        {'path': '/work/small.png'},
        null,
        null,
      );
      final note = _text(result);
      expect(note, contains('100x50'));
      expect(note, isNot(contains('resized')));
      final images = result.content.whereType<ImageContent>().toList();
      expect(images, hasLength(1));
      expect(images.first.mimeType, 'image/png');
      // Pass-through: the original bytes are sent untouched.
      expect(images.first.data, base64Encode(png));
    });

    test('passes small JPEG and GIF originals through untouched', () async {
      final jpg = Uint8List.fromList(encodeJpg(Image(width: 80, height: 60)));
      final gif = Uint8List.fromList(encodeGif(Image(width: 40, height: 30)));
      await env.writeBinaryFile('/work/small.jpg', jpg);
      await env.writeBinaryFile('/work/small.gif', gif);
      final tool = registry.lookup('read')!;

      final jpgResult = await tool.execute(
        {'path': '/work/small.jpg'},
        null,
        null,
      );
      final jpgImage = jpgResult.content.whereType<ImageContent>().single;
      expect(jpgImage.mimeType, 'image/jpeg');
      expect(jpgImage.data, base64Encode(jpg));

      final gifResult = await tool.execute(
        {'path': '/work/small.gif'},
        null,
        null,
      );
      final gifImage = gifResult.content.whereType<ImageContent>().single;
      expect(gifImage.mimeType, 'image/gif');
      expect(gifImage.data, base64Encode(gif));
    });

    test('bakes EXIF orientation before measuring and resizing', () async {
      // Stored as 200x3000 (WxH) with orientation 6 (rotate 90° CW for
      // display): the displayed image is 3000x200.
      final stored = Image(width: 200, height: 3000)
        ..exif.imageIfd.orientation = 6;
      await env.writeBinaryFile(
        '/work/rotated.jpg',
        Uint8List.fromList(encodeJpg(stored, quality: 80)),
      );
      final tool = registry.lookup('read')!;
      final result = await tool.execute(
        {'path': '/work/rotated.jpg'},
        null,
        null,
      );
      final note = _text(result);
      // Dims are reported AFTER orientation baking (a 133x2000 portrait
      // resize would mean the flag was ignored).
      expect(note, contains('3000x200'));
      expect(note, contains('resized to 2000x133'));
    });

    test('converts BMP to an inline format with a conversion hint', () async {
      final bmp = Uint8List.fromList(encodeBmp(Image(width: 30, height: 20)));
      await env.writeBinaryFile('/work/pic.bmp', bmp);
      final tool = registry.lookup('read')!;
      final result = await tool.execute({'path': '/work/pic.bmp'}, null, null);
      final note = _text(result);
      expect(note, contains('[Image converted from image/bmp to image/png.]'));
      expect(note, isNot(contains('resized')));
      final images = result.content.whereType<ImageContent>().toList();
      expect(images, hasLength(1));
      expect(images.first.mimeType, 'image/png');
      final decoded = decodeImage(base64Decode(images.first.data))!;
      expect(decoded.width, 30);
      expect(decoded.height, 20);
    });

    test('adds a non-vision note when the model cannot take images', () async {
      await env.writeBinaryFile('/work/small.png', makePng(10, 10));
      final textOnly = Model(
        id: 'text-only',
        api: 'openai-completions',
        provider: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        contextWindow: 128000,
        maxTokens: 4096,
      );
      final tool = readFileTool(env, model: () => textOnly);
      final result = await tool.execute(
        {'path': '/work/small.png'},
        null,
        null,
      );
      expect(
        _text(result),
        contains(
          '[Current model does not support images. The image will be '
          'omitted from this request.]',
        ),
      );
      // The image itself stays in the result; providers substitute an
      // explicit placeholder at request time.
      expect(result.content.whereType<ImageContent>(), hasLength(1));
    });

    test('omits the non-vision note for vision-capable models', () async {
      await env.writeBinaryFile('/work/small.png', makePng(10, 10));
      final vision = Model(
        id: 'gpt-4o',
        api: 'openai-completions',
        provider: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        input: const ['text', 'image'],
        contextWindow: 128000,
        maxTokens: 4096,
      );
      final tool = readFileTool(env, model: () => vision);
      final result = await tool.execute(
        {'path': '/work/small.png'},
        null,
        null,
      );
      expect(_text(result), isNot(contains('does not support images')));
    });

    test('empty files are treated as text, not images', () async {
      await env.writeFile('/work/empty.txt', '');
      final tool = registry.lookup('read')!;
      final result = await tool.execute(
        {'path': '/work/empty.txt'},
        null,
        null,
      );
      expect(result.content.whereType<ImageContent>(), isEmpty);
      expect(_text(result), isEmpty);
    });
  });
}
