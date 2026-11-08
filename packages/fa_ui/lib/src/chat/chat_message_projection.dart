// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_chat_core/flutter_chat_core.dart';

import 'fa_chat_service.dart';

/// Projects backend messages into flutter_chat rows, collapsing consecutive
/// visible system notices for display only. Empty aborted assistant turns
/// between notices are transparent: they have no visual payload and must not
/// split an otherwise continuous heartbeat run.
///
/// Message ids keep their original `msg-<backend-index>` positions. A notice
/// run is represented by one visible group at its first position and
/// zero-height rows at every other position, so history paging, record jumps
/// and incremental id-based diffing keep their existing contract.
List<Message> projectFaChatMessages(List<FaChatMessage> source) => [
  for (final (index, chat) in source.indexed)
    _projectDisplayMessage(source, index, chat),
];

bool _isEmptyAssistant(FaChatMessage chat) =>
    chat.role == 'assistant' &&
    chat.content.trim().isEmpty &&
    chat.attachments.isEmpty;

Message _projectDisplayMessage(
  List<FaChatMessage> source,
  int index,
  FaChatMessage chat,
) {
  final now = DateTime.now();
  final id = 'msg-$index';
  if (isFaSystemNoticeContent(chat.content)) {
    var previous = index - 1;
    while (previous >= 0 && _isEmptyAssistant(source[previous])) {
      previous--;
    }
    final continuesGroup =
        previous >= 0 && isFaSystemNoticeContent(source[previous].content);
    if (continuesGroup) {
      return Message.custom(
        id: id,
        authorId: 'system',
        createdAt: now,
        metadata: const {'role': 'systemNoticeHidden', 'content': ''},
      );
    }
    final notices = <String>[];
    for (var i = index; i < source.length; i++) {
      final candidate = source[i];
      if (_isEmptyAssistant(candidate)) continue;
      if (!isFaSystemNoticeContent(candidate.content)) break;
      notices.add(candidate.content);
    }
    return Message.custom(
      id: id,
      authorId: 'system',
      createdAt: now,
      metadata: {
        'role': 'systemNoticeGroup',
        'content': chat.content,
        'data': {'systemNotices': notices},
      },
    );
  }

  switch (chat.role) {
    case 'user':
      // User messages with attachments render through the shared
      // ChatMessageTile (thumbnails/chips inside the bubble).
      if (chat.attachments.isNotEmpty) {
        return Message.custom(
          id: id,
          authorId: 'user',
          createdAt: now,
          metadata: <String, dynamic>{
            'role': 'user',
            'content': chat.content,
            'attachments': chat.attachments,
          },
        );
      }
      return Message.text(
        id: id,
        authorId: 'user',
        text: chat.content,
        createdAt: now,
      );
    case 'assistant':
      return Message.text(
        id: id,
        authorId: 'assistant',
        text: chat.content,
        createdAt: now,
      );
    case 'system':
    case 'systemNotice':
    case 'tool':
    case 'thinking':
    case 'widget':
      return Message.custom(
        id: id,
        authorId: chat.role == 'tool' ? 'tool' : 'system',
        createdAt: now,
        metadata: <String, dynamic>{
          'role': chat.role,
          'toolName': chat.toolName,
          'content': chat.content,
          'isError': chat.isError,
          'data': chat.data,
          // The thinking tile's live gate identifies the streaming block by
          // its original transcript position, not a rebuilt message identity.
          'transcriptIndex': index,
        },
      );
    default:
      return Message.text(
        id: id,
        authorId: 'system',
        text: chat.content,
        createdAt: now,
      );
  }
}
