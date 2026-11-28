import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// gh-2461 REG (candidate 2): the gh-2423 seam — machine `custom` records
/// (`model_request_summary`, `shell_job_registry`, trajectory blobs, …)
/// NEVER project into the model context. The loop window of the Argon
/// incident carried one `model_request_summary` (and periodic
/// `shell_job_registry`) record after EVERY exchange; if the invariant
/// broke, every request would carry machine JSON noise. Pins BOTH
/// projection folds: the classic `_entryToMessages` path and the
/// structured `renderStructuredMessages` path (a session with
/// hidden-range/checkpoint records — any long session, like the incident
/// one at ~240k tokens).
void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// The machine JSON payload shapes seen in the incident window.
  Map<String, dynamic> requestSummaryPayload() => {
    'messageCount': 280,
    'systemPromptChars': 47767,
    'toolCount': 17,
    'toolNames': ['read', 'bash'],
    'messages': [
      {'role': 'user', 'chars': 42},
    ],
  };

  Map<String, dynamic> shellJobRegistryPayload() => {
    'jobs': [
      {'id': 'sh-1', 'command': 'dart test', 'status': 'running'},
    ],
  };

  test(
    'classic projection: custom records are inert, messages project',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('please read the file'));
      await session.appendMessage(
        AssistantMessage(
          content: [
            ToolCall(id: 'call-1', name: 'read', arguments: {'path': '/x.js'}),
          ],
          api: 'openai-completions',
          provider: 'copilot',
          model: 'gemini-4-argon',
          usage: Usage.zero,
          stopReason: StopReason.toolUse,
          timestamp: DateTime.utc(2026),
        ),
      );
      await session.appendMessage(
        ToolResultMessage(
          toolCallId: 'call-1',
          toolName: 'read',
          content: [TextContent(text: 'file body')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      );
      // One machine record after the exchange — the incident shape.
      await session.appendCustomEntry(
        customType: 'model_request_summary',
        data: requestSummaryPayload(),
      );
      await session.appendCustomEntry(
        customType: 'shell_job_registry',
        data: shellJobRegistryPayload(),
      );

      final messages = await session.buildContextMessages();

      // The real exchange projects.
      expect(messages.map((m) => m.role), ['user', 'assistant', 'toolResult']);
      // No machine JSON leaked into the wire messages.
      for (final message in messages) {
        final text = message is UserMessage
            ? userMessageText(message.content)
            : null;
        if (text != null) {
          expect(text, isNot(contains('model_request_summary')));
          expect(text, isNot(contains('systemPromptChars')));
          expect(text, isNot(contains('shell_job_registry')));
        }
      }
      expect(messages, hasLength(3));
    },
  );

  test(
    'structured projection: custom records stay inert beside folds',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final u1 = await session.appendMessage(UserMessage.text('one'));
      final a1 = await session.appendMessage(
        AssistantMessage(
          content: [TextContent(text: 'working')],
          api: 'openai-completions',
          provider: 'copilot',
          model: 'gemini-4-argon',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
      await session.appendCustomEntry(
        customType: 'model_request_summary',
        data: requestSummaryPayload(),
      );
      await session.appendCustomEntry(
        customType: 'shell_job_registry',
        data: shellJobRegistryPayload(),
      );
      // A structured fold on the path — flips the projection onto
      // `renderStructuredMessages`.
      await session.appendHiddenRange(recordIds: [u1, a1]);
      await session.appendMessage(UserMessage.text('continue'));
      await session.appendCustomEntry(
        customType: 'model_request_summary',
        data: requestSummaryPayload(),
      );

      final messages = await session.buildContextMessages();

      for (final message in messages) {
        final text = message is UserMessage
            ? userMessageText(message.content)
            : '';
        expect(text, isNot(contains('model_request_summary')));
        expect(text, isNot(contains('systemPromptChars')));
        expect(text, isNot(contains('shell_job_registry')));
      }
      // The folded-away records do not re-render; a hidden-range marker and
      // the tail message do (marker text renders as a user-role line).
      expect(messages.map((m) => m.role), everyElement('user'));
      expect(
        messages.map((m) => userMessageText((m as UserMessage).content)),
        contains(contains('continue')),
      );
    },
  );

  test('projectPath: custom records inert on an explicit view path', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('hello'));
    await session.appendCustomEntry(
      customType: 'model_request_summary',
      data: requestSummaryPayload(),
    );
    final entries = await session.getEntries();
    final messages = session.projectPath(entries);
    expect(messages.map((m) => m.role), ['user']);
    expect(userMessageText((messages.single as UserMessage).content), 'hello');
  });

  test(
    'the gh-2423 seam: custom_message records DO project (by design)',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendCustomMessageEntry(
        customType: 'checkpoint',
        content: 'checkpoint saved',
        display: true,
      );
      final messages = await session.buildContextMessages();
      expect(messages, hasLength(1));
      expect(
        userMessageText((messages.single as UserMessage).content),
        contains('checkpoint saved'),
      );
    },
  );
}
