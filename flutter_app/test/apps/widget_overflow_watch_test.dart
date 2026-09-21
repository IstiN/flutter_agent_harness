import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/widget_overflow_watch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WidgetOverflowWatch (issue #692 C)', () {
    testWidgets('a subtree wider than the viewport reports the overflow', (
      tester,
    ) async {
      final reports = <(double, double)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 300,
              height: 60,
              child: WidgetOverflowWatch(
                onOverflow: (px, width) => reports.add((px, width)),
                // The classic clipped card shape: fixed-width content
                // wider than the canvas, clipped by an ancestor (a Stack
                // clips like the tile border does) — no RenderFlex
                // exception, just silent clipping, which is the bug this
                // watcher exists to catch.
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    const Positioned(
                      left: 0,
                      top: 0,
                      child: SizedBox(width: 760, height: 40),
                    ),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(width: 100, height: 8),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(reports, isNotEmpty);
      expect(reports.first.$2, 300);
      expect(reports.first.$1, greaterThan(400));
    });

    testWidgets('a fitting subtree stays silent', (tester) async {
      var fired = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              child: WidgetOverflowWatch(
                onOverflow: (px, width) => fired++,
                child: const ColoredBox(
                  color: Colors.red,
                  child: SizedBox(width: 300, height: 40),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(fired, 0);
    });

    testWidgets('content inside a nested horizontal scrollable is not an '
        'overflow of this viewport', (tester) async {
      var fired = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              child: WidgetOverflowWatch(
                onOverflow: (px, width) => fired++,
                // A carousel scrolling its own content — intentional width.
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < 6; i++)
                        const SizedBox(width: 200, height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(fired, 0);
    });
  });

  group('DynamicMessagesService.noteViewportOverflow (issue #692 C)', () {
    DynamicMessageDefinition def() => DynamicMessageDefinition(
      id: 'w1',
      title: 'Productivity card',
      jsSource: 'jsr.render({type:"text",data:"x"});',
      createdAt: DateTime(2026, 9, 19),
    );

    DynamicMessagesService service(void Function(String text) onSend) =>
        DynamicMessagesService(
          env: MemoryExecutionEnv(),
          sendText: (text) async => onSend(text),
          sessionIdOf: () => 's1',
          sessionFileOf: () => 'sessions/s1.json',
          mediaGatewayOf: () => null,
          videoReaderOf: () => null,
          hostSecretsOf: () => const {},
          llmHandlerOf: () => null,
          asrTranscriberOf: () async => null,
        );

    test(
      'fires ONE note per widget id and marks it for the tile strip',
      () async {
        final sent = <String>[];
        final svc = service(sent.add);
        // A presented widget lands in the session's definition list.
        await svc.present(
          DynamicMessageRequest(title: def().title, jsSource: def().jsSource),
        );
        final definition = svc.widgets.single;
        svc.noteViewportOverflow(definition, 96, 393);
        svc.noteViewportOverflow(definition, 120, 393);
        svc.noteViewportOverflow(definition, 40, 393);

        expect(sent, hasLength(1));
        expect(sent.single, contains('[widget Productivity card]'));
        expect(sent.single, contains('viewport-overflow'));
        expect(sent.single, contains('"overflowPx":96'));
        expect(sent.single, contains('"viewportWidth":393'));
        expect(svc.overflowNotedFor(definition.id), isTrue);
        expect(svc.overflowNotedFor('other'), isFalse);
        svc.dispose();
      },
    );

    test(
      'a failed note does NOT burn the one-shot (rolled back, review fix)',
      () async {
        var calls = 0;
        final sent = <String>[];
        final svc = service((text) {
          calls++;
          if (calls == 1) throw StateError('session gone');
          sent.add(text);
        });
        await svc.present(
          DynamicMessageRequest(title: def().title, jsSource: def().jsSource),
        );
        final definition = svc.widgets.single;

        // The back-channel rejects: the agent was never told, so the
        // one-shot must roll back and the tile strip must drop.
        svc.noteViewportOverflow(definition, 96, 393);
        await Future<void>.delayed(Duration.zero);
        expect(svc.overflowNotedFor(definition.id), isFalse);

        // A later report of the same widget still reaches the agent.
        svc.noteViewportOverflow(definition, 96, 393);
        await Future<void>.delayed(Duration.zero);
        expect(sent, hasLength(1));
        expect(svc.overflowNotedFor(definition.id), isTrue);
        svc.dispose();
      },
    );
  });
}
