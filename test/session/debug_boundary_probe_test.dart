import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('record starting exactly at a block boundary is scanned', () async {
    const block = 4096;
    final prev = JsonlSessionRepo.debugCustomRecordScanBlockBytes;
    JsonlSessionRepo.debugCustomRecordScanBlockBytes = block;
    addTearDown(() => JsonlSessionRepo.debugCustomRecordScanBlockBytes = prev);
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    final meta = (await repo.list(cwd: '/work')).single;

    Future<int> size() async =>
        (await env.fileInfo(meta.path)).valueOrNull!.size;

    // Pad with a benign raw filler line so the NEXT record starts exactly
    // at a 4096-byte block boundary (previous block ends with '\n').
    final padLen = (block - (await size() % block)) % block;
    if (padLen > 0) {
      await env.appendFile(meta.path, '${'x' * (padLen - 1)}\n');
    }
    expect(await size() % block, 0, reason: 'newline exactly at boundary');

    await session.appendCustomEntry(
      customType: 'steering',
      data: {'text': 'aligned-at-boundary'},
    );
    // A trailing record so the steering line's newline is INSIDE its block
    // (line fully contained: starts at boundary, ends before block end).
    await session.appendMessage(UserMessage.text('tail'));

    final records = await repo.readCustomRecordsOfType(meta, {'steering'});
    expect(
      records.map((r) => (r.data as Map)['text']),
      contains('aligned-at-boundary'),
    );
  });
}
