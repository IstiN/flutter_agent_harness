// Issue #1760 — oversized user-message intake spill: pure L1/L2 suite for
// the decision function, the config surface, the replacement builder and
// the UserMessageSpillGuard over a MemoryExecutionEnv.
//
// Companion suites: spill_test.dart (tool-result spill, issue #678 shape
// these tests reuse), user_spill_agent_test.dart (the Agent seams),
// agent_cli_user_spill_test.dart (the CLI steering accept path).
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _secret = 'SUPERSECRET123';

MemoryExecutionEnv _env() => MemoryExecutionEnv(cwd: '/work');

/// A body big enough to spill under [_guard]'s defaults: 9999 chars →
/// estimate 2500 tokens > 0.5 × 4000 budget, and 9999 bytes > 1024 floor.
final _bigText = 'log line\n' * 1111;

String _sized(int chars) => 'x' * chars;

UserMessageSpillGuard _guard(
  ExecutionEnv env, {
  SpillsConfig config = const SpillsConfig(userThreshold: 1024),
  int budgetTokens = 4000,
  String? sessionId = 'sess-1',
  String Function(String text)? redact,
}) {
  return UserMessageSpillGuard(
    env: env,
    config: config,
    budgetTokens: () => budgetTokens,
    sessionId: () => sessionId,
    redact: redact,
  );
}

