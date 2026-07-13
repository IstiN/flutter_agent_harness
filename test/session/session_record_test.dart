import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  final ts = DateTime.utc(2026, 1, 2, 3, 4, 5);

  SessionRecord roundTrip(SessionRecord record) {
    return SessionRecord.fromJson(record.toJson());
  }

  group('SessionRecord JSON round-trips', () {
    test('MessageRecord with a user message', () {
      final record = MessageRecord(
        id: 'e1',
        parentId: null,
        timestamp: ts,
        message: UserMessage.text('hello', timestamp: ts),
      );
      final restored = roundTrip(record) as MessageRecord;
      expect(restored.type, 'message');
      expect(restored.id, 'e1');
      expect(restored.parentId, isNull);
      expect(restored.timestamp.toIso8601String(), ts.toIso8601String());
      expect((restored.message as UserMessage).content, 'hello');
    });

    test('MessageRecord with an assistant message', () {
      final record = MessageRecord(
        id: 'e2',
        parentId: 'e1',
        timestamp: ts,
        message: AssistantMessage(
          content: const [TextContent(text: 'hi')],
          api: 'openai-completions',
          provider: 'openrouter',
          model: 'm1',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: ts,
        ),
      );
      final restored = roundTrip(record) as MessageRecord;
      final message = restored.message as AssistantMessage;
      expect(message.provider, 'openrouter');
      expect((message.content.single as TextContent).text, 'hi');
    });

    test('ThinkingLevelChangeRecord', () {
      final restored =
          roundTrip(
                ThinkingLevelChangeRecord(
                  id: 'e3',
                  parentId: 'e2',
                  timestamp: ts,
                  thinkingLevel: 'high',
                ),
              )
              as ThinkingLevelChangeRecord;
      expect(restored.type, 'thinking_level_change');
      expect(restored.thinkingLevel, 'high');
    });

    test('ModelChangeRecord', () {
      final restored =
          roundTrip(
                ModelChangeRecord(
                  id: 'e4',
                  parentId: 'e3',
                  timestamp: ts,
                  provider: 'anthropic',
                  modelId: 'claude',
                ),
              )
              as ModelChangeRecord;
      expect(restored.type, 'model_change');
      expect(restored.provider, 'anthropic');
      expect(restored.modelId, 'claude');
    });

    test('ActiveToolsChangeRecord', () {
      final restored =
          roundTrip(
                ActiveToolsChangeRecord(
                  id: 'e5',
                  parentId: 'e4',
                  timestamp: ts,
                  activeToolNames: const ['read', 'write'],
                ),
              )
              as ActiveToolsChangeRecord;
      expect(restored.type, 'active_tools_change');
      expect(restored.activeToolNames, ['read', 'write']);
    });

    test('CompactionRecord with details and fromHook', () {
      final restored =
          roundTrip(
                CompactionRecord(
                  id: 'e6',
                  parentId: 'e5',
                  timestamp: ts,
                  summary: 'summary text',
                  firstKeptEntryId: 'e3',
                  tokensBefore: 12345,
                  details: const {'k': 'v'},
                  fromHook: true,
                ),
              )
              as CompactionRecord;
      expect(restored.type, 'compaction');
      expect(restored.summary, 'summary text');
      expect(restored.firstKeptEntryId, 'e3');
      expect(restored.tokensBefore, 12345);
      expect(restored.details, {'k': 'v'});
      expect(restored.fromHook, isTrue);
    });

    test('CompactionRecord omits null details/fromHook', () {
      final record = CompactionRecord(
        id: 'e6',
        parentId: null,
        timestamp: ts,
        summary: 's',
        firstKeptEntryId: 'e1',
        tokensBefore: 1,
      );
      final json = record.toJson();
      expect(json.containsKey('details'), isFalse);
      expect(json.containsKey('fromHook'), isFalse);
      final restored = roundTrip(record) as CompactionRecord;
      expect(restored.details, isNull);
      expect(restored.fromHook, isNull);
    });

    test('BranchSummaryRecord', () {
      final restored =
          roundTrip(
                BranchSummaryRecord(
                  id: 'e7',
                  parentId: 'e6',
                  timestamp: ts,
                  fromId: 'e6',
                  summary: 'branch summary',
                ),
              )
              as BranchSummaryRecord;
      expect(restored.type, 'branch_summary');
      expect(restored.fromId, 'e6');
      expect(restored.summary, 'branch summary');
    });

    test('CustomRecord', () {
      final restored =
          roundTrip(
                CustomRecord(
                  id: 'e8',
                  parentId: null,
                  timestamp: ts,
                  customType: 'checkpoint',
                  data: const {'n': 1},
                ),
              )
              as CustomRecord;
      expect(restored.type, 'custom');
      expect(restored.customType, 'checkpoint');
      expect(restored.data, {'n': 1});
    });

    test('CustomMessageRecord with string content', () {
      final restored =
          roundTrip(
                CustomMessageRecord(
                  id: 'e9',
                  parentId: null,
                  timestamp: ts,
                  customType: 'note',
                  content: 'a note',
                  display: true,
                ),
              )
              as CustomMessageRecord;
      expect(restored.type, 'custom_message');
      expect(restored.content, 'a note');
      expect(restored.display, isTrue);
    });

    test('CustomMessageRecord with block content', () {
      final restored =
          roundTrip(
                CustomMessageRecord(
                  id: 'e9',
                  parentId: null,
                  timestamp: ts,
                  customType: 'note',
                  content: const [TextContent(text: 'blocks')],
                  display: false,
                ),
              )
              as CustomMessageRecord;
      final blocks = restored.content as List<ContentBlock>;
      expect((blocks.single as TextContent).text, 'blocks');
    });

    test('LabelRecord with label and label removal', () {
      final restored =
          roundTrip(
                LabelRecord(
                  id: 'e10',
                  parentId: null,
                  timestamp: ts,
                  targetId: 'e1',
                  label: 'important',
                ),
              )
              as LabelRecord;
      expect(restored.type, 'label');
      expect(restored.targetId, 'e1');
      expect(restored.label, 'important');

      final removal =
          roundTrip(
                LabelRecord(
                  id: 'e11',
                  parentId: null,
                  timestamp: ts,
                  targetId: 'e1',
                ),
              )
              as LabelRecord;
      expect(removal.label, isNull);
      expect(removal.toJson().containsKey('label'), isFalse);
    });

    test('SessionInfoRecord', () {
      final restored =
          roundTrip(
                SessionInfoRecord(
                  id: 'e12',
                  parentId: null,
                  timestamp: ts,
                  name: 'my session',
                ),
              )
              as SessionInfoRecord;
      expect(restored.type, 'session_info');
      expect(restored.name, 'my session');
    });

    test('LeafRecord with and without target', () {
      final restored =
          roundTrip(
                LeafRecord(
                  id: 'e13',
                  parentId: 'e12',
                  timestamp: ts,
                  targetId: 'e7',
                ),
              )
              as LeafRecord;
      expect(restored.type, 'leaf');
      expect(restored.targetId, 'e7');

      final toRoot =
          roundTrip(LeafRecord(id: 'e14', parentId: 'e13', timestamp: ts))
              as LeafRecord;
      expect(toRoot.targetId, isNull);
    });

    test('fromJson rejects unknown types', () {
      expect(
        () => SessionRecord.fromJson({
          'type': 'bogus',
          'id': 'x',
          'parentId': null,
          'timestamp': ts.toIso8601String(),
        }),
        throwsFormatException,
      );
    });

    test('fromJson rejects missing id', () {
      expect(
        () => SessionRecord.fromJson({
          'type': 'label',
          'parentId': null,
          'timestamp': ts.toIso8601String(),
          'targetId': 'e1',
        }),
        throwsFormatException,
      );
    });

    test('fromJson rejects non-string parentId', () {
      expect(
        () => SessionRecord.fromJson({
          'type': 'label',
          'id': 'x',
          'parentId': 42,
          'timestamp': ts.toIso8601String(),
          'targetId': 'e1',
        }),
        throwsFormatException,
      );
    });
  });

  group('SessionHeader', () {
    test('round-trips with all fields', () {
      final header = SessionHeader(
        id: 's1',
        timestamp: ts,
        cwd: '/work',
        parentSessionPath: '/sessions/parent.jsonl',
        metadata: const {'source': 'test'},
      );
      final json = header.toJson();
      expect(json['type'], 'session');
      expect(json['version'], 3);
      final restored = SessionHeader.fromJson(json);
      expect(restored.id, 's1');
      expect(restored.cwd, '/work');
      expect(restored.parentSessionPath, '/sessions/parent.jsonl');
      expect(restored.metadata, {'source': 'test'});
    });

    test('rejects unsupported version', () {
      expect(
        () => SessionHeader.fromJson({
          'type': 'session',
          'version': 2,
          'id': 's1',
          'timestamp': ts.toIso8601String(),
          'cwd': '/work',
        }),
        throwsFormatException,
      );
    });

    test('rejects wrong type and missing fields', () {
      expect(
        () => SessionHeader.fromJson({'type': 'nope'}),
        throwsFormatException,
      );
      expect(
        () => SessionHeader.fromJson({
          'type': 'session',
          'version': 3,
          'timestamp': ts.toIso8601String(),
          'cwd': '/work',
        }),
        throwsFormatException,
      );
      expect(
        () => SessionHeader.fromJson({
          'type': 'session',
          'version': 3,
          'id': 's1',
          'timestamp': ts.toIso8601String(),
        }),
        throwsFormatException,
      );
    });

    test('rejects non-object metadata', () {
      expect(
        () => SessionHeader.fromJson({
          'type': 'session',
          'version': 3,
          'id': 's1',
          'timestamp': ts.toIso8601String(),
          'cwd': '/work',
          'metadata': [1, 2],
        }),
        throwsFormatException,
      );
    });
  });
}
