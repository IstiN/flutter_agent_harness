// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #148 — structured compaction: the context projection renders
/// hidden/compacted records as inline markers over stable numeric ids
/// (JSONL line numbers), never renumbering anything, never splitting tool
/// pairs on the wire.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) {
  return AssistantMessage(
    content: [
      TextContent(text: text),
      if (calls != null) ...calls,
    ],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

ToolCall _call(String id, String name) =>
    ToolCall(id: id, name: name, arguments: {'path': 'x.dart'});

ToolResultMessage _result(String callId, String name, String text) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: name,
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// Appends a bug-fix shaped history:
  /// 2 user ask, 3 assistant call(read), 4 result, 5 assistant text,
  /// 6 assistant call(bash)+7 result, 8 user thanks. Returns the
  /// record ids in append order (line numbers are these + 1: the header
  /// is line 1).
  Future<(Session, List<String>)> sessionWithHistory(Session session) async {
    final ids = <String>[];
    ids.add(await session.appendMessage(UserMessage.text('fix the login crash')));
    ids.add(await session.appendMessage(
      _assistant('looking', calls: [_call('c1', 'read')]),
    ));
    ids.add(await session.appendMessage(
      _result('c1', 'read', 'x' * 16000),
    ));
    ids.add(await session.appendMessage(
      _assistant('found it — token expiry check'),
    ));
    ids.add(await session.appendMessage(
      _assistant('run tests', calls: [_call('c2', 'bash')]),
    ));
    ids.add(await session.appendMessage(_result('c2', 'bash', 'y' * 12000)));
    ids.add(await session.appendMessage(UserMessage.text('thanks')));
    return (session, ids);
  }

  test('hidden records render as one-line markers at their position', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    final (_, ids) = await sessionWithHistory(session);
    // Hide the read result (line 4) and the bash pair (lines 6-7).
    await session.appendHiddenRange(recordIds: [ids[2]]);
    await session.appendHiddenRange(recordIds: [ids[4], ids[5]]);

    final messages = await session.buildContextMessages();

    // 7 records -> 7 projected entries (markers replace content in place).
    expect(messages, hasLength(7));
    final marker4 = messages[2] as ToolResultMessage;
    // Wire safety: the hidden result keeps its call id and tool name so the
    // pair stays intact (issue #85).
    expect(marker4.toolCallId, 'c1');
    expect(marker4.toolName, 'read');
    expect((marker4.content.single as TextContent).text, contains('[4:hidden'));
    // The hidden assistant carrier becomes a plain user-role marker.
    expect(messages[4], isA<UserMessage>());
    expect((messages[4] as UserMessage).content as String, contains('[6:hidden'));
    // The hidden bash result's carrier is hidden too, so the result
    // downgrades to a plain user-role marker (wire safety).
    expect(messages[5], isA<UserMessage>());
    expect((messages[5] as UserMessage).content as String, contains('[7:hidden'));
    // Kept messages render untouched.
    expect((messages[3] as AssistantMessage).content.first as TextContent,
        isA<TextContent>());
    expect((messages[6] as UserMessage).content as String, 'thanks');
    // Wire validity end to end.
    expect(validateToolPairing(messages), isEmpty);
  });

  test('markers carry numeric ids that never shift (identities)', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    final (_, ids) = await sessionWithHistory(session);
    await session.appendHiddenRange(recordIds: [ids[2]]);

    var messages = await session.buildContextMessages();
    var first = (messages[2] as ToolResultMessage).content.single as TextContent;
    expect(first.text, startsWith('[4:hidden'));

    // Hide more records around it — record 4's marker still says 4.
    await session.appendHiddenRange(recordIds: [ids[0], ids[3]]);
    messages = await session.buildContextMessages();
    first = (messages[2] as ToolResultMessage).content.single as TextContent;
    expect(first.text, startsWith('[4:hidden'));
    // The newly hidden user ask is exempt-shaped in the file but hidden
    // state is explicit: its marker names line 2.
    expect((messages[0] as UserMessage).content as String, startsWith('[2:hidden'));
  });

  test('checkpoint swallows its range and lists covered expand ids', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    final (_, ids) = await sessionWithHistory(session);
    // Checkpoint records 2..6 (the whole investigation arc).
    await session.appendCompactCheckpoint(
      firstRecordId: ids[0],
      lastRecordId: ids[4],
      text: 'investigated login crash, found token-expiry bug',
      coversRecordIds: [ids[1], ids[2], ids[3], ids[4]],
      flattenedRecordIds: const [],
    );

    final messages = await session.buildContextMessages();

    // The ckpt marker replaces records 2-6 in place; 7 and 8 stay.
    expect(messages, hasLength(3));
    final ckpt = (messages[0] as UserMessage).content as String;
    expect(ckpt, startsWith('[2-6:ckpt'));
    expect(ckpt, contains('covers:3-6'));
    expect(ckpt, contains('investigated login crash'));
    // The bash call (line 6) was swallowed, so its result (line 7) cannot
    // stay a tool_result on the wire — it renders as a user-role marker.
    expect(messages[1], isA<UserMessage>());
    expect((messages[1] as UserMessage).content as String, startsWith('[7:hidden'));
    expect((messages[2] as UserMessage).content as String, 'thanks');
    expect(validateToolPairing(messages), isEmpty);
  });

  test('nested checkpoint swallows the inner checkpoint record', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    final (_, ids) = await sessionWithHistory(session);
    await session.appendCompactCheckpoint(
      firstRecordId: ids[0],
      lastRecordId: ids[4],
      text: 'arc one',
      coversRecordIds: [ids[1], ids[2]],
      flattenedRecordIds: const [],
    );
    // Level 2: covers the level-1 checkpoint record (ids[5] is the hidden
    // bash pair member; the outer range runs to the level-1 ckpt record).
    final branch = await session.getBranch();
    final ckpt1Id = branch.last.id;
    await session.appendCompactCheckpoint(
      firstRecordId: ids[0],
      lastRecordId: ids[5],
      text: 'long debugging arc',
      coversRecordIds: [ids[1], ids[2], ids[3], ids[4], ckpt1Id],
      flattenedRecordIds: const [],
    );

    final messages = await session.buildContextMessages();

    // Only the OUTER checkpoint marker renders, in place of record 2; the
    // range runs to the bash result (line 7), leaving only the final
    // user turn (line 8) live.
    expect(messages, hasLength(2));
    final outer = (messages[0] as UserMessage).content as String;
    expect(outer, startsWith('[2-7:ckpt'));
    expect(outer, contains('long debugging arc'));
    expect(outer, isNot(contains('arc one')));
    expect((messages[1] as UserMessage).content as String, 'thanks');
    expect(validateToolPairing(messages), isEmpty);
  });

  test('hidden state stores record ids, never positions', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    final (_, ids) = await sessionWithHistory(session);
    await session.appendHiddenRange(recordIds: [ids[2]]);
    await session.appendCompactCheckpoint(
      firstRecordId: ids[0],
      lastRecordId: ids[1],
      text: 't',
      coversRecordIds: [ids[0]],
      flattenedRecordIds: const [],
    );

    final entries = await session.getEntries();
    // Byte-scan of the state model (AC3): only the opaque record ids.
    for (final record in entries) {
      final json = record.toJson();
      switch (record) {
        case HiddenRangeRecord():
          expect(json['recordIds'], ids.sublist(2, 3));
        case CompactCheckpointRecord():
          expect(json['firstRecordId'], ids[0]);
          expect(json['lastRecordId'], ids[1]);
        default:
          break;
      }
      expect(json.containsKey('seq'), isFalse);
      expect(json.containsKey('line'), isFalse);
      expect(json.containsKey('index'), isFalse);
    }
  });

  test('replay from disk rebuilds the identical structured view', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    final (_, ids) = await sessionWithHistory(session);
    await session.appendHiddenRange(recordIds: [ids[2], ids[5]]);
    await session.appendCompactCheckpoint(
      firstRecordId: ids[0],
      lastRecordId: ids[3],
      text: 'arc',
      coversRecordIds: [ids[1], ids[2]],
      flattenedRecordIds: const [],
    );
    final before = await session.buildContextMessages();

    final reopened = await repo.open(await session.getMetadata());
    final after = await reopened.buildContextMessages();

    expect(
      [for (final m in after) m.toJson()],
      [for (final m in before) m.toJson()],
    );
  });
}