void main() {
  group('shouldSpillUserMessage (L1)', () {
    const config = SpillsConfig(userThreshold: 1024, userFraction: 0.5);

    test('kill switch: enabled false never spills', () {
      expect(
        shouldSpillUserMessage(
          _sized(100000),
          const SpillsConfig(enabled: false),
          1000,
        ),
        isFalse,
      );
    });

    test('userThreshold 0 disables the user path alone', () {
      final zero = SpillsConfig(userThreshold: 0, threshold: 8);
      expect(zero.isUserActive, isFalse);
      expect(zero.isActive, isTrue); // the tool path stays armed
      expect(shouldSpillUserMessage(_sized(100000), zero, 1000), isFalse);
    });

    test(
      'byte floor: at the floor stays inline, past it the budget decides',
      () {
        // 1024 bytes exactly = no spill even with a tiny budget.
        expect(
          shouldSpillUserMessage(_sized(1024), config, 10),
          isFalse,
          reason: 'the floor is a hard lower bound',
        );
        // 1025 bytes with a huge budget: token estimate below fraction → no.
        expect(shouldSpillUserMessage(_sized(1025), config, 100000), isFalse);
      },
    );

    test(
      'relative threshold: token estimate over fraction of budget spills',
      () {
        // 10000 chars → 2500 estimated tokens; 0.5 × 4000 = 2000 → spills.
        expect(shouldSpillUserMessage(_sized(10000), config, 4000), isTrue);
        // Same text against a 6000 budget (3000 allowed): stays inline.
        expect(shouldSpillUserMessage(_sized(10000), config, 6000), isFalse);
      },
    );

    test('empty/whitespace text never spills', () {
      expect(shouldSpillUserMessage('   \n  ', config, 10), isFalse);
    });
  });

  group('SpillsConfig user fields (L1)', () {
    test('fromYaml parses userThreshold and userFraction', () {
      final c = SpillsConfig.fromYaml({
        'userThreshold': 4096,
        'userFraction': 0.25,
      });
      expect(c.userThreshold, 4096);
      expect(c.userFraction, 0.25);
      expect(c.notes, isEmpty);
    });

    test('mistyped user values fall back with notes (tolerant parse)', () {
      final c = SpillsConfig.fromYaml({
        'userThreshold': 'big',
        'userFraction': 'half',
      });
      expect(c.userThreshold, defaultUserSpillThresholdBytes);
      expect(c.userFraction, defaultUserSpillWindowFraction);
      expect(c.notes.where((n) => n.contains('userThreshold')), isNotEmpty);
      expect(c.notes.where((n) => n.contains('userFraction')), isNotEmpty);
    });

    test('negative values clamp to 0 with notes', () {
      final c = SpillsConfig.fromYaml({
        'userThreshold': -5,
        'userFraction': -0.5,
      });
      expect(c.userThreshold, 0);
      expect(c.userFraction, 0);
      expect(c.isUserActive, isFalse);
      expect(c.notes.where((n) => n.contains('clamped')), hasLength(2));
    });

    test('toYaml emits only non-defaults', () {
      expect(const SpillsConfig().toYaml(), isEmpty);
      expect(
        const SpillsConfig(userThreshold: 512).toYaml(),
        'spills:\n  userThreshold: 512\n',
      );
      expect(
        const SpillsConfig(userFraction: 0.75).toYaml(),
        'spills:\n  userFraction: 0.75\n',
      );
      expect(
        const SpillsConfig(enabled: false).toYaml(),
        'spills:\n  enabled: false\n',
      );
    });
  });

  group('resolveRunSpillsConfig user knob (AC8)', () {
    test('FAH_USER_SPILL_THRESHOLD overrides the configured floor', () {
      final config = resolveRunSpillsConfig(
        const SpillsConfig(userThreshold: 4096),
        {userSpillThresholdEnvVar: '512'},
      );
      expect(config!.userThreshold, 512);
      expect(config.threshold, 8192, reason: 'tool threshold untouched');
    });

    test('FAH_USER_SPILL_THRESHOLD=0 disables the user path for the run', () {
      final config = resolveRunSpillsConfig(null, {
        userSpillThresholdEnvVar: '0',
      });
      // With no section there is nothing else armed: the user path is off
      // and the tool path was never asked for.
      expect(config!.isUserActive, isFalse);
      expect(config.isActive, isFalse);
    });

    test('junk user env is ignored', () {
      final config = resolveRunSpillsConfig(
        const SpillsConfig(userThreshold: 4096),
        {userSpillThresholdEnvVar: 'lots'},
      );
      expect(config!.userThreshold, 4096);
    });

    test('the tool knob composes with the user knob', () {
      final config = resolveRunSpillsConfig(null, {
        spillThresholdEnvVar: '2048',
        userSpillThresholdEnvVar: '32768',
      });
      expect(config!.threshold, 2048);
      expect(config.userThreshold, 32768);
    });

    test('the user knob alone does NOT arm tool-result spilling (review)', () {
      // No section + FAH_USER_SPILL_THRESHOLD only: the user path arms,
      // the tool path stays off (threshold 0 → the tool hook never
      // attaches).
      final config = resolveRunSpillsConfig(null, {
        userSpillThresholdEnvVar: '32768',
      });
      expect(config!.isUserActive, isTrue);
      expect(config.isActive, isFalse);
      expect(config.threshold, 0);
    });

    test('the section kill-switch beats the env knobs (review)', () {
      const disabled = SpillsConfig(enabled: false);
      final viaUser = resolveRunSpillsConfig(disabled, {
        userSpillThresholdEnvVar: '32768',
      });
      expect(identical(viaUser, disabled), isTrue);
      expect(viaUser!.isUserActive, isFalse);
      final viaTool = resolveRunSpillsConfig(disabled, {
        spillThresholdEnvVar: '2048',
      });
      expect(identical(viaTool, disabled), isTrue);
      expect(viaTool!.isActive, isFalse);
    });

    test('the user knob set to 0 with an active section keeps tools on', () {
      final config = resolveRunSpillsConfig(const SpillsConfig(), {
        userSpillThresholdEnvVar: '0',
      });
      // The section asked for tool-result spilling; the knob silences
      // only the user path.
      expect(config!.isUserActive, isFalse);
      expect(config.isActive, isTrue);
    });
  });

  group('buildUserSpillReplacement (L1)', () {
    test('instruction names path + bytes, preview keeps the #678 shape', () {
      final replacement = buildUserSpillReplacement(
        _sized(10000),
        spillPath: '.fah/spills/s-1/user-1.md',
        budgetTokens: 4000,
        config: const SpillsConfig(userThreshold: 1024),
      );
      expect(
        replacement,
        contains('was written to `.fah/spills/s-1/user-1.md` (10000 bytes)'),
      );
      expect(replacement, contains('Read it in parts with the read tool'));
      expect(replacement, contains('[spill file: .fah/spills/s-1/user-1.md]'));
      expect(replacement, contains('[... '));
      expect(replacement, contains(spillReadHint));
    });
  });

  group('UserMessageSpillGuard (L2)', () {
    test(
      'below threshold: byte-identical pass-through, no disk writes (AC3)',
      () async {
        final env = _env();
        final guard = _guard(env);
        final small = UserMessage.text('a perfectly normal request');
        final out = await guard.guard(small);
        expect(identical(out, small), isTrue);
        expect(
          env.exportSnapshot().files.keys.where((k) => k.contains('.fah')),
          isEmpty,
        );
      },
    );

    test(
      'oversized text spills to user-1.md and the replacement is bounded',
      () async {
        final env = _env();
        final guard = _guard(env);
        final raw = UserMessage.text(_bigText);
        final out = await guard.guard(raw);
        expect(identical(out, raw), isFalse);
        final text = out.content as String;
        // The full body never rides the replacement.
        expect(text.contains(_bigText), isFalse);
        // Instruction + path + preview markers ride it.
        expect(text, contains('user-1.md'));
        expect(text, contains('Read it in parts with the read tool'));
        expect(text, contains('[... '));
        // The verbatim body is on disk, byte-exact, at the #678 layout.
        final file = await env.readTextFile('.fah/spills/sess-1/user-1.md');
        expect(file.isOk, isTrue, reason: '${file.errorOrNull}');
        expect(file.valueOrNull, _bigText);
      },
    );

    test('redaction runs BEFORE the spill write (AC6)', () async {
      final env = _env();
      final guard = _guard(
        env,
        redact: (text) => text.replaceAll(_secret, '[REDACTED]'),
      );
      final body = '$_bigText\n$_secret';
      final out = await guard.guard(UserMessage.text(body));
      final file = await env.readTextFile('.fah/spills/sess-1/user-1.md');
      expect(file.isOk, isTrue);
      expect(file.valueOrNull, contains('[REDACTED]'));
      expect((file.valueOrNull ?? '').contains(_secret), isFalse);
      // The replacement preview is built from the redacted body too.
      expect(out.content as String, contains('[REDACTED]'));
      expect((out.content as String).contains(_secret), isFalse);
    });

    test('images stay inline in a mixed message (AC5)', () async {
      final env = _env();
      final guard = _guard(env);
      const image = ImageContent(data: 'aGk=', mimeType: 'image/png');
      final message = UserMessage(
        content: [
          TextContent(text: _bigText),
          image,
        ],
        timestamp: DateTime.utc(2026),
      );
      final out = await guard.guard(message);
      final content = out.content as List<ContentBlock>;
      expect(content, hasLength(2));
      expect(content[1], same(image));
      expect(content[0], isA<TextContent>());
      expect((content[0] as TextContent).text, contains('user-1.md'));
    });

    test('write refusal degrades to inline legacy (AC7)', () async {
      final env = _ReadOnlyEnv(MemoryExecutionEnv(cwd: '/work'));
      final guard = _guard(env);
      final raw = UserMessage.text(_bigText);
      final out = await guard.guard(raw);
      expect(identical(out, raw), isTrue);
      expect(out.content as String, _bigText);
    });

    test(
      'a throwing guard (budget closure) never breaks the intake (AC7)',
      () async {
        final env = _env();
        final guard = UserMessageSpillGuard(
          env: env,
          config: const SpillsConfig(userThreshold: 1024),
          budgetTokens: () => throw StateError('meter exploded'),
          sessionId: () => 'sess-1',
        );
        final raw = UserMessage.text(_bigText);
        final out = await guard.guard(raw);
        expect(identical(out, raw), isTrue);
      },
    );

    test('idempotent on an already-spilled replacement (review)', () async {
      final env = _env();
      final guard = _guard(env);
      // A CLI-busy steer pre-spills at accept; the drained replacement
      // re-enters the guard at the seam. It must pass through unchanged —
      // no second file, same object (the FIFO identity depends on it).
      final replacement = await guard.guard(UserMessage.text(_bigText));
      final reGuarded = await guard.guard(replacement);
      expect(identical(reGuarded, replacement), isTrue);
      // No user-2 spill materialized; user-1 still holds the verbatim body.
      expect(
        env.exportSnapshot().files.keys.where((k) => k.contains('user-2')),
        isEmpty,
      );
      expect(
        (await env.readTextFile('.fah/spills/sess-1/user-1.md')).valueOrNull,
        _bigText,
      );
    });

    test('multiple oversized messages each get their own file (AC4)', () async {
      final env = _env();
      final guard = _guard(env);
      final one = await guard.guard(UserMessage.text(_sized(9000)));
      final two = await guard.guard(UserMessage.text(_sized(9000)));
      expect(one.content as String, contains('user-1.md'));
      expect(two.content as String, contains('user-2.md'));
      expect(
        (await env.readTextFile('.fah/spills/sess-1/user-1.md')).valueOrNull,
        _sized(9000),
      );
      expect(
        (await env.readTextFile('.fah/spills/sess-1/user-2.md')).valueOrNull,
        _sized(9000),
      );
    });

    test('sessionless counter still lands (no session id yet)', () async {
      final env = _env();
      final guard = _guard(env, sessionId: null);
      final out = await guard.guard(UserMessage.text(_bigText));
      expect(
        out.content as String,
        contains('.fah/spills/sessionless/user-1.md'),
      );
      expect(
        (await env.readTextFile('.fah/spills/sessionless/user-1.md')).isOk,
        isTrue,
      );
    });

    test('utf8 byte floor counts bytes, not chars (multibyte text)', () async {
      final env = _env();
      // 900 CJK chars = 2700 utf8 bytes > 1024 floor; 900 chars → 225
      // estimated tokens over the 0.5 × 10 budget → spills on both halves.
      final guard = _guard(env, budgetTokens: 10);
      const cjk = '日本語';
      final body = cjk * 300;
      final raw = UserMessage.text(body);
      final out = await guard.guard(raw);
      expect(identical(out, raw), isFalse);
      final file = await env.readTextFile('.fah/spills/sess-1/user-1.md');
      expect(file.valueOrNull, body);
    });
  });
}

/// Test env whose writes are refused (read-only sandbox / disk full, AC7):
/// everything forwards to an in-memory [MemoryExecutionEnv] except
/// [writeBinaryFile], which always fails. Mirrors spill_test.dart's fake.
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
