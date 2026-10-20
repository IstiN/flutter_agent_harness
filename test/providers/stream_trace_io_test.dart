// StreamTrace io half: the file sink and the env-gated installer —
// same "diagnostics must never break the host" contract as the fa.log
// telemetry sink (truncates at install, per-line flush, silent on any
// IO failure).
import 'dart:io';

import 'package:flutter_agent_harness/src/providers/stream_trace.dart';
import 'package:flutter_agent_harness/src/providers/stream_trace_io.dart';
import 'package:test/test.dart';

void main() {
  group('FileStreamTraceSink', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('stream-trace-test');
      file = File('${dir.path}/trace.log');
    });

    tearDown(() {
      StreamTrace.stop();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('writes one prefixed line per mark, truncating previous content', () {
      file.writeAsStringSync('stale\n');
      final sink = FileStreamTraceSink(file);
      StreamTrace.start(sink);

      StreamTrace.mark(StreamTraceMark.net, '+8B');
      StreamTrace.mark(StreamTraceMark.emit, 'text +2');

      final lines = file.readAsLinesSync();
      expect(lines, hasLength(2));
      // Wall-clock iso prefix + the pure body, one line each.
      expect(lines[0], contains(RegExp(r'^\d{4}-\d{2}-\d{2}T')));
      expect(lines[0], contains('net'));
      expect(lines[1], contains('emit'));
      expect(file.readAsStringSync(), isNot(contains('stale')));
    });

    test('a write failure degrades to silence, never throws', () {
      final sink = FileStreamTraceSink(file);
      StreamTrace.start(sink);
      dir.deleteSync(recursive: true);
      expect(
        () => StreamTrace.mark(StreamTraceMark.net, '+1B'),
        returnsNormally,
      );
    });
  });

  group('maybeStartStreamTrace', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('stream-trace-env-test');
    });

    tearDown(() {
      StreamTrace.stop();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('starts a trace only when the env value is 1', () {
      final file = File('${dir.path}/on.log');
      final trace = maybeStartStreamTrace(
        file,
        envLookup: (key) => key == 'FA_STREAM_TRACE' ? '1' : null,
      );
      expect(trace, isNotNull);
      expect(StreamTrace.active, same(trace));
      StreamTrace.mark(StreamTraceMark.net, '+1B');
      expect(file.readAsStringSync(), contains('net'));
    });

    test('any other value (or unset) keeps the trace off', () {
      for (final value in <String?>[null, '', '0', 'true', '2']) {
        final trace = maybeStartStreamTrace(
          File('${dir.path}/off-$value.log'),
          envLookup: (key) => key == 'FA_STREAM_TRACE' ? value : null,
        );
        expect(trace, isNull, reason: 'FA_STREAM_TRACE=$value');
        expect(StreamTrace.active, isNull);
      }
    });
  });
}
