import 'dart:convert';
import 'dart:math';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Issue #135 AC3 property test (review round 2): a SEEDED RANDOM
/// interleaving of page-ups, page-downs, and jumps over a large session
/// must keep every windowed view exact — the resident window is always a
/// gapless, duplicate-free, ordered slice of the branch, every tap delta
/// is exactly the slice adjacent to the pre-op window, and draining to
/// the top reaches e0. Deterministic: same seed, same walk.
void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/walk.jsonl';

  setUp(() {
    fs = MemoryFileSystem();
  });

  Future<void> seedRaw(int count) async {
    const iso = '2026-01-01T00:00:00.000Z';
    final buffer = StringBuffer(
      '{"type":"session","version":3,"id":"walk","timestamp":"$iso",'
      '"cwd":"/work"}\n',
    );
    for (var i = 0; i < count; i++) {
      buffer.write(
        '{"type":"message","id":"e$i","parentId":'
        '${i == 0 ? 'null' : '"e${i - 1}"'},"timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"message $i"}]}}\n',
      );
    }
    await fs.writeFile(path, buffer.toString());
  }

  /// The single-chain fixture makes exactness checkable as integer
  /// contiguity: e(k), e(k+1), e(k+2), ... — no gap, no duplicate, no
  /// reordering.
  void expectContiguous(List<String> ids, String because) {
    expect(ids, isNotEmpty, reason: because);
    for (var i = 1; i < ids.length; i++) {
      final prev = int.parse(ids[i - 1].substring(1));
      final current = int.parse(ids[i].substring(1));
      expect(
        current,
        prev + 1,
        reason: '$because: break between e$prev and e$current at $i',
      );
    }
  }

  test('seeded random walk of taps and jumps keeps every view exact', () async {
    const recordCount = 1500;
    for (final seed in [1, 7, 42, 1337, 90210]) {
      await seedRaw(recordCount);
      final random = Random(seed);
      final storage = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 50 + random.nextInt(100),
        residentRecords: 100 + random.nextInt(300),
        residentBytes: 1 << 30,
      );
      final because = 'seed $seed';
      var window = [for (final record in await storage.getEntries()) record.id];
      expectContiguous(window, '$because: open tail');

      for (var step = 0; step < 120; step++) {
        final before = window;
        switch (random.nextInt(3)) {
          case 0:
            if (storage.hasOlder) {
              final delta = [
                for (final record in await storage.loadOlder()) record.id,
              ];
              expect(delta, isNotEmpty, reason: '$because: tap-up stalled');
              // The delta is EXACTLY the slice above the pre-op window:
              // its newest record touches the window top, so a service
              // prepending it reconstructs history with no gap, no
              // duplicate, no reordering (AC3).
              expectContiguous(delta, '$because step $step: tap-up delta');
              expect(
                delta.last,
                _before(before.first),
                reason: '$because step $step: tap-up delta not adjacent',
              );
            }
          case 1:
            if (storage.hasNewer) {
              final delta = [
                for (final record in await storage.loadNewer()) record.id,
              ];
              expect(delta, isNotEmpty, reason: '$because: tap-down stalled');
              // The delta is EXACTLY the slice below the pre-op window:
              // its oldest record touches the window bottom. The
              // window's newest side may have slid out on an earlier
              // page-up — adjacency against the PRE-op window catches
              // any gap or overlap.
              expectContiguous(delta, '$because step $step: tap-down delta');
              expect(
                delta.first,
                _after(before.last),
                reason: '$because step $step: tap-down delta not adjacent',
              );
            }
          case 2:
            // Jump to any EXPLORED record's offset (the sparse map); an
            // unexplored target skips the step.
            final target = random.nextInt(recordCount);
            final offset = storage.offsetOf('e$target');
            if (offset != null) {
              final branch = [
                for (final record in await storage.jumpToOffset(offset))
                  record.id,
              ];
              expect(branch, isNotEmpty, reason: '$because: jump lost target');
              expect(
                branch.contains('e$target'),
                isTrue,
                reason: '$because: jump window missed target e$target',
              );
            }
        }
        // The resident window itself is always an exact contiguous
        // slice of the branch.
        window = [for (final r in await storage.getEntries()) r.id];
        expectContiguous(window, '$because step $step');
      }

      // Drain to the file top: every delta touches the window top, and
      // the accumulated slice finally starts at e0.
      while (storage.hasOlder) {
        final delta = [for (final r in await storage.loadOlder()) r.id];
        if (delta.isEmpty) fail('$because: loadOlder stalled at the top');
        expect(delta.last, _before(window.first));
        window = [...delta, ...window];
      }
      expect(window.first, 'e0');
      expect(await storage.countAbove(), 0);
    }
  });

  // Issue #2255 AC2: the append cursor is BYTE math. Random mixed-script
  // appends (ASCII / Latin-1 accents / CJK / emoji, where UTF-16 code
  // units and UTF-8 bytes diverge arbitrarily) must keep the cursor on
  // the real file size and every offset byte-exact. Deterministic: same
  // seed, same walk.
  test('mixed-script appends keep the cursor byte-exact', () async {
    const scripts = [
      'plain ascii body',
      'café naïve résumé — déjà vu',
      '日本語のテキスト、汉字、한국어',
      'emoji 🎉☕️ flags 🇯🇵 family 👨‍👩‍👧',
      'русский текст українська мова',
    ];
    for (final seed in [1, 42, 90210]) {
      const iso = '2026-01-01T00:00:00.000Z';
      await fs.writeFile(
        path,
        '{"type":"session","version":3,"id":"walk","timestamp":"$iso",'
        '"cwd":"/work"}\n',
      );
      final storage = await WindowedSessionStorage.open(fs, path);
      final random = Random(seed);
      final appended = <String>[];
      for (var i = 0; i < 60; i++) {
        final text =
            '${scripts[random.nextInt(scripts.length)]} #$i '
            '${scripts[random.nextInt(scripts.length)]}';
        final record = MessageRecord(
          id: 'm$i',
          parentId: i == 0 ? null : 'm${i - 1}',
          timestamp: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          message: UserMessage.text(text),
        );
        await storage.appendEntry(record);
        appended.add(record.id);
        expect(
          storage.knownFileBytes,
          (await storage.reader.stat())!.size,
          reason: 'seed $seed record $i: cursor diverged from file size',
        );
      }

      // Ground truth: a raw newline scan of the file bytes. Every
      // offset byte-exact, cursor on the real size.
      final raw = (await fs.readBinaryFile(path)).getOrThrow();
      final truth = <String, int>{};
      var start = 0;
      for (var i = 0; i <= raw.length; i++) {
        if (i == raw.length || raw[i] == 0x0A) {
          final id = RegExp(
            '"id":"([^"]+)"',
          ).firstMatch(utf8.decode(raw.sublist(start, i)))?.group(1);
          if (id != null) truth[id] = start;
          start = i + 1;
        }
      }
      expect(storage.knownFileBytes, raw.length, reason: 'seed $seed');
      for (final id in appended) {
        expect(storage.offsetOf(id), truth[id], reason: 'seed $seed: $id');
      }
    }
  });
}

String _before(String id) => 'e${int.parse(id.substring(1)) - 1}';

String _after(String id) => 'e${int.parse(id.substring(1)) + 1}';
