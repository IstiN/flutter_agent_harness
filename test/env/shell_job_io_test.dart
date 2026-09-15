import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late LocalExecutionEnv env;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('shell-job-test-');
    env = LocalExecutionEnv(cwd: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('BackgroundShell (local)', () {
    test('a job runs detached, writes its log, and settles', () async {
      final started = await env.startShellJob(
        'echo hello && echo err >&2',
        id: 'sh-1',
        logPath: '${tempDir.path}/sh-1.log',
      );
      expect(started.isOk, isTrue);
      final job = started.valueOrNull!;
      expect(job.isRunning, isTrue);
      await job.settled;
      expect(job.exitCode, 0);
      expect(job.stopReason, isNull);
      final log = File(job.logPath).readAsStringSync();
      expect(log, contains('hello'));
      expect(log, contains('err'));
    });

    test('stop terminates a long-running job', () async {
      final started = await env.startShellJob(
        'sleep 60',
        id: 'sh-2',
        logPath: '${tempDir.path}/sh-2.log',
      );
      final job = started.valueOrNull!;
      expect(job.isRunning, isTrue);
      await job.stop();
      await job.settled;
      expect(job.isRunning, isFalse);
      expect(job.exitCode, isNot(0));
      expect(job.stopReason, 'stopped');
    });

    test('the timeout kills the job and records the reason', () async {
      final started = await env.startShellJob(
        'sleep 60',
        id: 'sh-3',
        logPath: '${tempDir.path}/sh-3.log',
        options: const ShellExecOptions(timeout: Duration(milliseconds: 300)),
      );
      final job = started.valueOrNull!;
      await job.settled;
      expect(job.isRunning, isFalse);
      expect(job.stopReason, 'timeout');
    });

    test('the cancel token kills the job and records the reason', () async {
      final source = CancelTokenSource();
      final started = await env.startShellJob(
        'sleep 60',
        id: 'sh-4',
        logPath: '${tempDir.path}/sh-4.log',
        options: ShellExecOptions(cancelToken: source.token),
      );
      final job = started.valueOrNull!;
      source.cancel();
      await job.settled;
      expect(job.stopReason, 'cancelled');
    });

    test('live stdin: the pipe stays open until the process ends and a '
        'write reaches it (issue #367)', () async {
      final channel = LiveStdinChannel();
      final started = await env.startShellJob(
        'read line; echo "got:\$line"',
        id: 'sh-5',
        logPath: '${tempDir.path}/sh-5.log',
        options: ShellExecOptions(liveStdin: channel),
      );
      final job = started.valueOrNull!;
      expect(channel.isBound, isTrue);
      // The pipe is still open: the stdin-reader has not seen EOF and
      // keeps waiting for the answer.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(job.isRunning, isTrue);
      expect(channel.write('s3cret\n'), isTrue);
      await job.settled;
      expect(job.exitCode, 0);
      final log = File(job.logPath).readAsStringSync();
      expect(log, contains('got:s3cret'));
      // The process is gone: a late write fails cleanly, never throws.
      expect(channel.write('late\n'), isFalse);
    });

    test('without a live channel stdin closes at start (ripgrep safety)',
        () async {
      final started = await env.startShellJob(
        'read line; echo "got:\$line"',
        id: 'sh-6',
        logPath: '${tempDir.path}/sh-6.log',
      );
      final job = started.valueOrNull!;
      await job.settled;
      expect(job.exitCode, 0);
    });
  });
}
