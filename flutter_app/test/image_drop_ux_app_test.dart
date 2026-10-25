// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #1889 AC5 — the app surface of the aggregated image-cap drop
/// notices: two consecutive capped turns produce ONE chat chip, the
/// debug log keeps every per-request per-image event, and the details
/// panel renders the shared projection.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/ui/widgets/image_drop_notice_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

ImageDropReport _cappedTurnReport() => ImageDropReport(
  // Two consecutive capped turns drop the SAME 17 history images of
  // a 37-image window (the yoclip flood shape).
  drops: [
    for (var i = 0; i < 17; i++)
      ImageDropEvent(index: i, key: 'content-00$i', fromCurrentMessage: false),
  ],
  cap: 20,
  modelId: 'test-model',
  currentImageCount: 0,
  registryCount: 37,
  ridingCount: 20,
);

void main() {
  setUp(AppLog.reset);

  AgentService _liveService({bool registerTearDown = true}) {
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
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          stream.end();
          return stream;
        },
        toolRegistry: ToolRegistry(const []),
      ),
      watchExternalSessions: false,
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
      config: AgentConfig(
        providerKind: 'test',
        modelId: 'test-model',
        baseUrl: 'https://example.com',
        apiKey: '',
      ),
    );
    if (registerTearDown) addTearDown(service.dispose);
    return service;
  }

  AgentService anyService() => _liveService();

  test('dispose disarms the process-wide reporter + the notifier '
      '(#1891 review round 1)', () async {
    final stale = _liveService(registerTearDown: false);
    await stale.initialize();
    expect(imageDropReportNotice, isNotNull);
    imageDropReportNotice!(_cappedTurnReport());
    expect(stale.chatImageNotice.value, isNotNull);

    // A later service re-arms; the STALE service's dispose (its arming
    // is no longer current) must never clobber the newer arming.
    // Single-dispose contract: `current` is torn down manually here and
    // never via addTearDown.
    final current = _liveService(registerTearDown: false);
    await current.initialize();
    expect(imageDropReportNotice, isNotNull);
    stale.dispose();
    expect(
      imageDropReportNotice,
      isNotNull,
      reason: 'the current service keeps the seam armed',
    );

    // The current service's dispose disarms OUR closure.
    current.dispose();
    expect(imageDropReportNotice, isNull, reason: 'our arming was disarmed');
  });

  test(
    'two capped turns ⇒ one chip notice; AppLog keeps both requests',
    () async {
      final service = anyService();
      await service.initialize();
      expect(imageDropReportNotice, isNotNull);

      // Turn 1: capped → the chip appears with the aggregated line.
      imageDropReportNotice!(_cappedTurnReport());
      expect(service.chatImageNotice.value, isNotNull);
      expect(
        service.chatImageNotice.value!.line,
        contains('17 older images not sent this turn'),
      );

      // Turn 2: the SAME dropped set ⇒ the latch stays silent — still the
      // ONE notice, never a second.
      imageDropReportNotice!(_cappedTurnReport());
      expect(service.chatImageNotice.value, isNotNull);

      // The debug surface never went silent: both requests logged their
      // full per-image detail (the 8-hex key previews ride along).
      final log = AppLog.dump();
      expect(log, contains('[Image 0]'));
      expect(log, contains('(content-…'));
      expect('per-request cap reached'.allMatches(log), hasLength(34));
    },
  );

  test('a changed dropped set updates the chip; recovery clears it', () async {
    final service = anyService();
    await service.initialize();

    imageDropReportNotice!(_cappedTurnReport());
    final first = service.chatImageNotice.value!;

    // Turn 2 drops ONE more image: a new situation → the chip updates.
    imageDropReportNotice!(
      ImageDropReport(
        drops: [
          for (var i = 0; i < 18; i++)
            ImageDropEvent(
              index: i,
              key: 'content-00$i',
              fromCurrentMessage: false,
            ),
        ],
        cap: 20,
        modelId: 'test-model',
        currentImageCount: 0,
        registryCount: 38,
        ridingCount: 20,
      ),
    );
    final second = service.chatImageNotice.value!;
    expect(second.line, isNot(equals(first.line)));
    expect(second.line, contains('18 older images'));

    // Recovery (cap raised / images aged out): one all-clear transition.
    imageDropReportNotice!(
      ImageDropReport(
        drops: const [],
        cap: 20,
        modelId: 'test-model',
        currentImageCount: 0,
        registryCount: 20,
        ridingCount: 20,
      ),
    );
    expect(service.chatImageNotice.value!.line, contains('caught up'));
  });

  /// A history-drop notice produced the honest way — through the shared
  /// latch — so tests never fabricate [ImageDropNoticeView]s.
  ImageDropNoticeView historyNotice({int drops = 17}) {
    final view = ImageDropUx().observe(
      ImageDropReport(
        drops: [
          for (var i = 0; i < drops; i++)
            ImageDropEvent(
              index: i,
              key: 'content-00$i',
              fromCurrentMessage: false,
            ),
        ],
        cap: 20,
        modelId: 'test-model',
        currentImageCount: 0,
        registryCount: 20 + drops,
        ridingCount: 20,
      ),
    );
    return view!;
  }

  testWidgets('the chip renders the low-key history variant and dismisses', (
    tester,
  ) async {
    final notice = historyNotice();
    expect(notice.prominent, isFalse);
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImageDropNoticeChip(
            notice: notice,
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );
    expect(find.textContaining('17 older images not sent'), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsNothing);
    await tester.tap(find.byIcon(Icons.close));
    expect(dismissed, isTrue);
  });

  testWidgets('the prominent current-batch variant renders the warning icon', (
    tester,
  ) async {
    final view = ImageDropUx().observe(
      ImageDropReport(
        drops: [
          for (var i = 0; i < 5; i++)
            ImageDropEvent(
              index: i,
              key: 'attach-00$i',
              fromCurrentMessage: true,
            ),
        ],
        cap: 20,
        modelId: 'test-model',
        currentImageCount: 25,
        registryCount: 25,
        ridingCount: 20,
      ),
    )!;
    expect(view.prominent, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ImageDropNoticeChip(notice: view)),
      ),
    );
    expect(find.textContaining('5 of 25 attached images'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
  });

  testWidgets('the panel renders the shared projection lines', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showImageDropPanel(
                  context,
                  lines: imageSurfaceLines(
                    lastReport: _cappedTurnReport(),
                    config: const ImageRegistryConfig(),
                    modelId: 'test-model',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('37 in the window, 20 sent, 17 not sent'),
      findsOneWidget,
    );
    // The 17 dropped-image rows push the cap + knobs lines below the
    // sheet's fold — scroll before asserting them.
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('cap: 20 per request for test-model'),
      findsOneWidget,
    );
    expect(find.textContaining('images.registry: false'), findsOneWidget);
  });
}
