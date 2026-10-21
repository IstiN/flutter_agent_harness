import 'dart:io';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';

Future<void> main() async {
  final protectedDummy = await Process.start('sh', ['-c', 'sleep 1763']);
  final freeDummy = await Process.start('sh', ['-c', 'sleep 1763']);
  final ps = await Process.run('ps', ['-ax', '-o', 'pid=,command=']);
  for (final line in (ps.stdout as String).split('\n')) {
    if (line.contains('sleep 1763')) print('PS: $line');
  }
  print('protectedDummy.pid=${protectedDummy.pid} freeDummy.pid=${freeDummy.pid}');
  final result = await const LocalShell().exec(
    'pkill -f "sleep 1763"; '
    'if ps -o pid= -p ${protectedDummy.pid} >/dev/null 2>&1; then '
    'echo "protected_alive"; else echo "protected_dead"; fi; '
    'if ps -o pid= -p ${freeDummy.pid} >/dev/null 2>&1; then '
    'echo "free_alive"; else echo "free_reaped"; fi',
    options: ShellExecOptions(
      env: {'FA_PROTECTED_PIDS': '${protectedDummy.pid}'},
    ),
  );
  print('exit=${result.getOrThrow().exitCode}');
  print('stdout=${result.getOrThrow().stdout}');
  print('stderr=${result.getOrThrow().stderr}');
  protectedDummy.kill();
  freeDummy.kill();
}
