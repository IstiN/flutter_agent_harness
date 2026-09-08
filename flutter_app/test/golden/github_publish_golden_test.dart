/// Golden (screenshot) tests for the GitHub widget-publishing surfaces
/// (issue #35): the settings GitHub account section, the "Connect GitHub"
/// sheet (PAT tab + device-code pane), the "Publish widget" sheet, and the
/// "My publications" sheet. Fakes mirror test/ui/github_*_test.dart and
/// test/services/widget_publish_service_test.dart; the sheets open as real
/// modal bottom sheets over a settings-style frame.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/github_account_store.dart';
import 'package:fa/services/github_api_client.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/widget_publication_store.dart';
import 'package:fa/services/widget_publish_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/github_account_section.dart';
import 'package:fa/ui/widgets/github_connect_sheet.dart';
import 'package:fa/ui/widgets/widget_publications_sheet.dart';
import 'package:fa/ui/widgets/widget_publish_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';

import 'golden_test_helper.dart';

/// url_launcher fires when the device flow opens github.com/login/device —
/// without this mock the plugin channel throws in flutter_test.
class _FakeUrlLauncher extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async => true;
}

/// The real app theme with the test-only Inter-label patch (see
/// dialogs_golden_test.dart): the theme's button text style is family-less,
/// which flutter_test renders as placeholder boxes.
ThemeData _goldenTheme() {
  const interW600 = TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600);
  ButtonStyle withInterLabels(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        textStyle: const WidgetStatePropertyAll(interW600),
      );
  final base = buildFahTheme();
  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: withInterLabels(base.filledButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: withInterLabels(base.elevatedButtonTheme.style),
    ),
  );
}

