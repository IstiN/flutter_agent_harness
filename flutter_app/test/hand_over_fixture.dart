// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 test fixture: the merged hand-over call is the structured
/// engine's DEFAULT without a separate smol role, so a fake stream that
/// used to answer the judge / checkpoint prompts must answer the
/// hand-over instruction too — the same shape the core CLI suites route
/// with (`test/cli/agent_cli_test_support.dart`).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Whether [context] is the merged hand-over call — its LAST user
/// message is the rendered `prompts/compaction/hand_over.md`
/// instruction (the fold-range line), appended to the S0 prefix.
bool isHandOverCall(Context context) {
  final last = context.messages.lastOrNull;
  return last is UserMessage &&
      userMessageText(last).contains('Fold range: records');
}

final _openUserRequestsBlock = RegExp(
  r'<open-user-requests>\n(.*?)\n?</open-user-requests>',
  dotAll: true,
);

/// A valid hand-over reply for the instruction in [context]: [hideLines]
/// as the hide list (nothing by default), the `-` separator, the
/// mandatory `## Open User Requests` section with the instruction's
/// mechanical asks verbatim (`none` when empty), then [text] as the
/// transfer.
String handOverReplyFor(
  Context context, {
  List<String> hideLines = const [],
  required String text,
}) {
  final instruction = userMessageText(context.messages.last as UserMessage);
  final block = _openUserRequestsBlock.firstMatch(instruction)?.group(1) ?? '';
  final asks = [
    for (final line in block.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  return [
    ...hideLines,
    '-',
    '## Open User Requests',
    if (asks.isEmpty) '- none' else ...asks,
    '## Hand-over',
    text,
  ].join('\n');
}

/// The text of a user message (string or text blocks).
String userMessageText(UserMessage message) => message.content is String
    ? message.content as String
    : (message.content as List<Object>)
          .whereType<TextContent>()
          .map((block) => block.text)
          .join('\n');
