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

    test('returns ImageContent unchanged for a small image', () async {
      await env.writeBinaryFile('/work/small.png', makePng(100, 50));
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
