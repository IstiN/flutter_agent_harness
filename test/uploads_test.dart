// Pins the shared chat-attachment staging helper (issue #313): the exact
// semantics both the app's AgentService.stageAttachment and the extension
// SW staging op run — sanitize flattening (E2 name attacks), collision
// dedupe (`name-1.ext`), directory creation, and the thrown StateError
// contract (callers surface it, never fail silently).
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('stages a fresh name under uploads/ and returns the relative path',
      () async {
    final env = MemoryExecutionEnv();
    final path = await stageUpload(
      env,
      name: 'pasted-1789302656781.txt',
      bytes: Uint8List.fromList('hello'.codeUnits),
    );
    expect(path, 'uploads/pasted-1789302656781.txt');
    final read = await env.readBinaryFile(path);
    expect(read.valueOrNull, Uint8List.fromList('hello'.codeUnits));
  });

  test('dedupes collisions report-1.ext style (AC5/E3)', () async {
    final env = MemoryExecutionEnv();
    final bytes = Uint8List.fromList(const [1]);
    final first = await stageUpload(env, name: 'report.pdf', bytes: bytes);
    final second = await stageUpload(env, name: 'report.pdf', bytes: bytes);
    final third = await stageUpload(env, name: 'report.pdf', bytes: bytes);
    expect([first, second, third],
        ['uploads/report.pdf', 'uploads/report-1.pdf', 'uploads/report-2.pdf']);
  });

  test('appends the suffix whole when the name has no extension', () async {
    final env = MemoryExecutionEnv();
    final bytes = Uint8List.fromList(const [1]);
    final first = await stageUpload(env, name: 'LICENSE', bytes: bytes);
    final second = await stageUpload(env, name: 'LICENSE', bytes: bytes);
    expect([first, second], ['uploads/LICENSE', 'uploads/LICENSE-1']);
  });

  test('flattens path attacks (E2): ../, absolute, webkitRelativePath',
      () async {
    final env = MemoryExecutionEnv();
    final bytes = Uint8List.fromList(const [1]);
    expect(
      await stageUpload(env, name: '../../x.txt', bytes: bytes),
      'uploads/x.txt',
    );
    expect(
      await stageUpload(env, name: '/etc/passwd', bytes: bytes),
      'uploads/passwd',
    );
    expect(
      await stageUpload(
        env,
        name: 'some/deep/tree/shot.png',
        bytes: bytes,
      ),
      'uploads/shot.png',
    );
    // Nothing escaped uploads/: no sibling file landed at the flattened
    // or raw paths.
    expect((await env.exists('x.txt')).valueOrNull ?? false, isFalse);
    expect((await env.exists('passwd')).valueOrNull ?? false, isFalse);
  });

  test('empty base name is a named StateError, never a silent no-op',
      () async {
    final env = MemoryExecutionEnv();
    await expectLater(
      stageUpload(env, name: '', bytes: Uint8List.fromList(const [1])),
      throwsStateError,
    );
    await expectLater(
      stageUpload(env, name: '..', bytes: Uint8List.fromList(const [1])),
      throwsStateError,
    );
  });
}