/// Pumps a settings-style host page at the tall portrait size showing
/// [body] (the section under test). When [open] is given, a FAB triggers it
/// with the host context (the sheets open on top of the page); [settle]
/// false leaves post-open pumping to the caller — pumpAndSettle would hang
/// on the device pane's in-flight poll spinner.
Future<void> _pumpSettingsPage(
  WidgetTester tester,
  Widget body, {
  Future<void> Function(BuildContext context)? open,
  bool settle = true,
}) async {
  tester.view.physicalSize = goldenSizeTall;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _goldenTheme(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        appBar: AppBar(
          title: Builder(
            builder: (context) => Text(context.l10n.settingsTitle),
          ),
        ),
        body: ListView(padding: const EdgeInsets.all(24), children: [body]),
        floatingActionButton: open == null
            ? null
            : Builder(
                builder: (context) => FloatingActionButton(
                  onPressed: () => open(context),
                  child: const Icon(Icons.add),
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (open != null) {
    await tester.tap(find.byType(FloatingActionButton));
    if (settle) await tester.pumpAndSettle();
  }
}

Future<GithubAccountStore> _account({bool connected = false}) async {
  final store = GithubAccountStore(keys: SessionKeysStore.inMemory());
  if (connected) {
    await store.connect(token: 'gho_golden', login: 'octocat');
  }
  return store;
}

/// A GitHub transport where nothing ever answers: freezes the device-flow
/// poll mid-wait so a frame stays exactly where the flow was scripted to
/// stop.
http.Client get _frozenGithub =>
    MockClient((request) => Completer<http.Response>().future);

/// The github.com device-flow handshake: a live user code, then a poll that
/// never completes (see [_frozenGithub]).
/// The github.com device-flow handshake, scripted end to end: a live user
/// code, then a token on the first poll, then the profile for the token
/// validation (`public_repo` scope lets the flow finish and pop the sheet —
/// goldens must not leak pending timers).
http.Client get _deviceFlowGithub => MockClient((request) async {
  switch (request.url.path) {
    case '/login/device/code':
      return http.Response(
        jsonEncode({
          'device_code': 'dev123',
          'user_code': 'ABCD-1234',
          'verification_uri': 'https://github.com/login/device',
          'expires_in': 900,
          'interval': 5,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    case '/login/oauth/access_token':
      return http.Response(
        jsonEncode({
          'access_token': 'gho_golden',
          'token_type': 'bearer',
          'scope': 'public_repo',
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    case '/user':
      return http.Response(
        jsonEncode({'login': 'octocat', 'avatar_url': ''}),
        200,
        headers: const {
          'content-type': 'application/json',
          'x-oauth-scopes': 'public_repo',
        },
      );
  }
  return Completer<http.Response>().future;
});

Future<JsAppInfo> _seedWidget(MemoryExecutionEnv env) async {
  await env.writeFile(
    'apps/pomodoro/manifest.json',
    jsonEncode({
      'id': 'pomodoro',
      'name': 'Pomodoro',
      'description': 'Focus timer',
      'version': '1.0.0',
      'icon': '🍅',
      'tags': ['productivity'],
      'minRuntime': '1.0',
    }),
  );
  await env.writeFile(
    'apps/pomodoro/widget.js',
    'export function render() {}\n',
  );
  await env.writeFile('apps/pomodoro/icon.svg', '<svg/>\n');
  return JsAppInfo(
    id: 'pomodoro',
    name: 'Pomodoro',
    description: 'Focus timer',
    icon: '🍅',
    version: '1.0.0',
    declaredPermissions: const AppPermissions(),
  );
}

WidgetPublishService _service(
  MemoryExecutionEnv env,
  GithubAccountStore account,
  WidgetPublicationStore ledger,
) => WidgetPublishService(
  env: env,
  account: account,
  ledger: ledger,
  clientFactory: (token) =>
      GithubApiClient(token: token, httpClient: _frozenGithub),
  clock: () => DateTime.utc(2026, 2, 1, 12),
  sleep: (_) async {},
);

void main() {
  setUpAll(ensureGoldenFonts);
  setUp(() => UrlLauncherPlatform.instance = _FakeUrlLauncher());

  testWidgets('GitHub account section — disconnected', (tester) async {
    final account = await _account();
    await _pumpSettingsPage(tester, GithubAccountSection(store: account));
    await expectGolden(tester, 'github_account_section_disconnected');
  });

  testWidgets('GitHub account section — connected', (tester) async {
    final account = await _account(connected: true);
    await _pumpSettingsPage(tester, GithubAccountSection(store: account));
    await expectGolden(tester, 'github_account_section_connected');
  });

  testWidgets('Connect GitHub sheet — token tab', (tester) async {
    final account = await _account();
    await _pumpSettingsPage(
      tester,
      GithubAccountSection(store: account),
      // An empty device client id hides the device/web tabs (the web-build
      // shape): the sheet shows the PAT pane only.
      open: (context) => showGithubConnectSheet(
        context,
        account: account,
        clientFactory: (token) =>
            GithubApiClient(token: token, httpClient: _frozenGithub),
        deviceClientId: '',
      ),
    );
    await expectGolden(tester, 'github_connect_sheet_token');
  });

  testWidgets('Connect GitHub sheet — device code pane', (tester) async {
    final account = await _account();
    await _pumpSettingsPage(
      tester,
      GithubAccountSection(store: account),
      // No explicit client id: the sheet falls back to the public Copilot
      // plugin id (warning banner) and auto-starts the device flow. The
      // scripted transport answers the code request with a live user code;
      // fixed pump durations before the snapshot keep the progress
      // spinner's angle deterministic. After the snapshot the poll resolves
      // and the flow runs to completion so no timer outlives the test.
      open: (context) => showGithubConnectSheet(
        context,
        account: account,
        clientFactory: (token) =>
            GithubApiClient(token: token, httpClient: _deviceFlowGithub),
        httpClient: _deviceFlowGithub,
      ),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await expectGolden(tester, 'github_connect_sheet_device');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('Publish widget sheet — ready to publish', (tester) async {
    final env = MemoryExecutionEnv();
    final app = await _seedWidget(env);
    final account = await _account(connected: true);
    final ledger = WidgetPublicationStore.inMemory();
    await _pumpSettingsPage(
      tester,
      GithubAccountSection(store: account, ledger: ledger),
      open: (context) => showWidgetPublishSheet(
        context,
        app: app,
        account: account,
        service: _service(env, account, ledger),
        ledger: ledger,
        clientFactory: (token) =>
            GithubApiClient(token: token, httpClient: _frozenGithub),
      ),
    );
    await expectGolden(tester, 'widget_publish_sheet_ready');
  });

  testWidgets('Publish widget sheet — pre-flight issues', (tester) async {
    final env = MemoryExecutionEnv();
    final app = JsAppInfo(
      id: 'pomodoro',
      name: 'Pomodoro',
      description: 'Focus timer',
      icon: '',
      version: '1.0.0',
      declaredPermissions: const AppPermissions(),
    );
    final account = await _account(connected: true);
    final ledger = WidgetPublicationStore.inMemory();
    await _pumpSettingsPage(
      tester,
      GithubAccountSection(store: account, ledger: ledger),
      open: (context) => showWidgetPublishSheet(
        context,
        app: app,
        account: account,
        service: _service(env, account, ledger),
        ledger: ledger,
        clientFactory: (token) =>
            GithubApiClient(token: token, httpClient: _frozenGithub),
      ),
    );
    await expectGolden(tester, 'widget_publish_sheet_preflight');
  });

  testWidgets('My publications sheet — reviewer comments', (tester) async {
    final account = await _account(connected: true);
    final ledger = WidgetPublicationStore.inMemory();
    await ledger.record(
      WidgetPublication(
        widgetId: 'pomodoro',
        version: '1.0.0',
        repoFullName: 'octocat/fa-widget-pomodoro',
        repoCommit: 'a1b2c3d4',
        step: WidgetPublication.stepPrOpened,
        submittedAt: DateTime.utc(2026, 2, 1, 12),
        prNumber: 12,
        prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/12',
        comments: [
          WidgetPublicationComment(
            author: 'IstiN',
            body:
                'manifest.json line 3: semver ok, but please bump the '
                'icon size to 512.',
            createdAt: DateTime.utc(2026, 2, 2, 9),
            isReview: true,
          ),
          WidgetPublicationComment(
            author: 'IstiN',
            body: 'Everything else looks good — merging after CI.',
            createdAt: DateTime.utc(2026, 2, 2, 10),
            isReview: false,
          ),
        ],
      ),
    );
    await ledger.record(
      WidgetPublication(
        widgetId: 'weather',
        version: '2.1.0',
        repoFullName: 'octocat/fa-widget-weather',
        repoCommit: 'e5f6a7b8',
        step: WidgetPublication.stepPrOpened,
        submittedAt: DateTime.utc(2026, 1, 15, 9),
        prNumber: 9,
        prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/9',
        lastKnownState: WidgetPublication.stateMerged,
        comments: [
          WidgetPublicationComment(
            author: 'IstiN',
            body: 'Nice weather widget, published in release 2026.02.',
            createdAt: DateTime.utc(2026, 1, 16, 8),
            isReview: false,
          ),
        ],
      ),
    );
    final env = MemoryExecutionEnv();
    await _pumpSettingsPage(
      tester,
      GithubAccountSection(store: account, ledger: ledger),
      open: (context) => showWidgetPublicationsSheet(
        context,
        ledger: ledger,
        service: _service(env, account, ledger),
      ),
    );
    // Expand the reviewed submission: the golden pins the plain-text
    // comment rendering (author · date, body as text).
    await tester.tap(find.text('2 comments'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'widget_publications_sheet_comments');
  });

  testWidgets('My publications sheet', (tester) async {
    final account = await _account(connected: true);
    final ledger = WidgetPublicationStore.inMemory();
    await ledger.record(
      WidgetPublication(
        widgetId: 'pomodoro',
        version: '1.0.0',
        repoFullName: 'octocat/fa-widget-pomodoro',
        repoCommit: 'a1b2c3d4',
        step: WidgetPublication.stepPrOpened,
        submittedAt: DateTime.utc(2026, 2, 1, 12),
        prNumber: 12,
        prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/12',
      ),
    );
    await ledger.record(
      WidgetPublication(
        widgetId: 'weather',
        version: '2.1.0',
        repoFullName: 'octocat/fa-widget-weather',
        repoCommit: 'e5f6a7b8',
        step: WidgetPublication.stepPrOpened,
        submittedAt: DateTime.utc(2026, 1, 15, 9),
        prNumber: 9,
        prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/9',
        lastKnownState: WidgetPublication.stateMerged,
      ),
    );
    await ledger.record(
      WidgetPublication(
        widgetId: 'stocks',
        version: '0.3.0',
        repoFullName: 'octocat/fa-widget-stocks',
        repoCommit: 'c9d0e1f2',
        step: WidgetPublication.stepPrOpened,
        submittedAt: DateTime.utc(2026, 1, 2, 18),
        prNumber: 7,
        prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/7',
        lastKnownState: WidgetPublication.stateClosed,
      ),
    );
    final env = MemoryExecutionEnv();
    await _pumpSettingsPage(
      tester,
      GithubAccountSection(store: account, ledger: ledger),
      open: (context) => showWidgetPublicationsSheet(
        context,
        ledger: ledger,
        service: _service(env, account, ledger),
      ),
    );
    await expectGolden(tester, 'widget_publications_sheet');
  });

  testWidgets('My publications sheet — offline hint', (tester) async {
    final account = await _account(connected: true);
    final ledger = WidgetPublicationStore.inMemory();
    await ledger.record(
      WidgetPublication(
        widgetId: 'pomodoro',
        version: '1.0.0',
        repoFullName: 'octocat/fa-widget-pomodoro',
        repoCommit: 'a1b2c3d4',
        step: WidgetPublication.stepPrOpened,
        submittedAt: DateTime.utc(2026, 2, 1, 12),
        prNumber: 12,
        prHtmlUrl: 'https://github.com/IstiN/fa_widgets/pull/12',
      ),
    );
    final env = MemoryExecutionEnv();
    await _pumpSettingsPage(
      tester,
      GithubAccountSection(store: account, ledger: ledger),
      open: (context) => showWidgetPublicationsSheet(
        context,
        ledger: ledger,
        // A transport that always throws: the refresh cycle cannot reach
        // a single PR, so the sheet pins the AC8 offline hint over the
        // last-known state chip.
        service: WidgetPublishService(
          env: env,
          account: account,
          ledger: ledger,
          clientFactory: (token) => GithubApiClient(
            token: token,
            httpClient: MockClient(
              (request) => throw http.ClientException('offline'),
            ),
          ),
          clock: () => DateTime.utc(2026, 2, 1, 12),
          sleep: (_) async {},
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'widget_publications_sheet_offline');
  });
}
