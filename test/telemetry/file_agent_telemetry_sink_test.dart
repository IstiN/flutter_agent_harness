/// Issue #1322 Gap 3 — the io file sink: fa.log-format lines in the CLI's
/// own file so a host embed and a CLI session are post-mortem-identical.
library;

import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AgentTelemetryEvent _event(
  AgentTelemetryEventKind kind, {
  String? toolName,
  bool? isError,
  String? stopReason,
  int? httpStatus,
  String? detail,
  int? outputBytes,
  int? attempt,
  Duration sinceRunStart = const Duration(seconds: 7),
}) => AgentTelemetryEvent(
  kind: kind,
  timestamp: DateTime.utc(2026, 10, 6, 12, 30, 0),
  sinceRunStart: sinceRunStart,
  toolName: toolName,
  isError: isError,
  stopReason: stopReason,
  httpStatus: httpStatus,
  outputBytes: outputBytes,
  attempt: attempt,
  detail: detail,
);

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fa_telemetry_sink_test');
    path = '${dir.path}/logs/fa.log';
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('writes the CLI phase vocabulary, one sid-tagged line per record', () {
    const tag = 'yoclip-1a2b';
    FileAgentTelemetrySink(path, tag: tag)
      ..record(_event(AgentTelemetryEventKind.runStart))
      ..record(
        _event(
          AgentTelemetryEventKind.requestStart,
          detail: 'model=test-model provider=test-provider',
        ),
      )
      ..record(
        _event(
          AgentTelemetryEventKind.firstToken,
          detail: 'model=test-model provider=test-provider',
        ),
      )
      ..record(_event(AgentTelemetryEventKind.toolStart, toolName: 'bash'))
      ..record(
        _event(
          AgentTelemetryEventKind.toolEnd,
          toolName: 'bash',
          isError: false,
        ),
      )
      ..record(
        _event(
          AgentTelemetryEventKind.toolHeartbeat,
          toolName: 'bash',
          outputBytes: 834,
          attempt: 1,
          detail: 'elapsed=12s',
        ),
      )
      ..record(_event(AgentTelemetryEventKind.turnEnd, stopReason: 'stop'))
      ..record(
        _event(
          AgentTelemetryEventKind.error,
          httpStatus: 502,
          detail: '502: bad gateway',
        ),
      )
      ..record(_event(AgentTelemetryEventKind.runEnd));

    final lines = File(path).readAsLinesSync();
    expect(lines, hasLength(9));
    // The CLI's `<iso8601> <message>` shape, so the same greps work.
    for (final line in lines) {
      expect(line, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T')));
    }
    expect(lines[0], endsWith(' run start sid=yoclip-1a2b'));
    expect(
      lines[1],
      endsWith(
        ' request start sid=yoclip-1a2b '
        'model=test-model provider=test-provider',
      ),
    );
    expect(lines[3], endsWith(' tool start sid=yoclip-1a2b name=bash'));
    expect(
      lines[4],
      endsWith(' tool end sid=yoclip-1a2b name=bash error=false'),
    );
    // The CLI's heartbeat line shape: name=… elapsed=… out=<n>B attempt=<n>.
    expect(
      lines[5],
      endsWith(
        ' tool heartbeat sid=yoclip-1a2b name=bash elapsed=12s out=834B attempt=1',
      ),
    );
    expect(
      lines[6],
      contains(' turn end sid=yoclip-1a2b stop=stop elapsed=7s'),
    );
    expect(
      lines[7],
      allOf(
        contains(' run error sid=yoclip-1a2b elapsed=7s http=502 '),
        contains('502: bad gateway'),
      ),
    );
    expect(lines[8], contains(' run end sid=yoclip-1a2b elapsed=7s'));
  });

  test('a detail-less firstToken renders without a trailing segment', () {
    FileAgentTelemetrySink(
      path,
    ).record(_event(AgentTelemetryEventKind.firstToken));
    final line = File(path).readAsLinesSync().single;
    expect(line, endsWith(' first token sid=-'));
  });

  test('appends across runs (the CLI shares one fa.log)', () {
    FileAgentTelemetrySink(path)
      ..record(_event(AgentTelemetryEventKind.runStart))
      ..record(_event(AgentTelemetryEventKind.runStart));
    expect(File(path).readAsLinesSync(), hasLength(2));
    // Re-recording after a fresh sink instance (a second host process).
    FileAgentTelemetrySink(path).record(_event(AgentTelemetryEventKind.runEnd));
    expect(File(path).readAsLinesSync(), hasLength(3));
  });

  test('a broken path degrades to silence', () {
    // A path whose parent is a regular file cannot be created — the sink
    // must swallow the error like the CLI's own diagnostic writer.
    File('${dir.path}/blocker').writeAsStringSync('x');
    final sink = FileAgentTelemetrySink('${dir.path}/blocker/fa.log');
    sink.record(_event(AgentTelemetryEventKind.runStart));
    // Reaching here is the assertion: the sink swallowed the error.
  });

  test('forHomeDir resolves the canonical fa.log path', () {
    expect(
      FileAgentTelemetrySink.forHomeDir('/home/u')!.path,
      '/home/u/.fah/logs/fa.log',
    );
    expect(
      FileAgentTelemetrySink.forHomeDir('/home/u', tag: 'app')!.tag,
      'app',
    );
    expect(FileAgentTelemetrySink.forHomeDir(null), isNull);
    expect(FileAgentTelemetrySink.forHomeDir(''), isNull);
  });
}
