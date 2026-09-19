// RED-phase L1+L2 test suite for issue #678 (automatic tool-result
// spilling), written against the API skeleton in
// lib/src/spill/spill.dart. Failures must come ONLY from
// UnimplementedError on shouldSpill / buildPreview / SpillStore.write /
// attachSpillHooks — SpillsConfig.fromYaml is already implemented and its
// tests may pass.
//
// Preview shape pinned by the spill.dart doc comments:
//   line1  [spilled: <totalChars> chars, <totalLines> lines (threshold <T> chars)]
//   line2  [spill file: <path>]
//   blank  head (<= headChars, codepoint-safe)
//   blank  [... <N> chars omitted ...]
//   blank  tail (<= tailChars, codepoint-safe)
//   [read the spill file above for the full output]
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _secret = 'SUPERSECRET123';

Never _neverStream(Model model, Context context, {CancelToken? cancelToken}) =>
    throw UnimplementedError();

Future<ToolExecutionResult> _unusedExecutor(_, _, _) async =>
    ToolExecutionResult.text('unused');

AssistantMessage _assistant({List<ContentBlock> content = const []}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolCall _call(
  String name,
  Map<String, dynamic> args, {
  String id = 'call-1',
}) => ToolCall(id: id, name: name, arguments: args);

AfterToolCallContext _afterContext(ToolCall call, ToolExecutionResult result) {
  return AfterToolCallContext(
    assistantMessage: _assistant(content: [call]),
    toolCall: call,
    result: result,
    isError: false,
    context: const Context(messages: []),
  );
}

ToolExecutionResult _textResult(String text) =>
    ToolExecutionResult(content: [TextContent(text: text)]);

Agent _agentWithSpills(
  ExecutionEnv env, {
  String sessionId = 'sess-1',
  SpillsConfig config = const SpillsConfig(),
}) {
  final agent = Agent(
    streamFunction: _neverStream,
    toolExecutor: _unusedExecutor,
  );
  attachSpillHooks(agent, env: env, sessionId: () => sessionId, config: config);
  return agent;
}

const _markerPrefix = '[... ';
const _markerSuffix = ' chars omitted ...]';

/// Parses the omitted size out of a marker section; null when the section
/// is not exactly the pinned marker shape.
int? _omittedOf(String section) {
  if (!section.startsWith(_markerPrefix)) return null;
  if (!section.endsWith(_markerSuffix)) return null;
  return int.tryParse(
    section.substring(
      _markerPrefix.length,
      section.length - _markerSuffix.length,
    ),
  );
}

final _spillPathRe = RegExp(r'^\[spill file: (.+)\]$', multiLine: true);

/// Splits a preview into its pinned sections: header lines / head / omitted
/// marker / tail + read hint.
({String header, String spillLine, String head, String tail, int omitted})
_splitPreview(String preview) {
  final sections = preview.split('\n\n');
  expect(sections.length, 4, reason: 'preview sections:\n$preview');
  final headerLines = sections[0].split('\n');
  expect(headerLines, hasLength(2), reason: 'preview header:\n$preview');
  final trailerLines = sections[3].split('\n');
  expect(trailerLines.last, spillReadHint, reason: preview);
  final omitted = _omittedOf(sections[2]);
  expect(omitted, isNotNull, reason: 'omitted marker: ${sections[2]}');
  return (
    header: headerLines[0],
    spillLine: headerLines[1],
    head: sections[1],
    tail: trailerLines.sublist(0, trailerLines.length - 1).join('\n'),
    omitted: omitted!,
  );
}

/// Every UTF-16 surrogate in [s] must be one half of a proper pair: a head
/// or tail cut that lands mid-codepoint fails here (issue #678 AC4).
void _expectCodepointSafe(String s) {
  final units = s.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF) {
      expect(
        i + 1 < units.length &&
            units[i + 1] >= 0xDC00 &&
            units[i + 1] <= 0xDFFF,
        isTrue,
        reason: 'unpaired high surrogate at unit $i',
      );
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      expect(
        i > 0 && units[i - 1] >= 0xD800 && units[i - 1] <= 0xDBFF,
        isTrue,
        reason: 'orphan low surrogate at unit $i',
      );
    }
  }
}

/// Test env whose writes are refused (read-only sandbox / disk full, AC6):
/// everything forwards to an in-memory [MemoryExecutionEnv] except
/// [writeBinaryFile], which always fails.
class _ReadOnlyEnv implements ExecutionEnv {
  _ReadOnlyEnv(this._inner);
  final MemoryExecutionEnv _inner;

