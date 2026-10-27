import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:quickjs_runtime/quickjs_runtime.dart';
import 'package:test/test.dart';

void main() {
  late QuickjsRuntime rt;

  setUp(() {
    rt = QuickjsRuntime();
  });

  tearDown(() {
    rt.close();
  });

  test('eval returns JSON result', () {
    expect(rt.eval('1 + 2'), '3');
    expect(rt.eval('"hello".toUpperCase()'), '"HELLO"');
  });

  test('eval undefined returns null', () {
    expect(rt.eval('undefined'), isNull);
  });

  _defineBytesTests(() => rt);

  test('eval error reports message', () {
    final errMsg = <String?>[];
    expect(rt.eval('throw new Error("boom")', errMsg: errMsg), isNull);
    expect(errMsg.first, contains('boom'));
  });

  test('setGlobal exposes a Dart value to JS', () {
    rt.setGlobal('answer', {'value': 42});
    expect(rt.eval('answer.value * 2'), '84');
  });

  test('registerHostFunction invokes Dart synchronously', () {
    rt.registerHostFunction('add', (argsJson) {
      final args = jsonDecode(argsJson) as List;
      return jsonEncode(args[0] + args[1]);
    });
    expect(rt.eval('add(2, 3)'), '5');
  });

  test('executePendingJobs drains promise reactions', () {
    rt.eval('globalThis.out = null; Promise.resolve(7).then((v) => out = v)');
    rt.executePendingJobs();
    expect(rt.eval('out'), '7');
  });

  _defineFfiTests();
}

void _defineBytesTests(QuickjsRuntime Function() getRt) {
  test('registerHostBytesFn delivers typed array bytes zero-copy', () {
    final rt = getRt();
    if (!rt.hasBytesFn) {
      expect(rt.registerHostBytesFn('x', (_, __) {}), isFalse);
      return;
    }
    final received = <String, Uint8List>{};
    expect(rt.registerHostBytesFn('__jsrSendBytes', (name, data) {
      received[name] = Uint8List.fromList(data);
    }), isTrue);
    rt.executePendingJobs();
    rt.eval('''
      var f = new Float32Array(11);
      for (var i = 0; i < f.length; i++) f[i] = i * 0.25;
      __jsrSendBytes('f32', f);
      var u8 = new Uint8Array(3); u8[0] = 9; u8[1] = 200; u8[2] = 45;
      __jsrSendBytes('u8tail', u8);
      var view = new Uint8Array(10); view[5] = 77; view[6] = 88;
      __jsrSendBytes('view', view.subarray(5, 7));
    ''');
    expect(received, hasLength(3));
    final f32 = Float32List.view(received['f32']!.buffer);
    expect(f32, hasLength(11));
    for (var i = 0; i < 11; i++) {
      expect(f32[i], i * 0.25);
    }
    expect(received['u8tail'], [9, 200, 45]);
    expect(received['view'], [77, 88]);
  });

  test('registerHostBytesFn rejects non-typed-array args', () {
    final rt = getRt();
    if (!rt.hasBytesFn) return;
    var calls = 0;
    rt.registerHostBytesFn('__jsrSendBytes', (_, __) => calls++);
    rt.eval('try { __jsrSendBytes("n", "not-an-array"); } catch (e) {}');
    expect(calls, 0);
  });
}

void _defineFfiTests() {
  test('QuickjsFfi.isAvailable and preferDynamicLibrary fallback work', () {
    expect(QuickjsFfi.isAvailable, isTrue);
    final savedPath = QuickjsFfi.libraryPath;
    try {
      QuickjsFfi.libraryPath = '/nonexistent/libquickjs_bridge.so';
      expect(QuickjsFfi.isAvailable, isTrue);
    } finally {
      QuickjsFfi.libraryPath = savedPath;
    }
    if (File(QuickjsFfi.libraryPath).existsSync()) {
      final dynFfi = QuickjsFfi(preferDynamicLibrary: true);
      final rawRt = dynFfi.createRuntime();
      final rawCtx = dynFfi.createContext(rawRt);
      expect(dynFfi.eval(rawCtx, '2 + 2', '<test>', null), '4');
      dynFfi.destroy(rawRt, rawCtx);
    }
  });
}
