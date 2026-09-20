// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The in-app App Store Get banner (issue #691 AC4): renders from the
/// `links:` config section (one change in the config flips it — AC1),
/// dismissal persists through the sandbox-root store, taps emit the
/// store-referral analytics event with placement + platform (AC5), and
/// `links.banner: false` mounts nothing (AC7 regression switch).
library;

import 'package:fa/services/analytics.dart';
import 'package:fa/services/links_loader.dart';
import 'package:fa/services/store_banner_store.dart';
import 'package:fa/ui/widgets/store_get_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Events recorded through the analytics test sink.
  final events = <(String, Map<String, Object>)>[];

  setUp(() {
    events.clear();
    AppAnalytics.install((name, params) => events.add((name, params)));
  });

  tearDown(() => AppAnalytics.install(null));

  Future<void> pump(
    WidgetTester tester, {
    required ExecutionEnv env,
    AppLinksResolution? links,
    bool showOnPlatform = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StoreGetBanner(
            env: env,
            links: links,
            showOnPlatform: showOnPlatform,
            platformLabel: 'macos',
          ),
        ),
      ),
    ),
  );

  testWidgets('renders the paid/beta copy and the coming-soon Android slot', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await pump(
      tester,
      env: env,
      links: const AppLinksResolution(LinksConfig(), []),
    );
    await tester.pumpAndSettle();
    expect(find.byType(StoreGetBanner), findsOneWidget);
    expect(find.text('Get Fa on the App Store'), findsOneWidget);
    expect(find.textContaining('paid — it funds development'), findsOneWidget);
    expect(find.textContaining('free forever'), findsOneWidget);
    expect(find.textContaining('Android: coming soon'), findsOneWidget);
    expect(find.text('Open the App Store'), findsOneWidget);
  });

  testWidgets('a flipped links config flips the banner copy (AC1)', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    const flipped = LinksConfig(
      appstore: 'https://apps.apple.com/us/app/fa/id999',
      testflight: 'https://testflight.apple.com/join/ZZ',
      play: 'https://play.google.com/store/apps/details?id=dev.fa1.app',
    );
    await pump(tester, env: env, links: const AppLinksResolution(flipped, []));
    await tester.pumpAndSettle();
    expect(find.textContaining('coming soon'), findsNothing);
    expect(find.textContaining('Also on Google Play'), findsOneWidget);
    // The URL itself is carried by StoreBannerView.from(links) — pinned
    // end to end in the core test (test/cli/links_config_test.dart).
  });

  testWidgets('links.banner false mounts nothing (AC7 regression switch)', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    const off = LinksConfig(banner: false);
    await pump(tester, env: env, links: const AppLinksResolution(off, []));
    await tester.pumpAndSettle();
    expect(find.byType(StoreGetBanner), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a platform without the banner mounts nothing', (tester) async {
    final env = MemoryExecutionEnv();
    await pump(
      tester,
      env: env,
      links: const AppLinksResolution(LinksConfig(), []),
      showOnPlatform: false,
    );
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNothing);
  });

  testWidgets(
    'the CTA taps emit the store-referral event with the target split (AC5)',
    (tester) async {
      final env = MemoryExecutionEnv();
      await pump(
        tester,
        env: env,
        links: const AppLinksResolution(LinksConfig(), []),
      );
      await tester.pumpAndSettle();
      // Paid release tap and free-beta tap must be distinguishable in the
      // funnel — the same event name, split by `target` (AC5).
      await tester.tap(find.text('Open the App Store'));
      await tester.pump();
      await tester.tap(find.text('or join the free TestFlight beta'));
      await tester.pump();
      final referral = events.where((e) => e.$1 == 'store_referral').toList();
      expect(referral, hasLength(2), reason: 'one event per button');
      expect(referral[0].$2['placement'], 'get_banner');
      expect(referral[0].$2['platform'], 'macos');
      expect(referral[0].$2['target'], 'appstore', reason: 'the paid CTA');
      expect(referral[1].$2['placement'], 'get_banner');
      expect(referral[1].$2['platform'], 'macos');
      expect(referral[1].$2['target'], 'testflight', reason: 'the free beta');
    },
  );

  testWidgets('dismissal hides the banner and persists across restarts', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await pump(
      tester,
      env: env,
      links: const AppLinksResolution(LinksConfig(), []),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hide banner'));
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNothing);
    final dismissed = events
        .where((e) => e.$1 == 'store_banner_dismissed')
        .toList();
    expect(dismissed, hasLength(1));
    expect(dismissed.first.$2['platform'], 'macos');

    // A NEW widget over the SAME sandbox (a restart) stays dismissed.
    await pump(
      tester,
      env: env,
      links: const AppLinksResolution(LinksConfig(), []),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNothing);
    expect(await StoreBannerStore(env).loadDismissed(), isTrue);
  });

  testWidgets('a stale/foreign dismissal file never crashes the banner', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    await env.writeFile('${env.cwd}/store_banner.json', 'not json');
    await pump(
      tester,
      env: env,
      links: const AppLinksResolution(LinksConfig(), []),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsOneWidget);
  });
}
