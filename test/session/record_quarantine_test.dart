import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/session_repair.dart';
import 'package:test/test.dart';

/// gh-2178 — unbrickable session reads: malformed persisted timestamps
/// quarantine themselves (tolerant decode + one-time named report +
/// repair scan) instead of crashing every turn behind a provider error.
void main() {
  // Incident fixture (gh-2178) — real values, treated strictly as data.
  const incidentRecordId = '01a1d4b0-c9b6-709b-80c2-3cd97501a715';
  const incidentTimestamp = '2026-11-13T14:35:18.fZ';
  const sessionPath = '/sessions/poisoned.jsonl';

  setUp(() {
    SessionQuarantine.resetForTest();
  });
  tearDown(() {
    SessionQuarantine.resetForTest();
  });

  String headerLine([
    String timestamp = '2026-09-07T00:00:00.000Z',
    String id = 'poisoned',
  ]) => jsonEncode({
    'type': 'session',
    'version': 3,
    'id': id,
    'timestamp': timestamp,
    'cwd': '/work',
  });

  String messageLine(
    String id, {
    String? parentId,
    String timestamp = '2026-09-07T00:00:01.000Z',
    String text = 'hi',
  }) => jsonEncode({
    'type': 'message',
    'id': id,
    'parentId': ?parentId,
    'timestamp': timestamp,
    'message': {'role': 'user', 'content': text},
  });

  /// The incident's poison record: a hand-appended `obligations_ledger`
  /// custom record whose timestamp is not ISO at all.
  String poisonLine({
    String id = incidentRecordId,
    String timestamp = incidentTimestamp,
    String? parentId,
    String customType = 'obligations_ledger',
  }) => jsonEncode({
    'type': 'custom',
    'id': id,
    'parentId': ?parentId,
    'timestamp': timestamp,
    'customType': customType,
    'data': {'gen': 1},
  });

  group('parseRecordTimestamp (gh-2178 AC1/AC2)', () {
    test('UT-3/F1 pin: bare DateTime.parse throws on the incident value; '
        'parseRecordTimestamp does not', () {
      expect(
        () => DateTime.parse(incidentTimestamp),
        throwsA(isA<FormatException>()),
        reason: 'documents WHY the 664 MB session bricked',
      );
      final parsed = parseRecordTimestamp(incidentTimestamp);
      expect(parsed.degraded, isTrue);
    });

    test('UT-1/AC1: every malformed fixture degrades to the deterministic '
        'placeholder and nothing throws', () {
      const malformed = [
        incidentTimestamp, // the incident: strftime-style .fZ fraction
        '', // empty
        '<garbage>',
        '1773000000000', // numeric epoch string — NOT invented into a parse
        'not-a-date',
      ];
      for (final raw in malformed) {
        final parsed = parseRecordTimestamp(raw);
        expect(
          parsed.degraded,
          isTrue,
          reason: '"$raw" must degrade, not throw',
        );
        expect(
          parsed.value,
          DateTime.fromMillisecondsSinceEpoch(0),
          reason: '"$raw" must land on the deterministic epoch placeholder',
        );
      }
    });

    test('parseRecordTimestamp keeps the bare-parse normalization grammar '
        '(INV4: out-of-range fields normalize, they do not degrade)', () {
      // Dart's DateTime.parse normalizes out-of-range fields — part of
      // the accepted grammar today, so it must stay accepted.
      final parsed = parseRecordTimestamp('2026-13-45T99:99:99Z');
      expect(parsed.degraded, isFalse);
      expect(parsed.value, DateTime.parse('2026-13-45T99:99:99Z'));
    });

    test('UT-2/AC2 golden: valid ISO decodes to the EXACT bare-parse value '
        '(zero drift, E4/E5)', () {
      const valid = [
        '2026-11-13T14:35:18.198Z',
        '2026-11-13T14:35:18Z', // no fraction
        '2026-11-13T14:35:18.123456Z', // 6-digit micros
        '2026-11-13T14:35:18.123456789Z', // 9-digit fractions
        '2026-11-13T14:35:18+02:00', // offset form
        '2026-11-13T14:35:18.5-05:30', // fraction + negative offset
        '2026-11-13 14:35:18', // space separator (accepted today)
      ];
      for (final raw in valid) {
        final expected = DateTime.parse(raw);
        final parsed = parseRecordTimestamp(raw);
        expect(parsed.degraded, isFalse, reason: raw);
        expect(
          parsed.value,
          expected,
          reason: 'zero drift required for "$raw"',
        );
        expect(
          parsed.value.microsecondsSinceEpoch,
          expected.microsecondsSinceEpoch,
        );
      }
    });

    test('REG-2 property: a random valid-ISO corpus matches the bare parse, '
        'always', () {
      final base = DateTime.utc(2026, 1, 1);
      var seed = 20261113;
      int next() {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed;
      }

      for (var i = 0; i < 500; i++) {
        final ms = next() % (400 * 24 * 3600 * 1000);
        final instant = base.add(Duration(milliseconds: ms));
        final forms = [
          instant.toUtc().toIso8601String(),
          instant.toIso8601String(),
          '${instant.toUtc().toIso8601String().split('.').first}Z',
        ];
        for (final raw in forms) {
          final parsed = parseRecordTimestamp(raw);
          expect(parsed.degraded, isFalse, reason: raw);
          expect(parsed.value, DateTime.parse(raw), reason: raw);
        }
      }
    });
  });

  group('decode sites route through the tolerant parser (gh-2178)', () {
    test('SessionRecord.fromJson degrades a poison timestamp and keeps the '
        'payload intact', () {
      final record = SessionRecord.fromJson(
        (jsonDecode(poisonLine()) as Map).cast<String, dynamic>(),
      );
      expect(record, isA<CustomRecord>());
      expect(record.timestampDegraded, isTrue);
      expect(record.timestamp, DateTime.fromMillisecondsSinceEpoch(0));
      final custom = record as CustomRecord;
      expect(custom.id, incidentRecordId);
      expect(custom.customType, 'obligations_ledger');
      expect(custom.data, {'gen': 1});
    });

    test('SessionRecord.fromJson keeps valid records non-degraded '
        '(INV4 zero drift)', () {
      final record = SessionRecord.fromJson(
        (jsonDecode(messageLine('m1')) as Map).cast<String, dynamic>(),
      );
      expect(record.timestampDegraded, isFalse);
      expect(record.timestamp, DateTime.parse('2026-09-07T00:00:01.000Z'));
    });

    test('UT-4/F2 forensics pin: generateSessionEntryId emits the 8-char '
        'uuidv7 tail, never a full uuidv7 (no runtime gate is built)', () {
      final byId = <String, SessionRecord>{};
      for (var i = 0; i < 10000; i++) {
        final id = generateSessionEntryId(byId);
        expect(id.length, 8, reason: 'sampled $i ids before drift');
        byId[id] = MessageRecord(
          id: id,
          parentId: null,
          timestamp: DateTime.now(),
          message: UserMessage.text('x'),
        );
      }
    });

    test('SessionHeader.fromJson degrades a poison header timestamp (E1 '
        'path 1)', () {
      final header = SessionHeader.fromJson(
        (jsonDecode(headerLine(incidentTimestamp)) as Map)
            .cast<String, dynamic>(),
      );
      expect(header.timestampDegraded, isTrue);
      expect(header.timestamp, DateTime.fromMillisecondsSinceEpoch(0));
      final clean = SessionHeader.fromJson(
        (jsonDecode(headerLine()) as Map).cast<String, dynamic>(),
      );
      expect(clean.timestampDegraded, isFalse);
    });
  });

  group('quarantine report (gh-2178 AC5, INV3, E9)', () {
    test('UT-5: the report names file, line, record id and the bounded raw '
        'value, once per decode', () {
      final reports = <String>[];
      SessionQuarantine.onQuarantined = reports.add;
      final line = poisonLine();
      parseSessionEntryLine(line, sessionPath, 36937);
      expect(reports, hasLength(1));
      final report = reports.single;
      expect(report, contains(sessionPath));
      expect(report, contains('36937'));
      expect(report, contains(incidentRecordId));
      expect(report, contains(incidentTimestamp));
    });

    test('UT-6/INV3/AC5: the same record across 3 decodes reports exactly '
        'once', () {
      final reports = <String>[];
      SessionQuarantine.onQuarantined = reports.add;
      final line = poisonLine();
      for (var turn = 0; turn < 3; turn++) {
        parseSessionEntryLine(line, sessionPath, 36937);
      }
      expect(reports, hasLength(1));
    });

    test('UT-7/E9 flood cap: N poison records report individually up to the '
        'cap, then one count summary', () {
      final reports = <String>[];
      SessionQuarantine.onQuarantined = reports.add;
      const n = 30;
      for (var i = 0; i < n; i++) {
        parseSessionEntryLine(
          poisonLine(id: 'poison-$i'),
          sessionPath,
          100 + i,
        );
      }
      final individual = reports
          .where((line) => !line.contains('suppressed'))
          .toList();
      final summaries = reports
          .where((line) => line.contains('suppressed'))
          .toList();
      expect(individual.length, SessionQuarantine.maxReportedRecords);
      expect(summaries, hasLength(1));
      expect(SessionQuarantine.suppressedCount, n - individual.length);
    });

    test('the raw value excerpt is bounded and single-line (threat model: '
        'no record content beyond the bounded literal)', () {
      final reports = <String>[];
      SessionQuarantine.onQuarantined = reports.add;
      final hugeRaw = '${'x' * 500}\n${'y' * 500}';
      parseSessionEntryLine(poisonLine(timestamp: hugeRaw), sessionPath, 7);
      expect(reports, hasLength(1));
      expect(reports.single.length, lessThan(400));
      expect(reports.single.contains('\n'), isFalse);
    });

    test('a clean decode reports nothing (INV4: valid input is silent)', () {
      final reports = <String>[];
      SessionQuarantine.onQuarantined = reports.add;
      parseSessionEntryLine(messageLine('m1'), sessionPath, 2);
      expect(reports, isEmpty);
    });

    test('parseSessionHeaderLine reports a degraded header (E1)', () {
      final reports = <String>[];
      SessionQuarantine.onQuarantined = reports.add;
      parseSessionHeaderLine(headerLine(incidentTimestamp), sessionPath);
      expect(reports, hasLength(1));
      expect(reports.single, contains(sessionPath));
      expect(reports.single, contains(incidentTimestamp));
    });

    test('parseShallowCustomRecord degrades in place (site 3) and reports '
        'with the batch line number', () {
      final reports = <String>[];
      SessionQuarantine.onQuarantined = reports.add;
      final giant = jsonEncode({
        'type': 'custom',
        'id': incidentRecordId,
        'parentId': null,
        'timestamp': incidentTimestamp,
        'customType': 'obligations_ledger',
        'data': {'blob': 'x' * (80 << 10)},
      });
      final result = parseSessionEntryLinesSync(
        SessionParseBatch(
          filePath: sessionPath,
          firstLineNumber: 5,
          lines: [giant],
          shallowGiantCustoms: true,
        ),
      );
      final parsed = result.records.single;
      expect(parsed, isA<CustomRecord>());
      expect(parsed!.timestampDegraded, isTrue);
      expect(reports, hasLength(1));
      expect(reports.single, contains('5'));
      // The batch's own finding carries the REAL raw value now (the
      // top-level gate extracts it from the line) — before the gate
      // fired, every isolate-path finding degraded to an empty excerpt.
      expect(result.quarantined.single.rawTimestamp, incidentTimestamp);
      expect(result.quarantined.single.lineNumber, 5);
    });

    test('second tier UT-8: ProviderQuota.fromJson with a poison resetsAt/'
        'updatedAt degrades without throwing', () {
      final quota = ProviderQuota.fromJson({
        'used': 1.0,
        'limit': 10.0,
        'unit': 'tokens',
        'resetsAt': incidentTimestamp,
        'updatedAt': incidentTimestamp,
      });
      expect(quota.timestampsDegraded, isTrue);
      expect(quota.resetsAt, DateTime.fromMillisecondsSinceEpoch(0));
      expect(quota.updatedAt, DateTime.fromMillisecondsSinceEpoch(0));
      final clean = ProviderQuota.fromJson({
        'used': 1.0,
        'limit': 10.0,
        'unit': 'tokens',
        'resetsAt': '2026-11-13T14:35:18.198Z',
        'updatedAt': '2026-11-13T14:35:19.000Z',
      });
      expect(clean.timestampsDegraded, isFalse);
      expect(clean.resetsAt, DateTime.parse('2026-11-13T14:35:18.198Z'));
    });
  });

  group('branch-walk quarantine exclusion (gh-2178 AC4, E7)', () {
    test('a degraded record is absent from getBranch; its children stay '
        'usable (treated as absent)', () async {
      final fs = MemoryFileSystem(cwd: '/');
      await fs.writeFile(
        sessionPath,
        [
          headerLine(),
          messageLine('m1'),
          poisonLine(parentId: 'm1'),
          messageLine('m2', parentId: incidentRecordId),
        ].join('\n'),
      );
      final storage = await JsonlSessionStorage.open(fs, sessionPath);
      final branch = await storage.getPathToRoot('m2');
      expect(
        branch.map((r) => r.id),
        ['m1', 'm2'],
        reason:
            'the poison record is treated as absent; the walk continues '
            'through its parent',
      );
      expect(branch.where((r) => r.timestampDegraded), isEmpty);
    });

    test('the runtime reader never mutates the session file (INV2/AC4: '
        'bytes preserved verbatim)', () async {
      final fs = MemoryFileSystem(cwd: '/');
      final original = [
        headerLine(),
        messageLine('m1'),
        poisonLine(parentId: 'm1'),
        messageLine('m2', parentId: incidentRecordId),
      ].join('\n');
      await fs.writeFile(sessionPath, original);
      final storage = await JsonlSessionStorage.open(fs, sessionPath);
      await storage.getPathToRoot('m2');
      final after = (await fs.readTextFile(sessionPath)).valueOrNull;
      expect(after, original, reason: 'quarantine is read-time only');
      final listing = (await fs.listDir('/sessions')).valueOrNull!;
      expect(
        listing.map((e) => e.name),
        everyElement(isNot(contains('.corrupt'))),
        reason:
            'a degraded-timestamp record is NOT a torn line — the '
            'quarantine must not trigger the crash-heal rewrite',
      );
      expect(listing.map((e) => e.name), contains('poisoned.jsonl'));
    });

    test('a valid session walks byte-identically (REG-1 golden)', () async {
      final fs = MemoryFileSystem(cwd: '/');
      final lines = [
        headerLine(),
        for (var i = 1; i <= 50; i++)
          messageLine('m$i', parentId: i == 1 ? null : 'm${i - 1}'),
      ];
      await fs.writeFile(sessionPath, lines.join('\n'));
      final storage = await JsonlSessionStorage.open(fs, sessionPath);
      final branch = await storage.getPathToRoot('m50');
      expect(branch, hasLength(50));
      expect([
        for (final r in branch) r.timestamp.toIso8601String(),
      ], everyElement('2026-09-07T00:00:01.000Z'));
      final after = (await fs.readTextFile(sessionPath)).valueOrNull;
      expect(after, lines.join('\n'));
    });
  });

  group('windowed boot survival (gh-2178 AC3/AC7, F3, E3)', () {
    /// 250 small records + the poison at a DEEP position (record 10,
    /// outside the 200-record boot window), mirroring the incident's
    /// line-36,937-of-37,467 mask.
    Future<MemoryFileSystem> deepPoisonFile() async {
      final fs = MemoryFileSystem(cwd: '/');
      final lines = <String>[headerLine()];
      for (var i = 1; i <= 250; i++) {
        if (i == 10) {
          lines.add(poisonLine(parentId: 'm9'));
        } else {
          lines.add(messageLine('m$i', parentId: i == 1 ? null : 'm${i - 1}'));
        }
      }
      await fs.writeFile(sessionPath, lines.join('\n'));
      return fs;
    }

    test('IT-1/AC3: boot succeeds with the poison outside the window; the '
        'paged full-branch walk completes without a throw', () async {
      final fs = await deepPoisonFile();
      final storage = await WindowedSessionStorage.open(fs, sessionPath);
      expect(
        storage.hasOlder,
        isTrue,
        reason:
            'F3: the boot window masks '
            'the deep poison',
      );
      // The CLI resume pages to the compaction boundary (growOlderUntil);
      // the auto-compact full-branch walk must survive the poison.
      final boundary = await storage.growOlderUntil(
        (record) => record is CompactionRecord,
      );
      expect(boundary, isTrue);
      final branch = await storage.getPathToRoot(await storage.getLeafId());
      expect(branch.where((r) => r.timestampDegraded), isEmpty);
      expect(branch.map((r) => r.id), isNot(contains(incidentRecordId)));
      expect(
        branch.map((r) => r.id),
        contains('m250'),
        reason: 'live records stay usable',
      );
    });

    test('IT-2/AC7 negative: poison INSIDE the boot window also never '
        'fails boot', () async {
      final fs = MemoryFileSystem(cwd: '/');
      final lines = <String>[headerLine(), messageLine('m1')];
      for (var i = 2; i <= 12; i++) {
        lines.add(
          i == 6
              ? poisonLine(id: 'inner-poison', parentId: 'm5')
              : messageLine('m$i', parentId: 'm${i - 1}'),
        );
      }
      await fs.writeFile(sessionPath, lines.join('\n'));
      final storage = await WindowedSessionStorage.open(fs, sessionPath);
      final branch = await storage.getPathToRoot(await storage.getLeafId());
      expect(branch.map((r) => r.id), isNot(contains('inner-poison')));
      expect(branch.map((r) => r.id), contains('m12'));
    });

    test('the windowed reader never mutates the file either (INV2)', () async {
      final fs = await deepPoisonFile();
      final before = (await fs.readTextFile(sessionPath)).valueOrNull;
      final storage = await WindowedSessionStorage.open(fs, sessionPath);
      await storage.growOlderUntil((record) => record is CompactionRecord);
      final after = (await fs.readTextFile(sessionPath)).valueOrNull;
      expect(after, before);
    });
  });

  group('repair scan mode (gh-2178 AC6, OQ2 pre-pass)', () {
    Future<MemoryFileSystem> poisonedFile({int deep = 0}) async {
      final fs = MemoryFileSystem(cwd: '/');
      final lines = <String>[headerLine()];
      for (var i = 1; i <= deep + 5; i++) {
        if (i == deep + 1 && deep > 0) {
          lines.add(poisonLine(parentId: 'm$deep'));
        } else if (i == deep + 2 && deep > 0) {
          // The record after the poison chains THROUGH it — the fixed
          // record must rejoin the branch after repair.
          lines.add(messageLine('m$i', parentId: incidentRecordId));
        } else {
          lines.add(messageLine('m$i', parentId: i == 1 ? null : 'm${i - 1}'));
        }
      }
      await fs.writeFile(sessionPath, lines.join('\n'));
      return fs;
    }

    test('the scan lists the poison record (file+line+id+raw) in the '
        'report; a clean file reports none', () async {
      final fs = await poisonedFile(deep: 3);
      final report = await repairSessionLedgers(fs, sessionPath);
      expect(report.malformedTotal, 1);
      expect(report.malformedRecords, hasLength(1));
      final finding = report.malformedRecords.single;
      expect(finding.filePath, sessionPath);
      expect(finding.lineNumber, 5);
      expect(finding.recordId, incidentRecordId);
      expect(finding.rawTimestamp, incidentTimestamp);
      expect(report.summaryLines().join('\n'), contains(incidentTimestamp));

      final cleanFs = await poisonedFile(deep: 0);
      final clean = await repairSessionLedgers(cleanFs, sessionPath);
      expect(clean.malformedTotal, 0);
      expect(clean.malformedRecords, isEmpty);
    });

    test('the scan finds records OUTSIDE any boot window (deep position) '
        'and reports exact physical line numbers', () async {
      final fs = await poisonedFile(deep: 250);
      final report = await repairSessionLedgers(fs, sessionPath);
      expect(report.malformedTotal, 1);
      // header is line 1; m1..m250 are lines 2..251; the poison is 252.
      expect(report.malformedRecords.single.lineNumber, 252);
    });

    test('a repair pass FIXES the record in place: the file resumes with no '
        'quarantine report; bytes change only on the fixed line', () async {
      final fs = await poisonedFile(deep: 3);
      final before = (await fs.readTextFile(sessionPath)).valueOrNull!;
      final reports = <String>[];
      SessionQuarantine.onQuarantined = reports.add;

      final report = await repairSessionLedgers(fs, sessionPath);
      expect(report.malformedRepaired, 1);
      expect(report.backupPath, '$sessionPath.bak');
      expect(
        (await fs.exists('$sessionPath.bak')).valueOrNull,
        isTrue,
        reason: 'the original is preserved at .bak',
      );

      // The fixed line keeps its record identity but carries a valid
      // timestamp now.
      final after = (await fs.readTextFile(sessionPath)).valueOrNull!;
      expect(after, isNot(before));
      final fixedLines = after.split('\n');
      final fixed = fixedLines
          .map((l) => l.isEmpty ? null : jsonDecode(l))
          .whereType<Map>()
          .firstWhere((m) => m['id'] == incidentRecordId);
      expect(fixed['timestamp'], isA<String>());
      expect(
        () => DateTime.parse(fixed['timestamp'] as String),
        returnsNormally,
      );
      expect(fixed['customType'], 'obligations_ledger');
      // Everything else is byte-identical.
      final beforeLines = before.split('\n');
      expect(fixedLines.length, beforeLines.length);
      for (var i = 0; i < beforeLines.length; i++) {
        if (beforeLines[i].contains(incidentRecordId)) continue;
        expect(fixedLines[i], beforeLines[i], reason: 'line ${i + 1}');
      }

      // Post-repair resume: no degraded records, no quarantine report for
      // the fixed record.
      reports.clear();
      final storage = await JsonlSessionStorage.open(fs, sessionPath);
      await storage.getPathToRoot(await storage.getLeafId());
      expect(reports, isEmpty);
      final branch = await storage.getPathToRoot(await storage.getLeafId());
      expect(
        [for (final r in branch) r.id],
        contains(incidentRecordId),
        reason: 'the fixed record rejoins the tree',
      );
    });

    test('a second repair pass rotates the previous .bak to .bak1', () async {
      final fs = await poisonedFile(deep: 3);
      await repairSessionLedgers(fs, sessionPath);
      expect((await fs.exists('$sessionPath.bak')).valueOrNull, isTrue);
      await repairSessionLedgers(fs, sessionPath);
      expect((await fs.exists('$sessionPath.bak1')).valueOrNull, isTrue);
    });

    test('a dry run reports the finding without touching anything', () async {
      final fs = await poisonedFile(deep: 3);
      final before = (await fs.readTextFile(sessionPath)).valueOrNull;
      final report = await repairSessionLedgers(fs, sessionPath, dryRun: true);
      expect(report.dryRun, isTrue);
      expect(report.malformedTotal, 1);
      expect(report.malformedRepaired, 0);
      expect(
        (await fs.readTextFile(sessionPath)).valueOrNull,
        before,
        reason: 'dry run writes nothing',
      );
    });

    test('repair stays conservative: unknown customs, custom_message and '
        'unparseable lines are kept verbatim (gh-1073 REG)', () async {
      final fs = MemoryFileSystem(cwd: '/');
      await fs.writeFile(
        sessionPath,
        [
          headerLine(),
          poisonLine(customType: 'some_unknown_ledger', parentId: 'm1'),
          jsonEncode({
            'type': 'custom',
            'id': 'cm1',
            'parentId': null,
            'timestamp': '2026-09-07T00:00:02.000Z',
            'customType': 'custom_message',
            'data': null,
          }),
          '{"type":"message","id":"torn', // torn line — kept verbatim
          messageLine('m2', parentId: incidentRecordId),
        ].join('\n'),
      );
      final report = await repairSessionLedgers(fs, sessionPath);
      expect(report.malformedTotal, 1);
      expect(report.recordsKept, greaterThanOrEqualTo(3));
      final after = (await fs.readTextFile(sessionPath)).valueOrNull!;
      expect(after, contains('{"type":"message","id":"torn'));
      expect(after, contains('some_unknown_ledger'));
      expect(after, contains('custom_message'));
    });

    test('E2 (multiple poison records): each found, each repaired', () async {
      final fs = MemoryFileSystem(cwd: '/');
      // Plain custom types (not in any repair set) — both snapshots
      // survive the pass, both get fixed.
      await fs.writeFile(
        sessionPath,
        [
          headerLine(),
          messageLine('m1'),
          poisonLine(id: 'poison-a', parentId: 'm1', customType: 'my_ledger'),
          poisonLine(
            id: 'poison-b',
            parentId: 'poison-a',
            customType: 'my_ledger',
          ),
          messageLine('m2', parentId: 'poison-b'),
        ].join('\n'),
      );
      final report = await repairSessionLedgers(fs, sessionPath);
      expect(report.malformedTotal, 2);
      expect(report.malformedRepaired, 2);
      final storage = await JsonlSessionStorage.open(fs, sessionPath);
      final branch = await storage.getPathToRoot('m2');
      // m1 → poison-a → poison-b → m2: the fixed records rejoin.
      expect([for (final r in branch) r.id], hasLength(4));
      expect(branch.where((r) => r.timestampDegraded), isEmpty);
    });

    test('E3 (gh-2178 review, BLOCKING): a multi-byte UTF-8 line in the '
        'same merged span does not corrupt the splice', () async {
      // The review's verified repro: non-ASCII payload BEFORE the poison
      // line inside one merged kept span. SessionScannedLine offsets are
      // BYTE offsets; each Cyrillic character is 2 UTF-8 bytes, so
      // splicing byte offsets into the decoded UTF-16 string shifted
      // every cut off position and concatenated two half-lines (the
      // repaired file carried a permanently torn record).
      const russianPayload =
          'привет мир — длинная русская строка для многобайтности';
      final fs = MemoryFileSystem(cwd: '/');
      final m1 = messageLine('m1', text: russianPayload);
      await fs.writeFile(
        sessionPath,
        [
          headerLine(),
          m1,
          // A PLAIN-KEPT custom type: the poison line merges with m1/m2
          // into one kept span (a keep-latest type like obligations_ledger
          // would sit in its own span and never exercise the splice).
          poisonLine(parentId: 'm1', customType: 'my_ledger'),
          messageLine('m2', parentId: incidentRecordId),
        ].join('\n'),
      );
      final report = await repairSessionLedgers(fs, sessionPath);
      expect(report.malformedTotal, 1);
      expect(report.malformedRepaired, 1);

      // Every repaired line still parses — the splice must never cut
      // mid-record or concatenate half-lines. (No trailing newline in
      // the fixture — split yields exactly 4 lines.)
      final after = (await fs.readTextFile(sessionPath)).valueOrNull!;
      final lines = after.split('\n');
      expect(lines, hasLength(4));
      final decoded = [
        for (final line in lines) jsonDecode(line) as Map<String, dynamic>,
      ];
      expect(
        [for (final m in decoded) m['id'] as String],
        [
          'poisoned', // header
          'm1',
          incidentRecordId,
          'm2',
        ],
      );
      // The multi-byte payload survives byte-verbatim.
      expect(decoded[1]['message']['content'], russianPayload);
      // Only the poison line changed (its timestamp), everything else is
      // byte-identical to the input.
      expect(decoded[0], jsonDecode(headerLine()));
      expect(decoded[1], jsonDecode(m1));
      expect(
        decoded[3],
        jsonDecode(messageLine('m2', parentId: incidentRecordId)),
      );

      // The fixed record rejoins the branch with a valid timestamp.
      final storage = await JsonlSessionStorage.open(fs, sessionPath);
      final branch = await storage.getPathToRoot('m2');
      expect([for (final r in branch) r.id], contains(incidentRecordId));
      expect(branch.where((r) => r.timestampDegraded), isEmpty);
    });
  });

  group('repair scan finder (quarantineFindingForLine)', () {
    test('finds a malformed timestamp with the exact line number', () {
      final finding = quarantineFindingForLine(
        poisonLine(),
        filePath: sessionPath,
        lineNumber: 36937,
      );
      expect(finding, isNotNull);
      expect(finding!.recordId, incidentRecordId);
      expect(finding.rawTimestamp, incidentTimestamp);
      expect(finding.filePath, sessionPath);
      expect(finding.lineNumber, 36937);
    });

    test('returns null for valid lines, torn lines and foreign JSON', () {
      expect(
        quarantineFindingForLine(
          messageLine('m1'),
          filePath: sessionPath,
          lineNumber: 2,
        ),
        isNull,
      );
      expect(
        quarantineFindingForLine(
          '{"type":"message","id":"torn',
          filePath: sessionPath,
          lineNumber: 3,
        ),
        isNull,
      );
      expect(
        quarantineFindingForLine(
          'not json at all',
          filePath: sessionPath,
          lineNumber: 4,
        ),
        isNull,
      );
    });

    test('the top-level gate ignores payload timestamps (exact top-level '
        'extraction)', () {
      final tricky = jsonEncode({
        'type': 'message',
        'id': 'm1',
        'parentId': null,
        'timestamp': '2026-09-07T00:00:01.000Z',
        'message': {
          'role': 'user',
          'content': 'payload quoting {"timestamp": "<garbage>"} in its text',
        },
      });
      expect(
        quarantineFindingForLine(tricky, filePath: sessionPath, lineNumber: 2),
        isNull,
      );
    });
  });

  group('topLevelTimestampValue (the cheap top-level gate)', () {
    test('extracts the timestamp of a REAL record-object line — top-level '
        'object keys sit at depth 1 (gh-2178 review digest: the gate '
        'never fired before, so every line paid the full decode and '
        'isolate findings carried an empty raw value)', () {
      expect(
        topLevelTimestampValue(messageLine('m1')),
        '2026-09-07T00:00:01.000Z',
      );
      expect(topLevelTimestampValue(poisonLine()), incidentTimestamp);
    });

    test('ignores payload-only timestamps (nested objects/strings)', () {
      final payloadOnly = jsonEncode({
        'type': 'message',
        'id': 'm1',
        'parentId': null,
        'message': {
          'role': 'user',
          'content': '{"timestamp": "<garbage>"} nested text',
        },
      });
      expect(topLevelTimestampValue(payloadOnly), isNull);
    });

    test('non-string and torn values return null (full decode confirms)', () {
      expect(
        topLevelTimestampValue(
          '{"type":"custom","id":"x","timestamp":42,"customType":"my_ledger"}',
        ),
        isNull,
      );
      expect(
        topLevelTimestampValue('{"type":"custom","id":"x","timestamp":"torn'),
        isNull,
      );
      expect(
        topLevelTimestampValue('{"type":"custom","id":"x","timestamp":'),
        isNull,
      );
    });

    test('whitespace after the colon and escaped quotes inside the value '
        'are handled', () {
      expect(
        topLevelTimestampValue(
          '{"type":"custom","id":"x","timestamp": '
          '"2026-11-13T14:35:18.198Z"}',
        ),
        '2026-11-13T14:35:18.198Z',
      );
      expect(
        topLevelTimestampValue(
          '{"type":"custom","id":"x","timestamp":"a \\"quoted\\" value"}',
        ),
        'a \\"quoted\\" value',
      );
      // An escape at EOF is a torn value, not a finding.
      expect(
        topLevelTimestampValue('{"type":"custom","id":"x","timestamp":"a\\'),
        isNull,
      );
      // A string torn BEFORE the timestamp key stops the whole scan —
      // nothing after an unterminated string can be a top-level key.
      expect(
        topLevelTimestampValue(
          '{"note":"torn,"timestamp":"2026-11-13T14:35:18.198Z"}',
        ),
        isNull,
      );
    });
  });

  group('second tier: session_repo listing index (site 5)', () {
    test('a poisoned createdAtIso index row degrades the served row instead '
        'of failing the whole listing', () async {
      final fs = MemoryFileSystem(cwd: '/');
      final root = '/sessions';
      final path = '$root/s1.jsonl';
      await fs.writeFile(
        path,
        [
          headerLine('2026-09-07T00:00:00.000Z', 's1'),
          messageLine('m1'),
        ].join('\n'),
      );
      final repo = JsonlSessionRepo(fs: fs, sessionsRoot: root);
      final cold = await repo.list();
      expect(cold, hasLength(1));

      // Poison the persisted sidecar row (same stat pair, so the warm
      // path serves it without re-reading the header).
      final sidecarPath = '$root/.listing-index.json';
      final sidecar =
          jsonDecode((await fs.readTextFile(sidecarPath)).valueOrNull!)
              as Map<String, dynamic>;
      (sidecar['entries'][0] as Map)['createdAt'] = incidentTimestamp;
      await fs.writeFile(sidecarPath, jsonEncode(sidecar));

      final warm = await repo.list();
      expect(warm, hasLength(1));
      expect(warm.single.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
    });
  });
}
