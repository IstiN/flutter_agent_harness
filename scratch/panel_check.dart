import 'package:flutter_agent_harness/flutter_agent_harness.dart';

void main() {
  print(submitErrorPanelLine(
    StateError(
      'Error on line 8, column 5: Duplicate mapping key.\n'
      '  ╷\n'
      '8 │     "copilot":\n'
      '  │     ^^^^^^^^^\n'
      '  ╵',
    ),
  ));
}
