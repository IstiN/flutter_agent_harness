/// Issue #862 UT suite: the pure tool-misuse coercion policies
/// (`lib/src/tools/misuse_policy.dart`), one positive AND negative test per
/// policy per the GOAL card, plus the luna fixture shapes.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('resolveEditMode (UT-1..3)', () {
    test('UT-1/AC1: a valid patch wins over a complete exact-match triple '
        'and the notice names the ignored payload', () {
      final plan = resolveEditMode(
        path: 'app.js',
        oldText: 'const grid = "old"',
        newText: 'const grid = "new"',
        patch: '[app.js#a1b2]\nSWAP 1.=1:\n+const grid = "patched"',
      );
      expect(plan, isA<EditRunPatch>());
      final notice = plan.notice;
      expect(notice, isNotNull);
      expect(notice, contains('oldText'));
      expect(notice, contains('newText'));
      expect(notice, contains('IGNORED'));
    });

    test('UT-1 negative: a lone patch coerces nothing (no notice)', () {
      final plan = resolveEditMode(
        path: null,
        oldText: null,
        newText: null,
        patch: '[app.js#a1b2]\nSWAP 1.=1:\n+only',
      );
      expect(plan, isA<EditRunPatch>());
      expect(plan.notice, isNull);
    });

    test('UT-2/AC2: a malformed patch with a complete exact-match triple '
        'falls back to exact-match with the same notice shape', () {
      final plan = resolveEditMode(
        path: 'app.js',
        oldText: 'const grid = "old"',
        newText: 'const grid = "new"',
        patch: 'this is not a patch at all',
      );
      expect(plan, isA<EditRunExactMatch>());
      final notice = plan.notice!;
      expect(notice, contains('patch'));
      expect(notice, contains('IGNORED'));
      // Same notice shape as AC1: names the ignored mode + why.
      expect(notice, contains('exactly one mode'));
    });

    test('UT-2 negative: an empty (null) patch is not a coercion', () {
      final plan = resolveEditMode(
        path: 'app.js',
        oldText: 'a',
        newText: 'b',
        patch: null,
      );
      expect(plan, isA<EditRunExactMatch>());
      expect(plan.notice, isNull);
    });

    test('UT-3/AC3: neither mode complete rejects with a remedy example', () {
      for (final args in [
        (path: null, oldText: null, newText: null, patch: null),
        (path: 'app.js', oldText: null, newText: null, patch: null),
        (path: 'app.js', oldText: 'a', newText: null, patch: null),
        (path: 'app.js', oldText: '', newText: 'b', patch: null),
        // A malformed patch cannot rescue an incomplete exact-match triple.
        (path: null, oldText: null, newText: null, patch: 'garbage'),
      ]) {
        final plan = resolveEditMode(
          path: args.path,
          oldText: args.oldText,
          newText: args.newText,
          patch: args.patch,
        );
        expect(plan, isA<EditReject>(), reason: '$args');
        final message = (plan as EditReject).message;
        expect(message, contains('Example:'), reason: '$args');
        expect(message, contains('oldText'), reason: '$args');
        expect(message, contains('patch'), reason: '$args');
      }
    });

    test('E1: both modes complete and contradictory — patch wins '
        'deterministically, notice names the conflict', () {
      final plan = resolveEditMode(
        path: 'app.js',
        oldText: 'totally different target',
        newText: 'also different',
        patch: '[app.js#a1b2]\nSWAP 1.=1:\n+patched',
      );
      expect(plan, isA<EditRunPatch>());
      expect(plan.notice, isNotNull);
    });

    test('luna fixture: the exact 15x-rejected call shape now coerces '
        '(patch present, oldText/newText non-empty)', () {
      final plan = resolveEditMode(
        path: 'index.html',
        oldText: '<div id="grid"></div>',
        newText: '<div id="grid" class="new"></div>',
        patch: '[index.html#9f8e]\nSWAP 21.=21:\n+<div id="grid"></div>',
      );
      expect(plan, isA<EditRunPatch>());
    });
  });

  group('readWindowCoercionNotice (UT-4/AC4)', () {
    test('selector + offset/limit produces the ignore notice', () {
      final notice = readWindowCoercionNotice(
        hasSelector: true,
        offset: null,
        limit: 50,
      );
      expect(notice, isNotNull);
      expect(notice, contains('limit'));
      expect(notice, contains('IGNORED'));
      expect(notice, contains('selector'));
    });

    test('negative: selector alone coerces nothing', () {
      expect(
        readWindowCoercionNotice(hasSelector: true, offset: null, limit: null),
        isNull,
      );
    });

    test('negative: offset/limit without a selector coerces nothing', () {
      expect(
        readWindowCoercionNotice(hasSelector: false, offset: 15, limit: 7),
        isNull,
      );
    });

    test('luna fixture: selector + limit names both ignored params', () {
      final notice = readWindowCoercionNotice(
        hasSelector: true,
        offset: 15,
        limit: 50,
      );
      expect(notice, contains('offset'));
      expect(notice, contains('limit'));
    });
  });

  group('parsePatch (one shared parse, fallbackPath honored)', () {
    test('accepts a real hashline patch, rejects garbage and empty', () {
      expect(
        parsePatch('[a.txt#a1b2]\nSWAP 1.=1:\n+x').usable,
        isTrue,
      );
      expect(parsePatch('garbage').usable, isFalse);
      expect(parsePatch('').usable, isFalse);
      expect(parsePatch(null).usable, isFalse);
      expect(parsePatch('   \n  ').usable, isFalse);
    });

    test('a header-less patch with recognizable ops is usable under the '
        'executor fallbackPath contract — the BLOCKING regression pin '
        '(issue #862 review)', () {
      final parse = parsePatch('DEL 1', fallbackPath: 'f.txt');
      expect(parse.usable, isTrue,
          reason: 'HashlinePatch.parse(patch, fallbackPath: path) accepts '
              'this at apply time; the gate must agree');
      expect(parse.patch!.sections.single.path, 'f.txt');
      // Without a fallback path the same input is unusable (no header, and
      // the gate has no section path to offer).
      expect(parsePatch('DEL 1').usable, isFalse);
    });

    test('a failure carries the parser diagnostic for the remedy reject',
        () {
      final parse = parsePatch('DEL 1');
      expect(parse.usable, isFalse);
      expect(parse.error, contains('[PATH#HASH]'));
    });
  });
}
