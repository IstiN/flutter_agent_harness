@TestOn('vm')
/// Executor-level integration for the durable deliverable path (issue
/// #1829, IT-02/03/04/06, UT-07): real TaskExecutor + SubagentManager +
/// AgentOutputStore driven by scripted child runs.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'parent-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

const _secret = 'sk-live-canary-0123456789';

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> _toolTurn(
  String toolName,
  Map<String, dynamic> args, {
  StopReason reason = StopReason.toolUse,
}) {
  final empty = _assistant();
  final call = ToolCall(id: 'call-1', name: toolName, arguments: args);
  final partial = _assistant(content: [call], stopReason: reason);
  return [
    StartEvent(partial: empty),
    ToolCallStartEvent(contentIndex: 0, partial: empty),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: partial),
    DoneEvent(reason: reason, message: partial),
  ];
}

/// One scripted route: child runs whose last user message contains [match]
/// replay [turns] in order; unmatched runs answer 'done'.
typedef _Rule = ({String match, List<List<AssistantMessageEvent>> turns});

/// Scripted fake [StreamFunction]: routes by last user message and records
/// every context (including the child system prompt, UT-07).
final class _ScriptedStream {
  _ScriptedStream([List<_Rule> rules = const []]) : _rules = List.of(rules);

  final List<_Rule> _rules;
  final contexts = <Context>[];

