import '../tools/ask_tool.dart';

/// The question header and numbered option list of one ask question
/// (recommended flagged), as plain lines.
List<String> askQuestionLines(AskQuestion question, int index, int total) {
  final progress = total > 1 ? ' (${index + 1}/$total)' : '';
  return [
    '[ask] ${question.question}$progress',
    for (var i = 0; i < question.options.length; i++)
      _askOptionLine(question, i),
  ];
}

/// One numbered option row, with its description and the recommended
/// marker.
String _askOptionLine(AskQuestion question, int i) {
  final option = question.options[i];
  final description = option.description?.trim();
  final suffix = question.recommended == i ? ' (Recommended)' : '';
  return '[ask]   ${i + 1}) ${option.label}'
      '${description == null || description.isEmpty ? '' : ' — $description'}'
      '$suffix';
}

/// The comma-separated 1-based label of the currently toggled options.
String pickedLabel(Set<int> selected) => selected.isEmpty
    ? '-'
    : (selected.toList()..sort()).map((i) => '${i + 1}').join(', ');
