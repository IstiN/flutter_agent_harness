// Pins the chat-surface handler binder: any surface that renders its own
// transcript (the extension panel's SessionChatSheet — NOT FaChatScreen)
// must install the interactive handler trio (approval dialog, ask sheet,
// secret-request sheet) for as long as it is showing, and must clear
// exactly the handlers IT installed on detach.
//
// Regression context: the extension panel chatted through a surface that
// never installed approvalPromptHandler, so the relay logged "approval
// has no handler", the SW stalled 120s per gated tool call and denied —
// the user saw a busy badge and no output, with no dialog to answer.
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show ApprovalDecision, ApprovalRequest;
import 'package:flutter_test/flutter_test.dart';

import 'fake_chat_service.dart';

void main() {
  testWidgets('attach installs the trio; detach clears exactly it', (
    tester,
  ) async {
    final service = FakeChatService();
    late FaChatSurfaceHandlers handlers;

    await tester.pumpWidget(
      Builder(
        builder: (context) {
          handlers = FaChatSurfaceHandlers(context: context);
          handlers.attach(service);
          return const SizedBox.shrink();
        },
      ),
    );

    expect(service.approvalPromptHandler, isNotNull);
    expect(service.askHandler, isNotNull);
    expect(service.secretRequestHandler, isNotNull);

    handlers.detach();

    expect(service.approvalPromptHandler, isNull);
    expect(service.askHandler, isNull);
    expect(service.secretRequestHandler, isNull);
  });

  testWidgets('detach never clears a foreign handler', (tester) async {
    final service = FakeChatService();
    Future<ApprovalDecision> foreign(ApprovalRequest request) async =>
        throw UnimplementedError();
    service.approvalPromptHandler = foreign;

    late FaChatSurfaceHandlers handlers;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          handlers = FaChatSurfaceHandlers(context: context);
          handlers.attach(service);
          return const SizedBox.shrink();
        },
      ),
    );
    // attach() must not clobber the existing approval handler.
    expect(service.approvalPromptHandler, same(foreign));

    handlers.detach();
    expect(service.approvalPromptHandler, same(foreign));
    expect(service.askHandler, isNull);
    expect(service.secretRequestHandler, isNull);
  });

  testWidgets('rebinding to a new service moves the trio', (tester) async {
    final first = FakeChatService();
    final second = FakeChatService();
    late FaChatSurfaceHandlers handlers;

    await tester.pumpWidget(
      Builder(
        builder: (context) {
          handlers = FaChatSurfaceHandlers(context: context);
          return const SizedBox.shrink();
        },
      ),
    );
    handlers.attach(first);
    handlers.attach(second);

    expect(first.approvalPromptHandler, isNull);
    expect(second.approvalPromptHandler, isNotNull);
    handlers.detach();
    expect(second.approvalPromptHandler, isNull);
  });

  test('detaching twice is a no-op', () {
    final handlers = FaChatSurfaceHandlers(context: _FakeContext());
    handlers.detach();
    handlers.detach();
  });
}

class _FakeContext extends Fake implements BuildContext {}