  static String lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is UserMessage) {
        final content = message.content;
        if (content is String) return content;
        if (content is List<ContentBlock>) {
          return content.whereType<TextContent>().map((b) => b.text).join('\n');
        }
      }
    }
    return '';
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final text = lastUserText(context);
    for (final rule in _rules) {
      if (text.contains(rule.match) && rule.turns.isNotEmpty) {
        return _streamOf(rule.turns.removeAt(0));
      }
    }
    return _streamOf(_textTurn('done'));
  }

  static AssistantMessageEventStream _streamOf(
    List<AssistantMessageEvent> events,
  ) {
    final stream = AssistantMessageEventStream();
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// Minimal in-memory fabric so children can agent_message the parent.
final class _FakeFabric implements MessagingRepository {
  final _inboxes = <String, List<AgentMessage>>{};

  List<AgentMessage> inbox(String mailbox) =>
      List.unmodifiable(_inboxes[mailbox] ?? const []);

  @override
  Future<void> send(AgentMessage message) async =>
      _inboxes.putIfAbsent(message.toId, () => []).add(message);

  @override
  Future<List<AgentMessage>> peek(String agentId) async => inbox(agentId);

  @override
  Future<List<AgentMessage>> drain(String agentId) async =>
      List.unmodifiable(_inboxes.remove(agentId) ?? const []);

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {}

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {}

  @override
  Future<List<MailboxEntry>> directory() async => const [];
}

final class _Harness {
  _Harness(this.tool, this.config, this.stream, this.manager, this.fabric);

  final AgentTool tool;
  final TaskToolConfig config;
  final _ScriptedStream stream;
  final SubagentManager manager;
  final _FakeFabric? fabric;
}

Future<_Harness> _harness({
  List<_Rule> rules = const [],
  int maxReplyChars = 200,
  String Function(String text)? deliverableRedactor,
  bool fabric = false,
}) async {
  final s = _ScriptedStream(rules);
  final f = fabric ? _FakeFabric() : null;
  final manager = SubagentManager(
    parentSessionId: 'p',
    maxReplyChars: maxReplyChars,
    messaging: f,
  );
  final config = TaskToolConfig(
    childTools: const [],
    streamFunction: () => s.call,
    model: () => _model,
    subagentManager: manager,
    deliverableRedactor: deliverableRedactor,
  );
  return _Harness(taskTool(config: config), config, s, manager, f);
}

Future<TaskSingleResult> _spawnOne(_Harness h, String name, String task) async {
  return h.config.executor.runSpawn(
    item: TaskItem(task: task, name: name),
    index: 0,
    context: 'ctx',
  );
}

void main() {
  group('IT-02: oversized report is artifact-backed end to end', () {
    test(
      'envelope delivery, full redacted resolution, deliverable line',
      () async {
        final h = await _harness(
          rules: [
            (
              match: 'write the report',
              turns: [
                _toolTurn('reply', {'message': 'the full report ' * 40}),
              ],
            ),
          ],
          maxReplyChars: 200,
          deliverableRedactor: (text) => text.replaceAll(_secret, '***'),
        );
        final result = await _spawnOne(h, 'Researcher', 'write the report');

        expect(result.status, TaskSpawnStatus.completed);
        // The reply carried the envelope, not the raw body.
        expect(result.reply, isNotNull);
        expect(result.reply!.length, lessThanOrEqualTo(200));
        expect(result.reply, contains('agent://'));
        expect(result.reply, contains('complete'));
        // The parent result carries the record with a resolvable pointer.
        expect(result.deliverables, hasLength(1));
        final record = result.deliverables.single;
        expect(record.status, AgentArtifactStatus.complete);
        final resolution = resolveAgentUrl(record.pointer!, h.config.outputs);
        expect(resolution.content, 'the full report ' * 40);
        expect(resolution.notes.single, contains('deliverable: complete'));
      },
    );

    test(
      'AC1: an in-budget reply stays byte-identical with no artifact',
      () async {
        final h = await _harness(
          rules: [
            (
              match: 'small job',
              turns: [
                _toolTurn('reply', {'message': 'short and complete'}),
              ],
            ),
          ],
          maxReplyChars: 200,
        );
        final result = await _spawnOne(h, 'Small', 'small job');
        expect(result.reply, 'short and complete');
        expect(result.deliverables, isEmpty);
      },
    );
  });

  group('IT-04: truncated reply, stubs, and fallback', () {
    test(
      'partial pointer survives a later content-free stub (AC3/I4)',
      () async {
        final h = await _harness(
          rules: [
            (
              match: 'report job',
              turns: [
                // The truncated generation: the reply call never executes.
                _toolTurn('reply', {
                  'message': 'salvageable research body ' * 20,
                }, reason: StopReason.length),
                // The child "recovers" with a meta-summary stub.
                _toolTurn('reply', {
                  'message': 'delivered the map to the parent',
                }),
              ],
            ),
          ],
          maxReplyChars: 150,
        );
        final result = await _spawnOne(h, 'Explorer', 'report job');

        expect(result.status, TaskSpawnStatus.completed);
        // The stub reply is what the child sent — but the partial pointer
        // rides OUT OF BAND on the result (I4).
        expect(result.reply, 'delivered the map to the parent');
        expect(result.deliverables, hasLength(1));
        final partial = result.deliverables.single;
        expect(partial.status, AgentArtifactStatus.partial);
        expect(
          resolveAgentUrl(partial.pointer!, h.config.outputs).content,
          'salvageable research body ' * 20,
        );
        // A stub WITH a reply is not the null-reply fallback case (E9).
        expect(result.stubFallback, isNull);
      },
    );

    test(
      'no reply after a truncated report surfaces the transcript pointer (AC11)',
      () async {
        final h = await _harness(
          rules: [
            (
              match: 'report job',
              turns: [
                // Truncated args with NO salvageable message text (E2).
                _toolTurn('reply', {}, reason: StopReason.length),
                // The child gives up: final text only, no reply tool call.
                _textTurn('the map has been delivered to the parent'),
              ],
            ),
          ],
          maxReplyChars: 100,
        );
        final result = await _spawnOne(h, 'Explorer', 'report job');
        expect(result.reply, isNull);
        expect(
          result.deliverables,
          isEmpty,
          reason: 'salvage produced no text',
        );
        expect(result.stubFallback, isNotNull);
        expect(result.stubFallback, contains('output token limit'));
        expect(result.stubFallback, contains(h.manager['Explorer']!.sessionId));
      },
    );

    test('a legitimate short success is never flagged (E9)', () async {
      final h = await _harness(
        rules: [
          (
            match: 'tiny job',
            turns: [
              _toolTurn('reply', {'message': 'done, answer is 4'}),
            ],
          ),
        ],
        maxReplyChars: 100,
      );
      final result = await _spawnOne(h, 'Tiny', 'tiny job');
      expect(result.reply, 'done, answer is 4');
      expect(result.deliverables, isEmpty);
      expect(result.stubFallback, isNull);
    });
  });

  group('IT-03: chunked report over agent_message', () {
    test(
      'ordered parts + manifest rule complete; the parent inbox got envelopes-free parts',
      () async {
        final h = await _harness(
          rules: [
            (
              match: 'chunk job',
              turns: [
                _toolTurn('agent_message', {
                  'to': 'main',
                  'message': 'part zero findings',
                  'report_id': 'r1',
                  'part_index': 0,
                }),
                _toolTurn('agent_message', {
                  'to': 'main',
                  'message': 'part one findings',
                  'report_id': 'r1',
                  'part_index': 1,
                }),
                _toolTurn('reply', {
                  'message': 'report r1 complete',
                  'report_id': 'r1',
                  'report_parts': 2,
                }),
              ],
            ),
          ],
          maxReplyChars: 200,
          fabric: true,
        );
        final result = await _spawnOne(h, 'Chunker', 'chunk job');

        final manifest = result.deliverables.lastWhere(
          (r) => r.kind == DeliverableRecordKind.manifest,
        );
        expect(manifest.manifestComplete, isTrue);
        // The parts rode the parent inbox directly (in budget, no artifact).
        final chunks = result.deliverables
            .where((r) => r.kind == DeliverableRecordKind.chunk)
            .toList();
        expect(chunks, hasLength(2));
        for (final chunk in chunks) {
          expect(chunk.pointer, isNull);
        }
        expect(h.fabric!.inbox('main'), hasLength(2));
      },
    );

    test(
      'missing parts mark the manifest INCOMPLETE on the result (E10)',
      () async {
        final h = await _harness(
          rules: [
            (
              match: 'chunk job',
              turns: [
                _toolTurn('agent_message', {
                  'to': 'main',
                  'message': 'part zero only',
                  'report_id': 'r1',
                  'part_index': 0,
                }),
                _toolTurn('reply', {
                  'message': 'claiming complete',
                  'report_id': 'r1',
                  'report_parts': 3,
                }),
              ],
            ),
          ],
          maxReplyChars: 200,
          fabric: true,
        );
        final result = await _spawnOne(h, 'Chunker', 'chunk job');
        final manifest = result.deliverables.lastWhere(
          (r) => r.kind == DeliverableRecordKind.manifest,
        );
        expect(manifest.manifestComplete, isFalse);
        expect(manifest.missingParts, [1, 2]);
      },
    );

    test(
      'an oversize part still lands via artifact (Core flow A compose)',
      () async {
        final h = await _harness(
          rules: [
            (
              match: 'chunk job',
              turns: [
                _toolTurn('agent_message', {
                  'to': 'main',
                  'message': 'huge part ' * 60,
                  'report_id': 'r1',
                  'part_index': 0,
                }),
                _toolTurn('reply', {
                  'message': 'manifest',
                  'report_id': 'r1',
                  'report_parts': 1,
                }),
              ],
            ),
          ],
          maxReplyChars: 150,
          fabric: true,
        );
        final result = await _spawnOne(h, 'Chunker', 'chunk job');
        // The oversize part is stored as an artifact tagged with its report id.
        final oversize = result.deliverables
            .where(
              (r) =>
                  r.kind == DeliverableRecordKind.artifact &&
                  r.reportId == 'r1',
            )
            .single;
        expect(oversize.pointer, isNotNull);
        expect(
          resolveAgentUrl(oversize.pointer!, h.config.outputs).content,
          'huge part ' * 60,
        );
        // The inbox got the envelope, not the raw body.
        final delivered = h.fabric!.inbox('main').single.text;
        expect(delivered.length, lessThanOrEqualTo(150));
        expect(delivered, contains(oversize.pointer!));
        expect(manifestComplete(result), isTrue);
      },
    );
  });

  group('IT-06: redaction failure degrades explicitly', () {
    test(
      'a throwing redactor yields no artifact, no pointer, no raw write',
      () async {
        final h = await _harness(
          rules: [
            (
              match: 'report job',
              turns: [
                _toolTurn('reply', {'message': 'secret report ' * 40}),
              ],
            ),
          ],
          maxReplyChars: 100,
          deliverableRedactor: (text) => throw StateError('redactor down'),
        );
        final result = await _spawnOne(h, 'Reporter', 'report job');
        expect(result.status, TaskSpawnStatus.completed);
        // No artifact was persisted (the spawn's own result snapshot is not
        // an artifact) and the reply was not delivered raw.
        final artifactIds = h.config.outputs.availableIds
            .where((id) => h.config.outputs.artifactMeta(id) != null)
            .toList();
        expect(artifactIds, isEmpty);
        expect(result.deliverables, isEmpty);
        expect(result.reply, isNull, reason: 'the reply failed closed');
      },
    );
  });

  group('UT-07: the size contract is child-visible', () {
    test('the child system prompt carries the live budget (AC5)', () async {
      final h = await _harness(
        rules: [
          (match: 'prompt job', turns: [_textTurn('ok')]),
        ],
        maxReplyChars: 4321,
      );
      await _spawnOne(h, 'Prompted', 'prompt job');
      final childContext = h.stream.contexts.first;
      expect(childContext.systemPrompt, contains('REPORT SIZE CONTRACT'));
      expect(childContext.systemPrompt, contains('4321 characters'));
      expect(childContext.systemPrompt, contains('report_id'));
      expect(childContext.systemPrompt, contains('part_index'));
      expect(childContext.systemPrompt, contains('output-limit'));
    });
  });
}

bool manifestComplete(TaskSingleResult result) => result.deliverables
    .lastWhere((r) => r.kind == DeliverableRecordKind.manifest)
    .manifestComplete;