  @override
  String get cwd => _inner.cwd;

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) async => Err(
    const FileError(
      FileErrorCode.permissionDenied,
      'sandbox refused the spill write',
    ),
  );

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _inner.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _inner.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _inner.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _inner.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _inner.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _inner.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _inner.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _inner.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _inner.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _inner.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _inner.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _inner.exec(command, options: options);
}

void main() {
  group('shouldSpill (L1)', () {
    const config = SpillsConfig();

    test('exactly threshold chars stays inline (AC1 boundary)', () {
      expect(shouldSpill('x' * config.threshold, config), isFalse);
    });

    test('threshold+1 chars spills (AC1 boundary)', () {
      expect(shouldSpill('x' * (config.threshold + 1), config), isTrue);
    });

    test('threshold 0 disables spilling for any text (legacy, AC1)', () {
      const disabled = SpillsConfig(threshold: 0);
      expect(shouldSpill('', disabled), isFalse);
      expect(shouldSpill('x' * 100, disabled), isFalse);
      expect(shouldSpill('x' * 1000000, disabled), isFalse);
    });

    test('empty and whitespace-only results never spill (AC2)', () {
      const small = SpillsConfig(threshold: 4);
      expect(shouldSpill('', small), isFalse);
      expect(shouldSpill(' ', small), isFalse);
      expect(shouldSpill(' \t\r\n ', small), isFalse);
    });
  });

  group('buildPreview (L1)', () {
    const config = SpillsConfig();

    test('single giant line stays char-bounded, never line-counted (AC3)', () {
      final body = 'x' * 100000;
      final preview = buildPreview(
        body,
        spillPath: '.fah/spills/s/1.txt',
        config: config,
      );
      final p = _splitPreview(preview);
      expect(
        p.header,
        '[spilled: 100000 chars, 1 lines (threshold ${config.threshold} chars)]',
      );
      // One 100k line: the head cannot degenerate into a 50k "head".
      expect(p.head.length, lessThanOrEqualTo(config.headChars));
      expect(p.tail.length, lessThanOrEqualTo(config.tailChars));
      expect(p.head.length + p.tail.length + p.omitted, 100000);
      expect(
        preview.length,
        lessThan(config.headChars + config.tailChars + 300),
      );
    });

    test('UTF-16 surrogate pairs are never split by a cut (AC4)', () {
      // Two ASCII lead units put an even code-unit offset in front of the
      // emoji run, so a naive 2000-unit head cut lands mid-pair.
      final body = 'ab${'😀' * 5000}'; // 10002 UTF-16 code units
      expect(shouldSpill(body, config), isTrue);
      final preview = buildPreview(
        body,
        spillPath: '.fah/spills/s/1.txt',
        config: config,
      );
      _expectCodepointSafe(preview);
      expect(preview.contains('\u{FFFD}'), isFalse, reason: 'mojibake');
      final p = _splitPreview(preview);
      expect(p.head.length, lessThanOrEqualTo(config.headChars));
      expect(p.tail.length, lessThanOrEqualTo(config.tailChars));
      expect(
        preview.length,
        lessThan(config.headChars + config.tailChars + 300),
      );
      expect(
        p.header,
        '[spilled: 10002 chars, 1 lines (threshold ${config.threshold} chars)]',
      );
    });

    test('omitted marker and header carry the true totals (AC10)', () {
      final line = 'b' * 100;
      final body = '${'$line\n' * 99}$line'; // 100 lines, 10099 chars
      final preview = buildPreview(
        body,
        spillPath: '.fah/spills/s/1.txt',
        config: config,
      );
      final p = _splitPreview(preview);
      expect(
        p.header,
        '[spilled: 10099 chars, 100 lines (threshold ${config.threshold} chars)]',
      );
      expect(p.spillLine, '[spill file: .fah/spills/s/1.txt]');
      expect(preview, contains('[... 6099 chars omitted ...]'));
      expect(p.omitted, 6099);
      expect(p.head.length + p.tail.length + p.omitted, 10099);
    });
  });

  group('SpillsConfig.fromYaml (L1, AC11)', () {
    test('null node yields defaults', () {
      final c = SpillsConfig.fromYaml(null);
      expect(c.enabled, isTrue);
      expect(c.threshold, 8192);
      expect(c.headChars, 2000);
      expect(c.tailChars, 2000);
      expect(c.notes, isEmpty);
      expect(c.isActive, isTrue);
    });

    test('non-map node yields defaults', () {
      for (final node in [
        'spills',
        42,
        [true],
      ]) {
        final c = SpillsConfig.fromYaml(node);
        expect(c.threshold, 8192, reason: '$node');
        expect(c.notes, isEmpty, reason: '$node');
      }
    });

    test('unknown key is noted, parse survives', () {
      final c = SpillsConfig.fromYaml({'threshold': 8192, 'threshhold': 99});
      expect(c.threshold, 8192);
      expect(c.notes, contains(contains('threshhold')));
    });

    test('headChars below the preview minimum is clamped with a note', () {
      final c = SpillsConfig.fromYaml({'headChars': 50});
      expect(c.headChars, spillsMinPreviewChars);
      expect(c.headChars, 200);
      expect(
        c.notes.where((n) => n.contains('headChars') && n.contains('clamped')),
        isNotEmpty,
      );
    });

    test('negative threshold clamps to 0 (disabled) with a note', () {
      final c = SpillsConfig.fromYaml({'threshold': -5});
      expect(c.threshold, 0);
      expect(c.isActive, isFalse);
      expect(c.notes.where((n) => n.contains('threshold')), isNotEmpty);
    });

    test('mistyped enabled falls back to default true with a note', () {
      final c = SpillsConfig.fromYaml({'enabled': 'yes'});
      expect(c.enabled, isTrue);
      expect(c.notes.where((n) => n.contains('enabled')), isNotEmpty);
    });

    test('string threshold falls back to default with a note', () {
      final c = SpillsConfig.fromYaml({'threshold': '9000'});
      expect(c.threshold, 8192);
      expect(c.notes.where((n) => n.contains('threshold')), isNotEmpty);
    });
  });

  group('SpillStore.write (L2, AC7)', () {
    test('unique per-session names, exact utf8 content on disk', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final store = SpillStore(env: env, sessionId: () => 'sess-1');
      const body1 = 'first spill — é😀 日本語';
      final p1 = await store.write(body1);
      final p2 = await store.write('second spill');
      expect(p1, '.fah/spills/sess-1/1.txt');
      expect(p2, '.fah/spills/sess-1/2.txt');
      final r1 = await env.readTextFile(p1!);
      expect(r1.isOk, isTrue, reason: '${r1.errorOrNull}');
      expect(r1.valueOrNull, body1);
      final r2 = await env.readTextFile(p2!);
      expect(r2.isOk, isTrue, reason: '${r2.errorOrNull}');
      expect(r2.valueOrNull, 'second spill');
    });

    test('counter restarts at 1.txt for a new session id', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      var sessionId = 'one';
      final store = SpillStore(env: env, sessionId: () => sessionId);
      final p1 = await store.write('a');
      sessionId = 'two';
      final p2 = await store.write('b');
      expect(p1, '.fah/spills/one/1.txt');
      expect(p2, '.fah/spills/two/1.txt');
    });
  });

  group('attachSpillHooks under threshold (L2)', () {
    test('pass-through is byte-identical, no file written', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final agent = _agentWithSpills(env);
      const raw = 'small enough result';
      final out = await agent.afterToolCall!(
        _afterContext(_call('read', {'path': 'a.txt'}), _textResult(raw)),
        null,
      );
      // No override (null) or the exact same content — never rewritten.
      final text = out == null
          ? null
          : (out.content!.single as TextContent).text;
      expect(text, anyOf(isNull, raw));
      expect(
        env.exportSnapshot().files.keys.where((k) => k.contains('.fah')),
        isEmpty,
      );
    });
  });

  group('attachSpillHooks over threshold (L2)', () {
    test('one TextContent: preview + spill file with the full body', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final agent = _agentWithSpills(env);
      final body = 'x' * 9000;
      final out = await agent.afterToolCall!(
        _afterContext(_call('bash', {'command': 'big'}), _textResult(body)),
        null,
      );
      expect(out, isNotNull);
      expect(out!.content, hasLength(1));
      final text = (out.content!.single as TextContent).text;
      expect(text, contains('[spill file: '));
      expect(text, contains(spillReadHint));
      expect(text, contains('[... 5000 chars omitted ...]'));
      expect(text.contains(body), isFalse); // full body NOT kept inline
      final path = _spillPathRe.firstMatch(text)!.group(1)!;
      expect(path, '.fah/spills/sess-1/1.txt');
      final file = await env.readTextFile(path);
      expect(file.isOk, isTrue, reason: '${file.errorOrNull}');
      expect(file.valueOrNull, body); // FULL body on disk, byte-exact
    });
  });

  group('redaction ordering (L2, AC5)', () {
    // The prior afterToolCall hook stands in for the redactor, which runs
    // FIRST on the host: the spill hook must only ever see masked content.
    Agent maskedAgent(ExecutionEnv env) {
      final agent = Agent(
        streamFunction: _neverStream,
        toolExecutor: _unusedExecutor,
        afterToolCall: (context, cancelToken) async {
          final t = (context.result.content.single as TextContent).text;
          return AfterToolCallResult(
            content: [TextContent(text: t.replaceAll(_secret, '***'))],
          );
        },
      );
      attachSpillHooks(
        agent,
        env: env,
        sessionId: () => 'sess-1',
        config: const SpillsConfig(),
      );
      return agent;
    }

    test(
      'secret in the head: masked in preview AND in the spill file',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final agent = maskedAgent(env);
        final body = '$_secret${'x' * 9000}';
        final out = await agent.afterToolCall!(
          _afterContext(_call('bash', {'command': 'cat'}), _textResult(body)),
          null,
        );
        final text = (out!.content!.single as TextContent).text;
        expect(text.contains(_secret), isFalse);
        expect(text, contains('***'));
        final path = _spillPathRe.firstMatch(text)!.group(1)!;
        final file = await env.readTextFile(path);
        expect(file.isOk, isTrue, reason: '${file.errorOrNull}');
        expect(file.valueOrNull!.contains(_secret), isFalse);
        expect(file.valueOrNull, contains('***'));
      },
    );

    test(
      'secret only in the omitted middle: absent from preview, masked on disk',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final agent = maskedAgent(env);
        final body = '${'x' * 4000}$_secret${'x' * 5000}'; // 9015 units
        final out = await agent.afterToolCall!(
          _afterContext(_call('bash', {'command': 'cat'}), _textResult(body)),
          null,
        );
        final text = (out!.content!.single as TextContent).text;
        expect(text.contains(_secret), isFalse);
        // The middle is omitted wholesale — not even the mask shows.
        expect(text.contains('***'), isFalse);
        final path = _spillPathRe.firstMatch(text)!.group(1)!;
        final file = await env.readTextFile(path);
        expect(file.isOk, isTrue, reason: '${file.errorOrNull}');
        expect(file.valueOrNull!.contains(_secret), isFalse);
        expect(file.valueOrNull, contains('***'));
      },
    );
  });

  group('spill write failure (L2, AC6)', () {
    test(
      'full body stays inline with a named marker, hook never throws',
      () async {
        final inner = MemoryExecutionEnv(cwd: '/work');
        final agent = _agentWithSpills(_ReadOnlyEnv(inner));
        final raw = 'y' * 9000;
        final out = await agent.afterToolCall!(
          _afterContext(_call('bash', {'command': 'big'}), _textResult(raw)),
          null,
        );
        expect(out, isNotNull); // never a crash
        final text = (out!.content!.single as TextContent).text;
        expect(text, contains(raw)); // output never lost
        expect(text, contains('[spill failed:')); // named fallback marker
        expect(
          inner.exportSnapshot().files.keys.where((k) => k.contains('.fah')),
          isEmpty,
        );
      },
    );
  });

  group('parallel tool results (L2, AC7)', () {
    test(
      'concurrent oversized results spill to unique complete files',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final agent = _agentWithSpills(env);
        final bodyA = '${'x' * 9000}A';
        final bodyB = '${'x' * 9000}B';
        final results = await Future.wait<AfterToolCallResult?>([
          Future.sync(
            () => agent.afterToolCall!(
              _afterContext(
                _call('bash', {'command': 'a'}, id: 'c1'),
                _textResult(bodyA),
              ),
              null,
            ),
          ),
          Future.sync(
            () => agent.afterToolCall!(
              _afterContext(
                _call('bash', {'command': 'b'}, id: 'c2'),
                _textResult(bodyB),
              ),
              null,
            ),
          ),
        ]);
        final texts = results
            .map((r) => (r!.content!.single as TextContent).text)
            .toList();
        final paths = texts
            .map((t) => _spillPathRe.firstMatch(t)!.group(1)!)
            .toSet();
        expect(paths, {'.fah/spills/sess-1/1.txt', '.fah/spills/sess-1/2.txt'});
        final contents = await Future.wait(
          paths.map((p) => env.readTextFile(p)),
        );
        // Both complete, no overwrite: the two files carry exactly the two
        // distinct bodies.
        expect(contents.map((r) => r.valueOrNull).toSet(), {bodyA, bodyB});
      },
    );
  });
}
