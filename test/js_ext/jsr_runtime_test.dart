/// Tests for [JsrRuntime]'s deterministic fake: start records its arguments,
/// invoke dispatches to registered globals and counts calls, dispose gates
/// further use, and the timeout-behavior knob simulates engine overrun.
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('FakeJsrRuntime', () {
    test(
      'start records bootstrap, main, and bridges without running them',
      () async {
        final rt = FakeJsrRuntime('fake');
        expect(rt.lastBootstrapJs, isNull);
        expect(rt.lastMainJs, isNull);
        expect(rt.bridges, isNull);
        await rt.start(
          bootstrapJs: '//boot',
          mainJs: '//main',
          bridges: (m, a) async => null,
        );
        expect(rt.lastBootstrapJs, '//boot');
        expect(rt.lastMainJs, '//main');
        expect(rt.bridges, isNotNull);
        expect(rt.invokeCount, 0);
        expect(rt.disposed, isFalse);
      },
    );

    test('engineId echoes the constructor value', () {
      expect(FakeJsrRuntime('qjs-process').engineId, 'qjs-process');
      expect(FakeJsrRuntime('fake').engineId, 'fake');
    });

    test('invoke dispatches to constructor globals and counts calls', () async {
      final rt = FakeJsrRuntime(
        'fake',
        globals: {
          '__extInvoke': (args) async => {'handle': args[0]},
        },
      );
      final result = await rt.invoke('__extInvoke', [
        7,
        {'a': 1},
      ]);
      expect(result, {'handle': 7});
      expect(rt.invokeCount, 1);
      await rt.invoke('__extInvoke', ['x']);
      expect(rt.invokeCount, 2);
    });

    test('onGlobal registers and replaces globals', () async {
      final rt = FakeJsrRuntime('fake');
      expect(() => rt.invoke('__extPing', []), throwsStateError);
      rt.onGlobal('__extPing', (args) async => 'fake');
      expect(await rt.invoke('__extPing', []), 'fake');
      rt.onGlobal('__extPing', (args) async => 'replaced');
      expect(await rt.invoke('__extPing', []), 'replaced');
      expect(rt.invokeCount, 3);
    });

    test(
      'defaultTimeoutBehavior timeout throws TimeoutException with the caller timeout',
      () async {
        final rt = FakeJsrRuntime(
          'fake',
          globals: {'fn': (args) async => 'never'},
          defaultTimeoutBehavior: 'timeout',
        );
        await expectLater(
          () => rt.invoke('fn', [], timeout: const Duration(seconds: 3)),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.duration,
              'duration',
              const Duration(seconds: 3),
            ),
          ),
        );
        expect(rt.invokeCount, 1);
        // Any other value keeps the knob inert.
        final calm = FakeJsrRuntime(
          'fake',
          globals: {'fn': (args) async => 1},
          defaultTimeoutBehavior: 'other',
        );
        expect(await calm.invoke('fn', []), 1);
      },
    );

    test('bridges set at start dispatch', () async {
      final rt = FakeJsrRuntime('fake');
      await rt.start(
        bootstrapJs: '//',
        mainJs: '//',
        bridges: (method, args) async => 'bridged:$method:${args['x']}',
      );
      expect(
        await rt.bridges!('fs.readFile', {'x': 1}),
        'bridged:fs.readFile:1',
      );
    });

    test('dispose sets the flag and gates start and invoke', () async {
      final rt = FakeJsrRuntime('fake', globals: {'fn': (args) async => 1});
      expect(await rt.invoke('fn', []), 1);
      await rt.dispose();
      expect(rt.disposed, isTrue);
      await expectLater(rt.invoke('fn', []), throwsStateError);
      await expectLater(
        rt.start(bootstrapJs: '', mainJs: '', bridges: (m, a) async => null),
        throwsStateError,
      );
      expect(rt.invokeCount, 1); // gated invoke after dispose does not count
      await rt.dispose(); // idempotent
      expect(rt.disposed, isTrue);
    });
  });
}
