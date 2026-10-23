import 'dart:convert';
import 'dart:io';

import 'package:quickjs_runtime/quickjs_runtime.dart';
import 'package:test/test.dart';

/// Cross-runtime conformance: the shared fixture script
/// (`test/fixtures/cross_runtime_conformance.js`, byte-identical with the
/// epam/dm.ai Java test resource and the epam/dmtools-dart fixture) must
/// produce the identical result on QuickJS here as it does on GraalJS in
/// the Java bridge.
///
/// Worker engines install the same compat surface as the main engine —
/// the Java bridge and the dmtools worker wiring do the same inside
/// `runAsync` workers, so the dispatched function sees `require('path')`
/// and `TextEncoder` exactly like the main script does.

/// Evaluates [code] and decodes the JSON result (raw string when not
/// JSON).
/// The canned transport every runtime's harness installs for the
/// fixture's `conformance://ping` fetch call (JSON string return, same
/// contract as the production httpFetch hook).
const String cannedFetchResponse =
    '{"status":200,"headers":{"x":"y"},"body":"pong"}';

String? cannedFetch(String requestJson) {
  final url = jsonDecode(requestJson)['url'] as String?;
  if (url == 'conformance://ping') return cannedFetchResponse;
  return jsonEncode({
    'status': 404,
    'headers': <String, String>{},
    'body': 'no conformance route',
  });
}

Object? evalJson(QuickjsRuntime rt, String code) {
  final errors = <String?>[];
  final raw = rt.eval(code, errMsg: errors);
  if (errors.isNotEmpty) throw StateError(errors.first!);
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return raw;
  }
}

/// Per-job engine with the compat layer installed (mirrors the dmtools
/// worker wiring and the Java worker-bridge wiring, which both build a
/// fresh engine per dispatched job).
///
/// A runtime created at worker START and then used while the MAIN
/// isolate sits inside its own `rt.eval` intermittently evaluates even
/// `1+1` to `undefined` (silent, no errMsg) — QuickJS-level race between
/// the two isolates' C frames. Creating the engine per job, while the
/// main isolate is parked in the native `wait()`, is clean (0/30) and
/// matches the production adapter's fresh-engine-per-job contract.
Future<void> compatWorkerMain(AsyncWorkerLink link) async {
  try {
    while (true) {
      final request = await link.next();
      if (request == null) return;
      final runtime = QuickjsRuntime();
      try {
        installNodeCompat(
          runtime,
          NodeCompatConfig(
            utf8Encode: utf8.encode,
            utf8Decode: utf8.decode,
            httpFetch: cannedFetch,
          ),
        );
        link.complete(
          AsyncJobEnvelope.fromJson(
            runAsyncJobOnRuntime(
              runtime,
              jobId: request.jobId,
              fnSource: request.fnSource,
              argsJson: request.argsJson,
            ),
          ),
        );
      } finally {
        runtime.close();
      }
    }
  } catch (_) {
    // Never let the worker die silently: `link.next()` throwing ends the
    // loop and pending jobs would hang. The per-job envelope already
    // captures eval failures; worker-level failures surface as a dead
    // worker (pool completes pending jobs with an error envelope).
  }
}

