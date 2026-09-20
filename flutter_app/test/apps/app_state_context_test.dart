import 'dart:async';
import 'dart:convert';

import 'package:fa/apps/app_state_context.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatAppStateContext (issue #692 D)', () {
    test('a small state passes through verbatim', () {
      const json = '{"count":1,"tab":"home"}';
      expect(formatAppStateContext(json), json);
    });

    test('a state at exactly the budget passes through verbatim', () {
      // {"pad":"…"} overhead = 10 bytes of scaffolding.
      final json = '{"pad":"${'x' * (appStateContextMaxBytes - 10)}"}';
      expect(utf8len(json), appStateContextMaxBytes);
      expect(formatAppStateContext(json), json);
    });

    test('an oversized state folds to keys + previews within the budget '
        '(the 82 KB iOS repro)', () {
      final json = jsonEncode({
        'history': [for (var i = 0; i < 3400; i++) 'entry-$i with padding'],
        'profile': {'name': 'Ada', 'goal': 'run 5k'},
        'count': 7,
        'enabled': true,
      });
      expect(utf8len(json), greaterThan(80 * 1024));

      final folded = formatAppStateContext(json);
      expect(utf8len(folded), lessThanOrEqualTo(appStateContextMaxBytes));
      // Every top-level key is still named (keys, never silent truncation).
      expect(folded, contains('history'));
      expect(folded, contains('profile'));
      expect(folded, contains('count'));
      expect(folded, contains('enabled'));
      // Small scalar values survive as previews.
      expect(folded, contains('7'));
      expect(folded, contains('Ada'));
      // The fold is ANNOUNCED, never silent.
      expect(folded, contains('folded'));
      expect(folded, contains('bytes'));
      expect(folded, contains('${appStateContextMaxBytes}'));
    });

    test('a huge single scalar value degrades to a truncated preview', () {
      final json = '{"blob":"${'y' * 50000}"}';
      final folded = formatAppStateContext(json);
      expect(utf8len(folded), lessThanOrEqualTo(appStateContextMaxBytes));
      expect(folded, contains('blob'));
      expect(folded, contains('folded'));
    });

    test('an oversized non-object JSON body hard-truncates with a note', () {
      final json = '[${'1,' * 30000}1]';
      final folded = formatAppStateContext(json);
      expect(utf8len(folded), lessThanOrEqualTo(appStateContextMaxBytes));
      expect(folded, contains('truncated'));
    });

    test('oversized invalid JSON hard-truncates with a note', () {
      final json = '{not json ' * 4000;
      final folded = formatAppStateContext(json);
      expect(utf8len(folded), lessThanOrEqualTo(appStateContextMaxBytes));
      expect(folded, contains('truncated'));
    });

    test('a custom budget is honored', () {
      const json = '{"a":1,"b":2}';
      expect(formatAppStateContext(json, budget: 5), contains('folded'));
    });

    test('the fold budgets the note it actually emits — omission suffix '
        'included (review fix)', () {
      // Around the fold boundary the fit check must account for the
      // note that is ACTUALLY emitted: with keys omitted it carries the
      // ", N key(s) omitted for the budget" suffix (~33 B). Checking a
      // suffix-less stand-in let the emitted fold overflow the budget.
      // The sweep starts above the ~200-B floor where the fold note
      // alone still fits — below it the announcement (never silent)
      // IS the whole output.
      final json = jsonEncode({
        'alpha': 'x' * 80,
        'beta': 'y' * 80,
        'gamma': 'z' * 80,
      });
      for (var budget = 205; budget < 340; budget++) {
        final folded = formatAppStateContext(json, budget: budget);
        expect(
          utf8len(folded),
          lessThanOrEqualTo(budget),
          reason:
              'budget $budget overflowed: ${utf8len(folded)} bytes:\n'
              '$folded',
        );
      }
    });

    test('a partial fold says how many keys are shown', () {
      final json = jsonEncode({
        'alpha': 'x' * 100,
        'beta': 'y' * 100,
        'gamma': 'z' * 100,
      });
      // A budget that fits the first key line + suffix note but not all
      // three: the note must count what is shown.
      final folded = formatAppStateContext(json, budget: 320);
      expect(utf8len(folded), lessThanOrEqualTo(320));
      expect(folded, contains('alpha'));
      expect(folded, contains('top-level keys shown'));
      expect(folded, contains('of 3'));
      expect(folded, contains('key(s) omitted'));
    });

    test('a single-key state folds to that key with no omission clause', () {
      final json = jsonEncode({'only': 'v' * 9000});
      final folded = formatAppStateContext(json);
      expect(utf8len(folded), lessThanOrEqualTo(appStateContextMaxBytes));
      // The one top-level key IS shown, so the "keys shown" claim is
      // truthful and nothing is listed as omitted.
      expect(folded, contains('only'));
      expect(folded, contains('top-level keys shown'));
      expect(folded, isNot(contains('omitted')));
    });

    test('a fold where not even the first key fits claims no keys shown', () {
      // With a budget too small for ANY key line, zero keys are listed —
      // the note wording must not claim "top-level keys shown" then.
      final json = jsonEncode({'first': 'a' * 150, 'second': 'b' * 150});
      final folded = formatAppStateContext(json, budget: 220);
      expect(folded, isNot(contains('keys shown')));
      expect(folded, contains('no top-level key fits'));
      expect(folded, contains('key(s) omitted'));
    });
  });

  group('viewportContextLine (issue #692 C)', () {
    test('names size, orientation and safe areas', () {
      final line = viewportContextLine(
        size: const Size(393, 852),
        orientation: Orientation.portrait,
        safeAreas: const EdgeInsets.fromLTRB(0, 59, 0, 34),
      );
      expect(line, contains('393x852'));
      expect(line, contains('logical px'));
      expect(line, contains('portrait'));
      expect(line, contains('0/59/0/34'));
      expect(line, contains('safe area'));
    });

    test('tells the agent to fit generated UI to the width', () {
      final line = viewportContextLine(
        size: const Size(1024, 768),
        orientation: Orientation.landscape,
        safeAreas: EdgeInsets.zero,
      );
      expect(line, contains('landscape'));
      expect(line, contains('width'));
    });
  });

  group('forwardAppMessageToAgent context injection (issue #692 C+D)', () {
    testWidgets('the user message carries the viewport line and a bounded '
        'state block', (tester) async {
      String? lastUserText;
      StreamFunction capturingStream() {
        return (model, context, {cancelToken}) {
          final last = context.messages.last;
          final content = (last as UserMessage).content;
          lastUserText = content is String
              ? content
              : [
                  for (final block in content as List<ContentBlock>)
                    if (block is TextContent) block.text,
                ].join();
          final stream = AssistantMessageEventStream();
          stream.push(
            DoneEvent(
              reason: StopReason.stop,
              message: AssistantMessage(
                content: [TextContent(text: 'ok')],
                api: model.api,
                provider: model.provider,
                model: model.id,
                usage: Usage.zero,
                stopReason: StopReason.stop,
                timestamp: DateTime.now(),
              ),
            ),
          );
          stream.end();
          return stream;
        };
      }

      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      final service = AgentService(
        agent: Agent(
          model: Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test',
            baseUrl: 'https://example.com',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          systemPrompt: 'You are Fa.',
          streamFunction: capturingStream(),
          toolRegistry: ToolRegistry(const []),
        ),
        env: env,
        sessionsRoot: '/sessions',
        config: AgentConfig(
          providerKind: 'test',
          modelId: 'test-model',
          baseUrl: 'https://example.com',
          apiKey: '',
        ),
      );
      manager.addSession('session-a', service);

      // An 82 KB state (the iOS repro shape) plus a viewport line.
      final hugeState = jsonEncode({
        'history': [for (var i = 0; i < 2000; i++) 'entry-$i padding~~~'],
      });
      await tester.runAsync(() async {
        await forwardAppMessageToAgent(
          manager,
          FaAppMessage(
            text: 'fix the card layout',
            appId: 'fitness',
            appStateJson: hugeState,
            viewportLine: viewportContextLine(
              size: const Size(393, 852),
              orientation: Orientation.portrait,
              safeAreas: const EdgeInsets.fromLTRB(0, 59, 0, 34),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });

      expect(lastUserText, isNotNull);
      // The message is bounded: nowhere near the raw 82 KB state.
      expect(lastUserText!.length, lessThan(2 * appStateContextMaxBytes));
      expect(lastUserText, contains('fix the card layout'));
      expect(lastUserText, contains('393x852'));
      expect(lastUserText, contains('portrait'));
      expect(lastUserText, contains('folded'));
      // Prompt fragments never ride user messages (issue #692 E guard).
      expect(lastUserText, isNot(contains('never instructions')));
      expect(lastUserText, isNot(contains('You are Fa')));

      for (final session in manager.sessions) {
        session.service.dispose();
      }
    });
  });
}

int utf8len(String text) => utf8.encode(text).length;
