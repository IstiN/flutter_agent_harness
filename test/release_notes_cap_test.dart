// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-237 behavioral tests for scripts/release_notes_cap.sh — the bounded
// release-body helper. The daily-publish cli leg (run 44680647719,
// v1.0.756) died in three attach jobs because `release_notes.sh` returned
// the curated `## Unreleased` CHANGELOG section (131,072 bytes) as the
// release body, over GitHub's hard release-body cap of 125,000 characters:
// `gh release create` answered `HTTP 422: body is too long (maximum is
// 125000 characters)`, release_lazy_draft.sh swallowed the failure
// (`|| true`) and printed "✅ lazy draft ready", and the attach gate
// failed with "release not found". The helper bounds a notes file under
// the API cap at a line boundary with an explicit marker — the release
// page body is a VIEW; the full curated notes stay in CHANGELOG.md (the
// staged pub.dev changelog is stamped from release_notes.sh uncapped, so
// the cap must NOT live there).
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Runs the helper over [file] with an explicit [cap] (the scripts pass
/// the default implicitly — tests pin the semantics with small caps).
ProcessResult runCap(String file, {int? cap}) => Process.runSync(
  'bash',
  [
    File('scripts/release_notes_cap.sh').absolute.path,
    file,
    if (cap != null) '$cap',
  ],
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

/// A notes file of [size] bytes: newline-terminated [lineBytes]-byte lines
/// ('a' * n + '\n') so a line-boundary cut has plenty of candidates.
File makeNotes(String path, int size, {int lineBytes = 100}) {
  final lines = size ~/ (lineBytes + 1);
  final buf = StringBuffer();
  for (var i = 0; i < lines; i++) {
    buf.write('a' * lineBytes);
    buf.write('\n');
  }
  final f = File(path)..parent.createSync(recursive: true);
  f.writeAsStringSync(buf.toString());
  return f;
}

void main() {
  late Directory td;
  setUp(() {
    td = Directory.systemTemp.createTempSync('gh2337_notes_cap');
    addTearDown(() => td.deleteSync(recursive: true));
  });

  test('under-cap file passes through byte-identical (no-op)', () {
    final f = makeNotes('${td.path}/small.md', 500);
    final before = f.readAsBytesSync();
    final r = runCap(f.path, cap: 1000);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(f.readAsBytesSync(), before);
  });

  test('exactly-at-cap file passes through byte-identical (no-op)', () {
    final f = makeNotes('${td.path}/exact.md', 1000);
    final before = f.readAsBytesSync();
    final r = runCap(f.path, cap: 1000);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(f.readAsBytesSync(), before);
  });

  test(
    'over-cap file is truncated under the cap with a CHANGELOG.md marker',
    () {
      const cap = 1000;
      final f = makeNotes('${td.path}/big.md', 5000);
      final original = f.lengthSync();
      final r = runCap(f.path, cap: cap);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final after = f.readAsStringSync();
      expect(
        f.lengthSync(),
        lessThanOrEqualTo(cap),
        reason: 'the bounded body must fit the cap the caller asked for',
      );
      expect(after, contains('truncated'));
      expect(after, contains('CHANGELOG.md'));
      expect(f.lengthSync(), lessThan(original));
    },
  );

  test('truncation lands on a line boundary (no partial line)', () {
    const cap = 1000;
    final f = makeNotes('${td.path}/lines.md', 5000, lineBytes: 100);
    runCap(f.path, cap: cap);
    final body = f.readAsStringSync();
    final markerStart = body.indexOf('…(truncated');
    expect(markerStart, greaterThan(0));
    // Everything before the marker is whole lines: '\n' right before it.
    expect(body.substring(markerStart - 1, markerStart), '\n');
    expect(
      body.substring(0, markerStart).split('\n').first.length,
      100,
      reason: 'the first kept line must be an intact line',
    );
  });

  test('UTF-8 multibyte content survives the cut undamaged', () {
    // Long dash (3 bytes) + 'é' (2 bytes) repeated — a naive byte cut
    // would split a code point and produce invalid UTF-8.
    final unit = '—é—é—é—é\n';
    final f = File('${td.path}/utf8.md');
    f.writeAsStringSync(unit * 400); // 400 lines × 28 bytes = 11200
    final r = runCap(f.path, cap: 1000);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final body = f.readAsStringSync();
    // Decoding already throws in readAsStringSync if invalid; assert the
    // kept prefix explicitly.
    final markerStart = body.indexOf('…(truncated');
    final kept = body.substring(0, markerStart);
    expect(kept, isNotEmpty);
    expect(kept.runes.last, isNonZero);
  });

  test('marker reports the dropped byte count', () {
    final f = makeNotes('${td.path}/drop.md', 5000);
    runCap(f.path, cap: 1000);
    final body = f.readAsStringSync();
    final m = RegExp(r'truncated — (\d+) bytes dropped').firstMatch(body);
    expect(m, isNotNull, reason: body);
    final dropped = int.parse(m!.group(1)!);
    expect(dropped, greaterThan(0));
    expect(dropped, lessThan(5000));
  });

  test('missing file fails loud with a ::error::', () {
    final r = runCap('${td.path}/nope.md', cap: 1000);
    expect(r.exitCode, isNot(0));
    expect(r.stderr, contains('::error::'));
  });

  test('idempotent: a second run is a no-op', () {
    final f = makeNotes('${td.path}/twice.md', 5000);
    runCap(f.path, cap: 1000);
    final afterFirst = f.readAsBytesSync();
    final r = runCap(f.path, cap: 1000);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(f.readAsBytesSync(), afterFirst);
  });

  test('single newline-less giant line: byte cut stays UTF-8-valid', () {
    // The line-boundary preference has no newline to land on — the
    // UTF-8 code-point backoff must keep the kept prefix decodable.
    final f = File('${td.path}/giant-line.md');
    f.writeAsStringSync('é' * 3000); // 6000 bytes, no newline at all
    final r = runCap(f.path, cap: 1000);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(f.lengthSync(), lessThanOrEqualTo(1000));
    final body = f.readAsStringSync(); // throws if the cut split a point
    expect(body, contains('truncated'));
    expect(body, contains('CHANGELOG.md'));
  });

  test('content without a trailing newline is cut cleanly', () {
    final f = File('${td.path}/no-tail-nl.md');
    final buf = StringBuffer();
    for (var i = 0; i < 40; i++) {
      buf.write('${'b' * 100}\n');
    }
    buf.write('c' * 500); // final line, no trailing newline
    f.writeAsStringSync(buf.toString()); // 4500 bytes
    final r = runCap(f.path, cap: 1000);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(f.lengthSync(), lessThanOrEqualTo(1000));
    final body = f.readAsStringSync();
    expect(body, contains('truncated'));
    // The kept prefix still ends at a whole line (the partial 'c' tail
    // line is dropped, not half-shipped).
    final markerStart = body.indexOf('…(truncated');
    expect(body.substring(markerStart - 1, markerStart), '\n');
  });
}
