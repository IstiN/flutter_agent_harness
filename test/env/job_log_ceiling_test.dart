/// Pure policy unit tests for the bounded background-job-log ceiling
/// (issue #919): byte identity below the ceiling (UT-2), the truncation
/// crossing (head + one marker + patched tail), marker uniqueness on a
/// pathological stream (E2), UTF-8 sequence-boundary safety (E1), and the
/// low-disk guard (UT-4). The io integration that pins real file bytes
/// lives in `shell_job_io_test.dart`.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('below the ceiling (UT-2)', () {
    test('every chunk appends byte-identically, in order', () async {
      final ceiling = JobLogCeiling(maxBytes: 1024);
      final ops = [
        ...await ceiling.ingest('a\n'),
        ...await ceiling.ingest('b\n'),
        ...await ceiling.ingest('ccc\n'),
      ];
      expect(ceiling.truncated, isFalse);
      expect(ceiling.producedBytes, 8);
      expect(ceiling.settleFlush(), isNull);
      expect(
        [for (final op in ops) (op.offset, op.text)],
        [(null, 'a\n'), (null, 'b\n'), (null, 'ccc\n')],
      );
    });
  });

  group('the truncation crossing', () {
    test('one marker append, then patch ops at the head boundary', () async {
      const maxBytes = 512; // head budget 256, tail budget 128
      final ceiling = JobLogCeiling(maxBytes: maxBytes);

      // Chunks inside the head budget append untouched.
      final head = await ceiling.ingest('h' * 200);
      expect(head.single.offset, isNull);
      expect(head.single.text, 'h' * 200);

      // The crossing chunk becomes ONE append: marker + first tail bytes.
      // Nothing is dropped yet, so the marker starts at 0.
      final cross = await ceiling.ingest('c' * 100);
      expect(ceiling.truncated, isTrue);
      expect(cross.single.offset, isNull);
      expect(cross.single.text, jobLogTruncationMarker(0) + 'c' * 100);

      // > jobLogTailFlushEveryBytes of further output: patched in place at
      // the seam (offset == headBytes == 200), never appended.
      final patches = <JobLogWrite>[];
      for (var i = 0; i < 9; i++) {
        patches.addAll(await ceiling.ingest('t' * 8192)); // 72 KiB > 64 KiB
      }
      expect(patches, isNotEmpty);
      for (final op in patches) {
        expect(op.offset, 200);
        expect(op.text, startsWith('[… log truncated:'));
      }

      // settleFlush re-patches once with the exact dropped count:
      // produced 74028 = 200 head + 128 tail + 73700 dropped.
      expect(ceiling.producedBytes, 74028);
      final settle = ceiling.settleFlush();
      expect(settle, isNotNull);
      expect(settle!.offset, 200);
      expect(
        settle.text,
        jobLogTruncationMarker(ceiling.producedBytes - 200 - 128) + 't' * 128,
      );
    });

    test(
      'E2: a pathological stream keeps exactly one marker per region',
      () async {
        final ceiling = JobLogCeiling(maxBytes: 1024);
        final regions = <String>[];
        for (final chunk in List.generate(200, (i) => 'noise-$i-' * 20)) {
          for (final op in await ceiling.ingest(chunk)) {
            regions.add(op.text);
          }
        }
        final settle = ceiling.settleFlush();
        expect(settle, isNotNull);
        regions.add(settle!.text);

        // Exactly two regions carry the marker — the crossing append and the
        // final patch — and each contains it exactly once, never more.
        final markerRegions = regions.where(
          (region) => region.contains('[… log truncated:'),
        );
        expect(markerRegions, hasLength(2));
        for (final region in markerRegions) {
          expect('[… log truncated:'.allMatches(region), hasLength(1));
        }
        // The first four 160-byte chunks filled the 640-byte head exactly;
        // the final dropped count is the produced total minus head and tail.
        expect(
          settle.text,
          startsWith(jobLogTruncationMarker(ceiling.producedBytes - 640 - 256)),
        );
      },
    );

    test('E1: a multibyte tail trims on UTF-8 sequence boundaries', () async {
      const maxBytes = 4096; // head budget 2944, tail budget 1024
      final ceiling = JobLogCeiling(maxBytes: maxBytes);
      final regions = <String>[];
      regions.addAll((await ceiling.ingest('a' * 2944)).map((op) => op.text));
      // 'é' is 2 UTF-8 bytes: 20 chunks x 200 bytes repeatedly overflow the
      // 1024-byte tail, forcing mid-sequence trims down to whole chars.
      for (var i = 0; i < 20; i++) {
        regions.addAll((await ceiling.ingest('é' * 100)).map((op) => op.text));
      }
      final settle = ceiling.settleFlush();
      expect(settle, isNotNull);

      // produced 6944 = 2944 head + 1024 tail + 2976 dropped; the tail is
      // exactly 1024 bytes = 512 whole é characters. Matching this exact
      // text proves the region decodes cleanly (a split sequence would
      // surface as U+FFFD or a decode error inside _regionText).
      expect(
        settle!.text,
        jobLogTruncationMarker(6944 - 2944 - 1024) + 'é' * 512,
      );
      for (final region in regions) {
        expect(region.contains('�'), isFalse);
      }
      expect(ceiling.producedBytes, 6944);
    });

    test('the tail region is capped at 1 MiB at large ceilings and the '
        'patch churn stays within ~2x the post-crossing bytes (review: '
        'write amplification)', () async {
      const mib = 1024 * 1024;
      final ceiling = JobLogCeiling(maxBytes: 8 * mib);
      var patchBytes = 0;
      var produced = 0;
      // Pipe-sized chunks: the runaway pattern that once grew a log to
      // 335 GB. A ceiling-proportional tail rewritten at a fixed 64 KiB
      // cadence would amplify these into hundreds of MB of rewrites.
      while (produced < 9 * mib) {
        final ops = await ceiling.ingest('x' * 8192);
        produced += 8192;
        for (final op in ops) {
          // Region = marker + capped tail, never a ceiling-proportional
          // region (the old maxBytes/4 tail at 8 MiB was 2 MiB).
          expect(op.text.length, lessThan(mib + 128));
          patchBytes += op.text.length;
        }
      }
      final settle = ceiling.settleFlush();
      patchBytes += settle?.text.length ?? 0;
      expect(ceiling.truncated, isTrue);
      expect(patchBytes, lessThan(2 * produced + 2 * mib));
    });
  });

  group('validation', () {
    test('non-positive ceilings are rejected loudly (public API)', () {
      for (final bad in [0, -1, -50 * 1024 * 1024]) {
        expect(
          () => JobLogCeiling(maxBytes: bad),
          throwsArgumentError,
          reason: 'maxBytes=$bad must not silently degrade the layout',
        );
      }
    });
  });

  group('low-disk guard (UT-4)', () {
    test(
      'a below-threshold probe stops writes and warns exactly once',
      () async {
        var probes = 0;
        final warnings = <String>[];
        final ceiling = JobLogCeiling(
          probe: () async {
            probes++;
            return 1024; // far below the 1 GB threshold
          },
          onWarn: warnings.add,
        );
        expect(await ceiling.ingest('one'), isEmpty);
        expect(ceiling.writesStopped, isTrue);
        expect(warnings, hasLength(1));
        expect(warnings.single, contains('log writes stopped'));

        // Later chunks are dropped wholesale and stay unproduced; the log is
        // left frozen with no marker to fix up.
        expect(await ceiling.ingest('two'), isEmpty);
        expect(await ceiling.ingest('three'), isEmpty);
        expect(warnings, hasLength(1));
        expect(ceiling.producedBytes, 0);
        expect(ceiling.truncated, isFalse);
        expect(ceiling.settleFlush(), isNull);
        expect(probes, 1);
      },
    );

    test('a null or healthy probe keeps writes flowing', () async {
      final unknown = JobLogCeiling(maxBytes: 1024, probe: () async => null);
      expect((await unknown.ingest('kept')).single.text, 'kept');
      expect(unknown.writesStopped, isFalse);

      final healthy = JobLogCeiling(
        maxBytes: 1024,
        probe: () async => defaultJobLogMinFreeBytes * 2,
        onWarn: (message) => fail('no warning expected: $message'),
      );
      expect((await healthy.ingest('kept too')).single.text, 'kept too');
      expect(healthy.writesStopped, isFalse);
    });

    test('a throwing probe leaves the guard inactive', () async {
      final ceiling = JobLogCeiling(
        maxBytes: 1024,
        probe: () async => throw StateError('df exploded'),
      );
      expect((await ceiling.ingest('kept')).single.text, 'kept');
      expect(ceiling.writesStopped, isFalse);
      expect(ceiling.settleFlush(), isNull);
    });

    test('the probe runs at most once per produced cadence window', () async {
      var probes = 0;
      final ceiling = JobLogCeiling(
        maxBytes: 1 << 30,
        probe: () async {
          probes++;
          return defaultJobLogMinFreeBytes * 2;
        },
      );
      for (var i = 0; i < 3; i++) {
        await ceiling.ingest('x' * 4096); // 12 KiB total, far below 1 MiB
      }
      expect(probes, 1); // only the mandatory first-chunk check
    });
  });
}
