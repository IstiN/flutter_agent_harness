import 'package:flutter_agent_harness/src/cli/agent_hub_panel.dart';

void main() {
  final huge = 'echo ${'y' * 5000}';
  final lines = taskBlockLines(
    TaskBlock(
      kind: 'bash',
      id: 'sh-1234',
      state: TaskBlockState.done,
      elapsed: 2,
      label: huge,
      detail: 'sh-1234 · work · exit 0 · log: /home/runner/work/repo/.fah/bash_jobs/sh-1234/job-output.log',
    ),
    width: 100,
    fit: CardTextFit.wrap,
  );
  final body = lines.join('\n');
  print('lines: ${lines.length}');
  print('contains log pointer: ${body.contains('log: /home/runner')}');
  print('contains more-chars pointer: ${body.contains('more chars, see <log>')}');
  final last5 = lines.length <= 8 ? lines : lines.sublist(lines.length - 8);
  for (final l in last5) {
    print('|${l.length}> $l');
  }
}