/// The contract every runtime must satisfy. Kept in lockstep with the
/// expected JSON in the dm.ai and dmtools-dart conformance tests.
const Map<String, dynamic> expected = {
  'globalAlias': true,
  'processType': 'object',
  'envIsObject': true,
  'cwdIsString': true,
  'joined': 'a/b/c.txt',
  'baseName': 'z.md',
  'assertOk': true,
  'formatted': 'answer=42',
  'utf8ByteLen': 10,
  'utf8RoundTrip': true,
  'base64': true,
  'clockIsNumber': true,
  'uuidShape': true,
  'randomFilled': true,
  'cloneDeep': true,
  'buffer': {
    'typeofFn': true,
    'isUint8Array': true,
    'b64': 'aGVsbG8=',
    'hexRoundTrip': true,
    'latin1Hex': '68ff',
    'utf8ByteLen': 12,
    'le': 1,
    'be': 9,
    'slice': 'bc',
    'copyRoundTrip': true,
    'isBufferTrue': true,
    'isBufferFalse':
        true, // fixture value: `B.isBuffer(new Uint8Array(4)) === false`
  },
  'url': {
    'href': 'https://example.com/a/b?q=1&x=%20#frag',
    'origin': 'https://example.com',
    'pathname': '/a/b',
    'search': '?q=1&x=%20',
    'hash': '#frag',
    'q': '1',
    'xDecoded': ' ',
    'getAllA': '1|2',
    'bDecoded': 'x y',
    'appendForm': 'k=a+b',
    'canParse': true,
  },
  'utilExtras': {
    'inspectString': "'hi'",
    'inspectNumber': '42',
    'isArray': true,
    'isString': true,
    'hasTime': true,
  },
  'osProcess': {
    'osEolType': 'string',
    'osPlatformType': 'string',
    'osArchType': 'string',
    'osHomedirType': 'string',
    'nextTickType': 'function',
    'hrtimeType': 'function',
    'argvIsArray': true,
    'pidIsNumber': true,
    'exitIsFunction': true,
  },
  'intl': {
    'numberFormat': true,
    'dateTimeFormat': true,
    'canonicalLocales': true,
  },
  'events': {
    'got': 't1,o',
    'emitReturnNoListener': true,
    'hasOff': true,
    'listenerCount': 1,
  },
  'fetchShapes': {
    'fetchTypeof': 'function',
    'headerGet': 'b',
    'headerHas': true,
    'responseType': 'function',
    'callStatus': 200,
    'callHeader': 'y',
    'callBody': true,
  },
  'stubGuards': true,
  'parallel': {
    'sum': 5050,
    'workerBase': 'parallel.js',
    'workerUtf8': 4,
    'workerBuffer': 'b2s=',
    'allValues': ['first', 'second'],
  },
};

/// The timers protocol result (step 3-5 of the header): one ready drain
/// pass runs immediates before due timeouts; the microtask fired at the
/// end of the actionTimers eval.
const Map<String, dynamic> expectedTimers = {
  'log': ['sync', 'p1', 'imm', 't0', 'iv'],
};

void main() {
  test('conformance script produces the identical cross-runtime result',
      () async {
    final rt = QuickjsRuntime();
    final pool = AsyncEnginePool(workers: 2, workerMain: compatWorkerMain);
    try {
      installNodeCompat(
        rt,
        NodeCompatConfig(
          utf8Encode: utf8.encode,
          utf8Decode: utf8.decode,
          httpFetch: cannedFetch,
        ),
      );
      await pool.boot();
      pool.attachMainRuntime(rt);
      rt.setGlobal('params', {
        'jobParams': {'nodeCompat': true, 'parallelWorkers': 2},
      });
      final errors = <String?>[];
      rt.eval(
        File('test/fixtures/cross_runtime_conformance.js').readAsStringSync(),
        filename: 'cross_runtime_conformance.js',
        errMsg: errors,
      );
      if (errors.isNotEmpty) throw StateError(errors.first!);
      expect(evalJson(rt, 'action(params)'), equals(expected));
    } finally {
      pool.dispose();
      rt.close();
    }
  });

  test('timers protocol: microtask at eval end, one drain pass ordering', () {
    final rt = QuickjsRuntime();
    final handle = installNodeCompat(
      rt,
      NodeCompatConfig(
        utf8Encode: utf8.encode,
        utf8Decode: utf8.decode,
        httpFetch: cannedFetch,
      ),
    );
    try {
      final errors = <String?>[];
      rt.eval(
        File('test/fixtures/cross_runtime_conformance.js').readAsStringSync(),
        filename: 'cross_runtime_conformance.js',
        errMsg: errors,
      );
      if (errors.isNotEmpty) throw StateError(errors.first!);
      expect(
        evalJson(rt, 'actionTimers({})'),
        'registered',
      );
      final stats = handle.drainTimers();
      expect(stats.ran, 3); // imm + t0 + iv
      expect(evalJson(rt, 'globalThis.__timersOut'), equals(expectedTimers));
    } finally {
      rt.close();
    }
  });
}
