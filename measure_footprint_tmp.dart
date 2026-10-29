import 'package:flutter_agent_harness/flutter_agent_harness.dart';

void main() {
  final mgr = SubagentManager(parentSessionId: 'p', maxReplyChars: 8000);
  final descs = [
    for (final tool in subagentMonitoringTools(manager: mgr, currentSubagentId: () => null))
      if (tool.name == 'reply' || tool.name == 'agent_message') tool.description,
  ];
  final contract = deliverableChunkContract(8000).length;
  final oldFormulaExtra = descs
      .map((d) => d.length - contract < 0 ? 0 : d.length - contract)
      .fold<int>(0, (a, b) => a + b);
  final total = contract + descs.fold<int>(0, (a, d) => a + d.length);
  print('contract=$contract');
  print('descs=${descs.map((d) => d.length).toList()}');
  print('oldFormulaContractTokens=${((contract + oldFormulaExtra) / 4).ceil()}');
  print('totalFootprintChars=$total');
}
