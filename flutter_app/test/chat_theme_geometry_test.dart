// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa_ui/fa_ui.dart' as fa_ui;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AgentService _service(ExecutionEnv env) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'test',
      streamFunction: (model, context, {cancelToken}) =>
          AssistantMessageEventStream()..end(),
      toolRegistry: ToolRegistry(const []),
    ),
    watchExternalSessions: false,
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required FlutterSessionManager manager,
  required fa_ui.FaVisualDirection direction,
  required Brightness brightness,
  required double width,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 700);
  await tester.pumpWidget(
    MaterialApp(
      theme: fa_ui.buildFaTheme(direction: direction, brightness: brightness),
      home: ChatScreen(
        manager: manager,
        sessionTitle: 'Release review',
        projectLabel: 'fa_network',
        onProjectTap: () {},
        modelChip: const Text('test-model'),
        chipMenuLabel: 'test-model',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectRect(Rect actual, Rect expected, String reason) {
  expect(actual.left, closeTo(expected.left, .001), reason: reason);
  expect(actual.top, closeTo(expected.top, .001), reason: reason);
  expect(actual.right, closeTo(expected.right, .001), reason: reason);
  expect(actual.bottom, closeTo(expected.bottom, .001), reason: reason);
}

void main() {
  testWidgets('header and composer geometry is invariant across every theme', (
    tester,
  ) async {
    fa_ui.debugFaGlassAlwaysFake = true;
    addTearDown(() => fa_ui.debugFaGlassAlwaysFake = false);
    addTearDown(tester.view.reset);

    for (final width in <double>[900, 1100, 600]) {
      final env = MemoryExecutionEnv();
      final service = _service(env);
      addTearDown(service.dispose);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('session-$width', service);
      final wide = width >= fa_ui.kWideLayoutBreakpoint;
      final keys = <String>[
        'faChatFloatingHeader',
        if (wide) ...['faChatHeaderAvatar', 'faChatHeaderTitlePill'],
        'faChatTranscriptList',
        'faChatFloatingComposer',
        'faChatComposerFieldRow',
      ];
      Map<String, Rect>? baseline;

      for (final direction in fa_ui.FaVisualDirection.values) {
        for (final brightness in Brightness.values) {
          await _pumpChat(
            tester,
            manager: manager,
            direction: direction,
            brightness: brightness,
            width: width,
          );
          final reason = '$width $direction $brightness';
          final current = <String, Rect>{
            for (final key in keys)
              key: tester.getRect(find.byKey(ValueKey(key))),
          };
          if (wide) {
            final copy = find.byIcon(Icons.copy_outlined);
            final actionFinder = find
                .ancestor(
                  of: copy,
                  matching: find.byType(fa_ui.FaHeaderCircularAction),
                )
                .first;
            current['copyAction'] = tester.getRect(actionFinder);
            final material = tester.widget<Material>(
              find
                  .descendant(of: actionFinder, matching: find.byType(Material))
                  .first,
            );
            expect(
              material.color,
              fa_ui.FaDesignTokens.of(tester.element(copy)).surface2,
              reason: reason,
            );
            expect(material.shape, isA<CircleBorder>(), reason: reason);
            expect(
              (material.shape! as CircleBorder).side,
              BorderSide.none,
              reason: reason,
            );
            final copyRect = current['copyAction']!;
            expect(copyRect.width, 40, reason: reason);
            expect(copyRect.height, copyRect.width, reason: reason);
            expect(tester.widget<Icon>(copy).size, 18, reason: reason);
            final timeline = find.byIcon(Icons.timeline);
            if (timeline.evaluate().isNotEmpty) {
              final timelineAction = find
                  .ancestor(
                    of: timeline,
                    matching: find.byType(fa_ui.FaHeaderCircularAction),
                  )
                  .first;
              expect(
                copyRect.left - tester.getRect(timelineAction).right,
                8,
                reason: reason,
              );
            }
            expect(
              tester
                  .getCenter(find.byKey(const ValueKey('faChatHeaderAvatar')))
                  .dx,
              closeTo(width / 2, .001),
              reason: reason,
            );
            expect(
              tester
                  .getCenter(
                    find.byKey(const ValueKey('faChatHeaderTitlePill')),
                  )
                  .dx,
              closeTo(width / 2, .001),
              reason: reason,
            );
            expect(copyRect.left, greaterThan(width / 2), reason: reason);
            expect(copyRect.right, lessThanOrEqualTo(width), reason: reason);
            expect(find.text('test-model'), findsOneWidget, reason: reason);
            final overflow = find.byKey(const ValueKey('faChatHeaderOverflow'));
            final hasOverflow = overflow.evaluate().isNotEmpty;
            current['overflow'] = hasOverflow
                ? tester.getRect(overflow)
                : Rect.zero;
            if (hasOverflow) {
              expect(
                tester.widget<IconButton>(overflow).onPressed,
                isNotNull,
                reason: reason,
              );
            }
          } else {
            final copy = find.byIcon(Icons.copy_outlined);
            current['narrowCopy'] = copy.evaluate().isEmpty
                ? Rect.zero
                : tester.getRect(copy);
            if (copy.evaluate().isNotEmpty) {
              final copyAction = find
                  .ancestor(
                    of: copy,
                    matching: find.byType(fa_ui.FaHeaderCircularAction),
                  )
                  .first;
              expect(
                tester.getSize(copyAction),
                const Size.square(40),
                reason: reason,
              );
              expect(tester.widget<Icon>(copy).size, 18, reason: reason);
              final folder = find.byTooltip('Files');
              if (folder.evaluate().isNotEmpty) {
                final folderAction = find
                    .ancestor(
                      of: folder,
                      matching: find.byType(fa_ui.FaHeaderCircularAction),
                    )
                    .first;
                expect(
                  tester.getRect(copyAction).left -
                      tester.getRect(folderAction).right,
                  8,
                  reason: reason,
                );
              }
            }
            final overflow = find.byKey(const ValueKey('faChatHeaderOverflow'));
            final hasOverflow = overflow.evaluate().isNotEmpty;
            current['narrowOverflow'] = hasOverflow
                ? tester.getRect(overflow)
                : Rect.zero;
            if (hasOverflow) {
              expect(
                tester.widget<IconButton>(overflow).onPressed,
                isNotNull,
                reason: reason,
              );
            }
          }
          expect(find.text('fa_network'), findsOneWidget, reason: reason);
          expect(find.text('Release review'), findsOneWidget, reason: reason);
          expect(find.text('Fa'), findsNothing, reason: reason);

          if (baseline == null) {
            baseline = current;
          } else {
            for (final key in keys) {
              _expectRect(current[key]!, baseline[key]!, '$reason: $key');
            }
            if (wide) {
              _expectRect(
                current['copyAction']!,
                baseline['copyAction']!,
                '$reason: circular action',
              );
              _expectRect(
                current['overflow']!,
                baseline['overflow']!,
                '$reason: adaptive overflow decision and geometry',
              );
            } else {
              _expectRect(
                current['narrowCopy']!,
                baseline['narrowCopy']!,
                '$reason: adaptive inline copy action',
              );
              _expectRect(
                current['narrowOverflow']!,
                baseline['narrowOverflow']!,
                '$reason: adaptive narrow overflow decision and geometry',
              );
            }
          }
        }
      }
    }
  });

  testWidgets(
    'composer floats inside safe-area plus 8 with a 40px single-line row',
    (tester) async {
      fa_ui.debugFaGlassAlwaysFake = true;
      addTearDown(() => fa_ui.debugFaGlassAlwaysFake = false);
      addTearDown(tester.view.reset);
      tester.view.padding = const FakeViewPadding(bottom: 24);
      tester.view.viewInsets = const FakeViewPadding();

      final env = MemoryExecutionEnv();
      final service = _service(env);
      addTearDown(service.dispose);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('composer-session', service);

      for (final width in <double>[1100, 600]) {
        for (final direction in fa_ui.FaVisualDirection.values) {
          await _pumpChat(
            tester,
            manager: manager,
            direction: direction,
            brightness: Brightness.dark,
            width: width,
          );
          final reason = '$width $direction';
          final composer = tester.getRect(
            find.byKey(const ValueKey('faChatFloatingComposer')),
          );
          final fieldRow = tester.getRect(
            find.byKey(const ValueKey('faChatComposerFieldRow')),
          );
          final send = tester.getRect(
            find.byKey(const ValueKey('faChatComposerSendButton')),
          );
          final fade = tester.getRect(
            find.byKey(const ValueKey('faChatBottomEnvironmentFade')),
          );
          expect(composer.left, 8, reason: reason);
          expect(composer.right, width - 8, reason: reason);
          expect(composer.bottom, 700 - 24 - 8, reason: reason);
          expect(composer.height, 40, reason: reason);
          expect(fieldRow.height, 40, reason: reason);
          expect(
            fieldRow.bottom,
            closeTo(composer.bottom, .001),
            reason: reason,
          );
          expect(send.size, const Size.square(36), reason: reason);
          expect(fade.left, 0, reason: reason);
          expect(fade.right, width, reason: reason);
          expect(fade.bottom, 700, reason: reason);
          expect(fade.top, lessThan(composer.top), reason: reason);
          expect(fade.bottom, greaterThan(composer.bottom), reason: reason);
          expect(
            send.left,
            greaterThanOrEqualTo(composer.left),
            reason: reason,
          );
          expect(send.right, lessThanOrEqualTo(composer.right), reason: reason);
          expect(send.top, greaterThanOrEqualTo(composer.top), reason: reason);
          expect(
            send.bottom,
            lessThanOrEqualTo(fieldRow.bottom),
            reason: reason,
          );

          final field = tester.widget<TextField>(
            find.byKey(const ValueKey('faChatComposerTextField')),
          );
          final decoration = field.decoration!;
          expect(decoration.filled, isFalse, reason: reason);
          expect(decoration.fillColor, Colors.transparent, reason: reason);
          for (final border in <InputBorder?>[
            decoration.border,
            decoration.enabledBorder,
            decoration.focusedBorder,
            decoration.disabledBorder,
            decoration.errorBorder,
            decoration.focusedErrorBorder,
          ]) {
            expect(border, InputBorder.none, reason: reason);
          }
          expect(
            find.ancestor(
              of: find.byKey(const ValueKey('faChatComposerTextField')),
              matching: find.byType(fa_ui.FaSurface),
            ),
            findsOneWidget,
            reason: reason,
          );
          expect(tester.takeException(), isNull, reason: reason);
        }
      }
    },
  );
}
