/// Unit tests for the pure `qjs` stdio protocol layer
/// (`ext_engine_protocol.dart`, no `dart:io`): line routing, pending-invoke
/// bookkeeping, timeout kill wiring, bridge reply shaping, probe parsing,
/// and script composition.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/cli/ext_engine_protocol.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_protocol.dart';
import 'package:test/test.dart';

/// Records notes and bridge requests instead of touching a process.
final class _RecordingSink implements ExtLineSink {
  final notes = <String>[];
  final bridges = <(int, String, Object?)>[];

  @override
  void note(String line) => notes.add(line);

  @override
  void answerBridge(int seq, String method, Object? args) =>
      bridges.add((seq, method, args));
}

void main() {
  group('composeExtScript', () {
    test('wraps main in a fatal reporter and try/catch', () {
      final script = composeExtScript('<BOOT>', '<MAIN>');
      expect(script, contains('__extFatal'));
      expect(script, startsWith('globalThis.__extFatal'));
      expect(script, contains('<BOOT>'));
      expect(script, contains('try{\n<MAIN>'));
      expect(script, contains('__extFatal(String(e && e.message || e))'));
    });
  });

  group('extReplyValue', () {
    test('returns value on ok', () {
      expect(extReplyValue({'ok': true, 'value': 7}), 7);
    });

    test('null value on ok is preserved', () {
      expect(extReplyValue({'ok': true, 'value': null}), isNull);
    });

    test('throws ExtProtocolException with the engine error', () {
      expect(
        () => extReplyValue({'ok': false, 'error': 'boom'}),
        throwsA(
          isA<ExtProtocolException>().having(
            (e) => e.message,
            'message',
            'boom',
          ),
        ),
      );
    });

    test('missing error falls back to a generic message', () {
      expect(
        () => extReplyValue({'ok': false}),
        throwsA(isA<ExtProtocolException>()),
      );
    });
  });

  group('bridge reply shaping', () {
    test('extBridgeArgs maps objects and empties the rest', () {
      expect(extBridgeArgs({'a': 1}), {'a': 1});
      expect(extBridgeArgs(null), isEmpty);
      expect(extBridgeArgs(42), isEmpty);
      expect(extBridgeArgs('x'), isEmpty);
    });

    test('ok and error payloads match the wire contract', () {
      expect(extBridgeOk(3, 'v'), {'seq': 3, 'ok': true, 'value': 'v'});
      expect(extBridgeError(4, 'bad'), {'seq': 4, 'ok': false, 'error': 'bad'});
    });
  });

  group('probe parsing', () {
    test('working binary has no problem', () {
      expect(extProbeProblem('qjs', 0, '1\n', ''), isNull);
    });

    test('failure exit or wrong output is a problem', () {
      expect(
        extProbeProblem('qjs', 1, '', 'cannot open file'),
        contains('exit 1'),
      );
      expect(extProbeProblem('qjs', 0, '2\n', ''), contains('exit 0'));
    });

    test('version line only from a clean -v run', () {
      expect(extProbeVersion(0, 'quickjs-ng 1.0\n'), 'quickjs-ng 1.0');
      expect(extProbeVersion(1, 'quickjs-ng 1.0'), isNull);
      expect(extProbeVersion(0, '   \n'), isNull);
    });
  });

  group('ExtEngineRouter', () {
    late ExtEngineRouter router;
    late _RecordingSink sink;

    setUp(() {
      router = ExtEngineRouter();
      sink = _RecordingSink();
    });

    ExtLineAction feed(String line) {
      final action = router.onLine(line);
      action.runWith(sink);
      return action;
    }

    test('blank lines are handled with no note', () {
      expect(feed('   '), isA<ExtHandled>());
      expect(sink.notes, isEmpty);
    });

    test('undecodable and non-object lines become notes', () {
      feed('{not json');
      feed('[1,2]');
      expect(sink.notes, hasLength(2));
      expect(sink.notes.first, contains('undecodable'));
      expect(sink.notes.last, contains('non-object'));
    });

    test('unrecognized objects become notes', () {
      feed('{"nope": 1}');
      expect(sink.notes.single, contains('unrecognized'));
    });

    test('invoke reply completes the pending waiter', () async {
      final id = router.beginInvoke('t', const []);
      final future = router.response(id, 't', null, null);
      feed(jsonEncode({'invoke': id, 'ok': true, 'value': 'done'}));
      expect(await future, 'done');
      expect(sink.notes, isEmpty);
    });

    test(
      'invoke error reply fails the waiter with ExtProtocolException',
      () async {
        final id = router.beginInvoke('t', const []);
        final future = router.response(id, 't', null, null);
        feed(jsonEncode({'invoke': id, 'ok': false, 'error': 'js error'}));
        await expectLater(future, throwsA(isA<ExtProtocolException>()));
      },
    );

    test('bridge request reaches the sink with its args', () {
      feed(
        jsonEncode({
          'seq': 5,
          'method': 'io.write',
          'args': {'t': 'x'},
        }),
      );
      final (seq, method, args) = sink.bridges.single;
      expect(seq, 5);
      expect(method, 'io.write');
      expect(args, {'t': 'x'});
    });

    test('bridge request without args hands over null', () {
      feed(jsonEncode({'seq': 6, 'method': 'has'}));
      expect(sink.bridges.single.$3, isNull);
    });

    test('non-int seq or non-string method is unrecognized', () {
      feed(jsonEncode({'seq': 'x', 'method': 'io.write'}));
      feed(jsonEncode({'seq': 1, 'method': 9}));
      expect(sink.notes, hasLength(2));
      expect(sink.bridges, isEmpty);
    });

    test(
      'fatal line fails every pending invoke and later ones stay open',
      () async {
        final first = router.beginInvoke('a', const []);
        final second = router.beginInvoke('b', const []);
        final f1 = router.response(first, 'a', null, null);
        final f2 = router.response(second, 'b', null, null);
        feed(jsonEncode({'fatal': 'syntax error in main.js'}));
        await expectLater(f1, throwsA(isA<ExtProtocolException>()));
        await expectLater(f2, throwsA(isA<ExtProtocolException>()));
        // The router survives: a fresh invoke can still be registered.
        final third = router.beginInvoke('c', const []);
        expect(router.invokePayload(third, 'c', const []), {
          'invoke': third,
          'fn': 'c',
          'args': <Object?>[],
        });
      },
    );

    test('timeout drops the waiter, runs the kill hook, and throws', () async {
      final id = router.beginInvoke('spin', const []);
      final future = router.response(
        id,
        'spin',
        const Duration(milliseconds: 10),
        () async => sink.note('killed'),
      );
      await expectLater(future, throwsA(isA<TimeoutException>()));
      expect(sink.notes, ['killed']);
      // A late reply for the dropped id must not throw zones errors.
      feed(jsonEncode({'invoke': id, 'ok': true, 'value': 'late'}));
    });

    test('failAll fails waiters without killing the router', () async {
      final id = router.beginInvoke('a', const []);
      final future = router.response(id, 'a', null, null);
      router.failAll(StateError('engine exited: code 1'));
      await expectLater(future, throwsA(isA<StateError>()));
    });

    test('note buffer keeps only the last 200 lines', () {
      for (var i = 0; i < 250; i++) {
        router.note('n$i');
      }
      final joined = router.lastNotes.split('\n');
      expect(joined, hasLength(200));
      expect(joined.first, 'n50');
      expect(joined.last, 'n249');
    });

    test('invoke ids increase monotonically', () {
      expect(
        router.invokePayload(router.beginInvoke('a', const []), 'a', const []),
        containsPair('invoke', 1),
      );
      expect(
        router.invokePayload(router.beginInvoke('b', const []), 'b', const []),
        containsPair('invoke', 2),
      );
    });
  });
}
