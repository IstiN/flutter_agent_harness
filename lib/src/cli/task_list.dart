import '../task/task.dart';

/// The `/tasks` listing rows: status marker, id, agent, status name,
/// elapsed time, task preview, and the agent:// ref.
///
/// Issue #222 AC5: [supersedesOf] (job id → the id it supersedes, from the
/// retained-subagent registry) folds a respawn chain into ONE logical
/// entry — superseded generations disappear and the chain head's row
/// carries the whole chain (`· supersedes gen-2 ← gen-1`).
List<String> taskJobLines(
  List<TaskJob> jobs, {
  required String Function(String) dim,
  Map<String, String> supersedesOf = const {},
}) {
  // Only fold a job when its successor is ALSO listed: /tasks lists
  // background jobs only, and hiding a row whose successor never shows up
  // (e.g. superseded by a blocking spawn) would drop information silently.
  final listed = jobs.map((job) => job.id).toSet();
  final superseded = {
    for (final entry in supersedesOf.entries)
      if (listed.contains(entry.key)) entry.value,
  };
  return [
    'background agents:',
    for (final job in jobs)
      if (!superseded.contains(job.id))
        taskJobLine(job, dim: dim, supersedesOf: supersedesOf),
  ];
}

/// One task-list row: status marker, id, agent, status name, elapsed time,
/// task preview, and the agent:// ref. With [supersedesOf] the row also
/// carries the respawn chain it folds (see [taskJobLines]).
String taskJobLine(
  TaskJob job, {
  required String Function(String) dim,
  Map<String, String> supersedesOf = const {},
}) {
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
  // The folded generations, newest predecessor first (`x ← y` reads "this
  // entry supersedes x, which superseded y").
  final chain = <String>[];
  String? previous = supersedesOf[job.id];
  while (previous != null && !chain.contains(previous)) {
    chain.add(previous);
    previous = supersedesOf[previous];
  }
  final supersedesNote = chain.isEmpty
      ? ''
      : ' · supersedes ${chain.join(' ← ')}';
  return '  $marker ${job.id} (${job.agent}) ${job.status.name}$elapsed — '
      '$task$supersedesNote  ${dim('agent://${job.id}')}';
}
