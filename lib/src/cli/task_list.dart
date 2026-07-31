import '../task/task.dart';

/// The `/tasks` listing rows: status marker, id, agent, status name,
/// elapsed time, task preview, and the agent:// ref.
List<String> taskJobLines(
  List<TaskJob> jobs, {
  required String Function(String) dim,
}) {
  return [
    'background agents:',
    for (final job in jobs) taskJobLine(job, dim: dim),
  ];
}

/// One task-list row: status marker, id, agent, elapsed time, task
/// preview, and the agent:// ref.
String taskJobLine(TaskJob job, {required String Function(String) dim}) {
  final marker = switch (job.status) {
    TaskJobStatus.queued => '○',
    TaskJobStatus.running => '⠿',
    TaskJobStatus.completed => '✓',
    TaskJobStatus.failed || TaskJobStatus.aborted => '✗',
  };
  final duration = job.result?.duration;
  final elapsed = duration == null
      ? ''
      : ' ${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
  var task = job.task.replaceAll('\n', ' ');
  if (task.length > 60) task = '${task.substring(0, 60)}…';
  return '  $marker ${job.id} (${job.agent}) ${job.status.name}$elapsed — '
      '$task  ${dim('agent://${job.id}')}';
}
