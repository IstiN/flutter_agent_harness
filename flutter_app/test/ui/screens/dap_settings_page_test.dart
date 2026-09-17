// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Behavioral tests for `lib/ui/screens/dap_settings_page.dart` (issue #564):
/// every flow the page drives — load/error/unsupported states, the live
/// probe, the add/edit connection editor, bookmark switch/remove, and the
/// inbound-mail routing — plus the pure bookmark-merge helper. Fakes mirror
/// `test/golden/settings_golden_test.dart` (scripted [DapHubService]) and
/// `test/dap_service_web_core_test.dart` (injected extension bridges) —
/// no network, no `~/.dap`.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/dap_service.dart';
import 'package:fa/services/dap_service_web_core.dart';
import 'package:fa/ui/screens/dap_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The en copy the assertions match against (same strings the page gets
  /// from `context.l10n`).
  const saveFailed = 'Could not save the DAP connection — check the hub URL.';
  const loadFailed = 'Could not read the DAP config on this machine.';
  const unsupported = 'DAP hub is not supported on this platform.';

  final connected = DapHubSnapshot(
    supported: true,
    url: 'ws://hub.example.com/ws',
    name: 'fa-desktop',
    agentId: 'a1b2c3d4e5f60718',
    channels: const ['general'],
  );

  Future<void> pumpPage(WidgetTester tester, DapHubService service) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DapHubPage(service: service),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The connection body (probe, inbound rows, editor buttons) sits below
  /// the fold on the default 800x600 test surface — give every flow a tall
  /// window so controls are hittable without scroll juggling.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// Opens the active connection's detail body (the list view shows
  /// first; the probe/inbound/editor controls live on the detail).
  Future<void> openActiveDetail(WidgetTester tester, String url) async {
    await tester.tap(find.byKey(ValueKey('dapConn-$url')));
    await tester.pumpAndSettle();
  }

  group('load states', () {
    testWidgets('a failed read shows the error note, never a spinner', (
      tester,
    ) async {
      await pumpPage(
        tester,
        _FakeService(snapshot: connected, loadThrows: true),
      );

      expect(find.text(loadFailed), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an unsupported host shows the platform-honest note', (
      tester,
    ) async {
      await pumpPage(
        tester,
        _FakeService(
          snapshot: const DapHubSnapshot(
            supported: false,
            url: 'ws://127.0.0.1:8787/ws',
            channels: [],
          ),
        ),
      );

      expect(find.text(unsupported), findsOneWidget);
    });
  });

  group('probe', () {
    testWidgets('a passing probe flips the status chip to Connected', (
      tester,
    ) async {
      useTallSurface(tester);
      await pumpPage(tester, _FakeService(snapshot: connected));
      await openActiveDetail(tester, connected.url);

      expect(find.text('Not checked'), findsOneWidget);
      await tester.tap(find.text('Check connection'));
      await tester.pumpAndSettle();

      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('a failing probe stops the spinner, keeps the page usable', (
      tester,
    ) async {
      useTallSurface(tester);
      await pumpPage(
        tester,
        _FakeService(snapshot: connected, probeThrows: true),
      );
      await openActiveDetail(tester, connected.url);

      await tester.tap(find.text('Check connection'));
      await tester.pumpAndSettle();

      // Stale "Not checked" chip stays; the spinner is gone.
      expect(find.text('Not checked'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Check connection'), findsOneWidget);
    });
  });

  group('connection list', () {
    testWidgets('the active connection renders as a synthesized row', (
      tester,
    ) async {
      useTallSurface(tester);
      // Name null → the row title falls back to the url.
      await pumpPage(
        tester,
        _FakeService(
          snapshot: DapHubSnapshot(
            supported: true,
            url: 'ws://hub.example.com/ws',
            name: null,
            channels: const [],
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('dapConn-ws://hub.example.com/ws')),
        findsOneWidget,
      );
      expect(find.text('Active'), findsOneWidget);
      // The active row's detail is the full connection body.
      await tester.tap(
        find.byKey(const ValueKey('dapConn-ws://hub.example.com/ws')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Check connection'), findsOneWidget);
    });
  });

  group('inbound routing', () {
    testWidgets('tapping a mode persists it', (tester) async {
      useTallSurface(tester);
      final service = _FakeService(snapshot: connected);
      await pumpPage(tester, service);
      await openActiveDetail(tester, connected.url);

      await tester.tap(find.text('A dedicated agent session (recommended)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whichever session is open'));
      await tester.pumpAndSettle();

      expect(service.bindings[0].$1, DapInboundMode.dedicated);
      expect(service.bindings[1].$1, DapInboundMode.currentSession);
    });

    testWidgets('the named mode binds the picked session from the picker', (
      tester,
    ) async {
      useTallSurface(tester);
      final service = _FakeService(
        snapshot: DapHubSnapshot(
          supported: true,
          url: connected.url,
          name: connected.name,
          channels: const [],
          inboundMode: DapInboundMode.named,
          boundSessionTitle: 'beta',
        ),
        sessions: const [
          (id: 'alpha-id', title: 'alpha'),
          (id: 'beta-id', title: 'beta'),
        ],
      );
      await pumpPage(tester, service);
      await openActiveDetail(tester, connected.url);

      // The picker opens preselected on the bound session; pick the other.
      await tester.tap(
        find.descendant(
          of: find.byType(DropdownMenu<String>),
          matching: find.byType(TextField),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('alpha').last);
      await tester.pumpAndSettle();

      expect(service.bindings.single.$1, DapInboundMode.named);
      expect(service.bindings.single.$2, 'alpha-id');
      expect(service.bindings.single.$3, 'alpha');
    });

    testWidgets('named mode with no enumerable sessions has a dead row', (
      tester,
    ) async {
      useTallSurface(tester);
      final service = _FakeService(
        snapshot: DapHubSnapshot(
          supported: true,
          url: connected.url,
          name: connected.name,
          channels: const [],
          inboundMode: DapInboundMode.currentSession,
        ),
      );
      await pumpPage(tester, service);
      await openActiveDetail(tester, connected.url);

      await tester.tap(find.text('A session you pick'));
      await tester.pumpAndSettle();

      expect(service.bindings, isEmpty);
    });

    testWidgets('a failed bind tells the user via snackbar', (tester) async {
      useTallSurface(tester);
      final service = _FakeService(snapshot: connected, bindThrows: true);
      await pumpPage(tester, service);
      await openActiveDetail(tester, connected.url);

      await tester.tap(find.text('Whichever session is open'));
      await tester.pumpAndSettle();

      expect(find.text(saveFailed), findsOneWidget);
    });
  });

  group('bookmarks (extension service)', () {
    testWidgets('a bookmark row opens its detail and switches live', (
      tester,
    ) async {
      useTallSurface(tester);
      final h = _extensionHarness(
        storage: {
          'faDap': {
            'url': 'ws://hub.example.com/ws',
            'name': 'ext-agent',
            'savedConnections': [
              {'url': 'ws://hub.example.com/ws', 'name': 'ext-agent'},
              {
                'url': 'ws://other:8787/ws',
                'name': 'cli-agent',
                'secret': 'pw1',
              },
            ],
          },
        },
      );
      await pumpPage(tester, h.service);

      // Both bookmarks listed; the active one carries the Active chip.
      expect(find.text('ext-agent'), findsOneWidget);
      expect(find.text('cli-agent'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('dapConn-ws://other:8787/ws')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Make active'), findsOneWidget);

      await tester.tap(find.text('Make active'));
      await tester.pumpAndSettle();

      expect(
        h.sent.singleWhere((m) => m['type'] == 'hub.switch')['url'],
        'ws://other:8787/ws',
      );
    });

    testWidgets('a failed switch shows the save-failed snackbar', (
      tester,
    ) async {
      useTallSurface(tester);
      final h = _extensionHarness(
        storage: {
          'faDap': {
            'url': 'ws://hub.example.com/ws',
            'name': 'ext-agent',
            'savedConnections': [
              {'url': 'ws://hub.example.com/ws', 'name': 'ext-agent'},
              {'url': 'ws://other:8787/ws', 'name': 'cli-agent'},
            ],
          },
        },
        onMessage: (message) => message['type'] == 'hub.switch'
            ? {'ok': false, 'error': 'reboot failed'}
            : null,
      );
      await pumpPage(tester, h.service);

      await tester.tap(
        find.byKey(const ValueKey('dapConn-ws://other:8787/ws')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make active'));
      await tester.pumpAndSettle();

      expect(find.text(saveFailed), findsOneWidget);
    });

    testWidgets('an unnamed bookmark titles its detail by the URL', (
      tester,
    ) async {
      useTallSurface(tester);
      final h = _extensionHarness(
        storage: {
          'faDap': {
            'url': 'ws://hub.example.com/ws',
            'name': 'ext-agent',
            'savedConnections': [
              {'url': 'ws://hub.example.com/ws', 'name': 'ext-agent'},
              {'url': 'ws://other:8787/ws', 'name': ''},
            ],
          },
        },
      );
      await pumpPage(tester, h.service);

      await tester.tap(
        find.byKey(const ValueKey('dapConn-ws://other:8787/ws')),
      );
      await tester.pumpAndSettle();

      // The empty name falls back to the URL, on the row and in the
      // detail's bar title.
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('ws://other:8787/ws'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Remove drops the bookmark and returns to the list', (
      tester,
    ) async {
      useTallSurface(tester);
      final h = _extensionHarness(
        storage: {
          'faDap': {
            'url': 'ws://hub.example.com/ws',
            'name': 'ext-agent',
            'savedConnections': [
              {'url': 'ws://hub.example.com/ws', 'name': 'ext-agent'},
              {'url': 'ws://other:8787/ws', 'name': 'cli-agent'},
            ],
          },
        },
      );
      await pumpPage(tester, h.service);

      await tester.tap(
        find.byKey(const ValueKey('dapConn-ws://other:8787/ws')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      final setMsg = h.sent.singleWhere(
        (m) => m['type'] == 'hub.connections.set',
      );
      final list = (setMsg['list']! as List).cast<Map>();
      expect(list, hasLength(1));
      expect(list.single['url'], 'ws://hub.example.com/ws');
      // Back on the list view.
      expect(find.text('Add connection'), findsOneWidget);
    });
  });

  group('edit connection (extension service)', () {
    testWidgets('saving the editor persists the connection and the bookmark', (
      tester,
    ) async {
      useTallSurface(tester);
      final h = _extensionHarness(
        storage: {
          'faDap': {
            'url': 'ws://hub.example.com/ws',
            'name': 'ext-agent',
            'savedConnections': [
              {'url': 'ws://hub.example.com/ws', 'name': 'ext-agent'},
            ],
          },
        },
      );
      await pumpPage(tester, h.service);
      await openActiveDetail(tester, 'ws://hub.example.com/ws');

      await tester.tap(find.text('Edit connection'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'hub2.example.com:8787',
      );
      await tester.enterText(find.byType(TextField).at(1), ' renamed ');
      // Password field left empty → no secret rides the hub.save.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final save = h.sent.singleWhere((m) => m['type'] == 'hub.save');
      expect(save['url'], 'ws://hub2.example.com:8787/ws');
      expect(save['name'], 'renamed');
      expect(save.containsKey('secret'), isFalse);
      // The bookmark list picked up the edited entry (url-normalized).
      final setMsg = h.sent.singleWhere(
        (m) => m['type'] == 'hub.connections.set',
      );
      final urls = [
        for (final e in (setMsg['list']! as List).cast<Map>()) e['url'],
      ];
      expect(urls, contains('ws://hub2.example.com:8787/ws'));
    });

    testWidgets(
      'a typed password rides the save; a failed save snackbar only',
      (tester) async {
        useTallSurface(tester);
        var saves = 0;
        final h = _extensionHarness(
          storage: {
            'faDap': {
              'url': 'ws://hub.example.com/ws',
              'name': 'ext-agent',
              'savedConnections': <Object>[],
            },
          },
          onMessage: (message) => message['type'] == 'hub.save' && saves++ == 0
              ? {'ok': false, 'error': 'bad host'}
              : null,
        );
        await pumpPage(tester, h.service);
        await openActiveDetail(tester, 'ws://hub.example.com/ws');

        await tester.tap(find.text('Edit connection'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).at(2), 'pw2');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        // First attempt failed → snackbar, no bookmark write.
        expect(find.text(saveFailed), findsOneWidget);
        expect(
          h.sent.where((m) => m['type'] == 'hub.connections.set'),
          isEmpty,
        );

        // Let the failure snackbar expire before the retry.
        await tester.pump(const Duration(seconds: 5));

        // The typed secret rode the failed save too (write-only field).
        expect(
          h.sent.singleWhere((m) => m['type'] == 'hub.save')['secret'],
          'pw2',
        );

        // A retry from a fresh editor succeeds → the bookmark write lands.
        await tester.tap(find.text('Edit connection'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).at(2), 'pw2');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.text(saveFailed), findsNothing);
        expect(
          h.sent.where((m) => m['type'] == 'hub.connections.set'),
          isNotEmpty,
        );
      },
    );

    testWidgets('cancelling the editor persists nothing', (tester) async {
      useTallSurface(tester);
      final h = _extensionHarness(
        storage: {
          'faDap': {
            'url': 'ws://hub.example.com/ws',
            'name': 'ext-agent',
            'savedConnections': <Object>[],
          },
        },
      );
      await pumpPage(tester, h.service);
      await openActiveDetail(tester, 'ws://hub.example.com/ws');

      await tester.tap(find.text('Edit connection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      const writeTypes = {
        'hub.save',
        'hub.bind',
        'hub.switch',
        'hub.connections.set',
      };
      expect(h.sent.where((m) => writeTypes.contains(m['type'])), isEmpty);
    });
  });

  group('add connection (extension service)', () {
    testWidgets('a saved draft becomes the active connection and a bookmark', (
      tester,
    ) async {
      useTallSurface(tester);
      final h = _extensionHarness(
        storage: {
          'faDap': {
            'url': 'ws://hub.example.com/ws',
            'name': 'ext-agent',
            'savedConnections': <Object>[],
          },
        },
      );
      await pumpPage(tester, h.service);

      await tester.tap(find.text('Add connection'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        'hub3.example.com:8787',
      );
      await tester.enterText(find.byType(TextField).at(1), 'third hub');
      await tester.enterText(find.byType(TextField).at(2), 'pw3');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final save = h.sent.singleWhere((m) => m['type'] == 'hub.save');
      expect(save['url'], 'ws://hub3.example.com:8787/ws');
      expect(save['secret'], 'pw3');
      final setMsg = h.sent.singleWhere(
        (m) => m['type'] == 'hub.connections.set',
      );
      final urls = [
        for (final e in (setMsg['list']! as List).cast<Map>()) e['url'],
      ];
      expect(urls, contains('ws://hub3.example.com:8787/ws'));
    });
  });

  group('mergeDapSavedConnections (pure)', () {
    const hub = DapSavedConnection(url: 'ws://hub/ws', name: 'hub');
    const other = DapSavedConnection(url: 'ws://other/ws', name: 'other');

    test('a new url is appended, existing entries kept in order', () {
      final merged = mergeDapSavedConnections([
        hub,
        other,
      ], const DapSavedConnection(url: 'ws://third/ws', name: 'third'));
      expect(merged.map((e) => e.url), [
        'ws://hub/ws',
        'ws://other/ws',
        'ws://third/ws',
      ]);
    });

    test('a typed secret replaces the stored one on the same url', () {
      final merged = mergeDapSavedConnections(
        [
          hub,
          const DapSavedConnection(
            url: 'ws://other/ws',
            name: 'other',
            secret: 'old',
          ),
        ],
        const DapSavedConnection(
          url: 'ws://other/ws',
          name: 'renamed',
          secret: 'new',
        ),
      );
      expect(merged, hasLength(2));
      final entry = merged.singleWhere((e) => e.url == 'ws://other/ws');
      expect(entry.name, 'renamed');
      expect(entry.secret, 'new');
    });

    test('an empty secret keeps the stored secret of the same-url entry', () {
      final merged = mergeDapSavedConnections([
        const DapSavedConnection(
          url: 'ws://other/ws',
          name: 'other',
          secret: 'stored',
        ),
      ], const DapSavedConnection(url: 'ws://other/ws', name: 'other'));
      expect(merged.single.secret, 'stored');
    });

    test('empty everywhere stays empty (an open hub)', () {
      final merged = mergeDapSavedConnections([
        const DapSavedConnection(url: 'ws://other/ws', name: 'other'),
      ], const DapSavedConnection(url: 'ws://other/ws', name: 'other'));
      expect(merged.single.secret, '');
    });

    test('duplicate same-url entries fold into one, first secret wins', () {
      final merged = mergeDapSavedConnections([
        const DapSavedConnection(url: 'ws://other/ws', name: 'a', secret: 's1'),
        const DapSavedConnection(url: 'ws://other/ws', name: 'b', secret: 's2'),
      ], const DapSavedConnection(url: 'ws://other/ws', name: 'c'));
      expect(merged, hasLength(1));
      expect(merged.single.name, 'c');
      expect(merged.single.secret, 's1');
    });
  });
}

/// A scripted [DapHubService]: returns the fixed snapshot, records
/// bindings, throws on demand. Mirrors the golden fake — no files, no
/// network.
class _FakeService implements DapHubService {
  _FakeService({
    required this.snapshot,
    this.loadThrows = false,
    this.probeThrows = false,
    this.bindThrows = false,
    this.sessions = const [],
  });

  final DapHubSnapshot snapshot;
  final bool loadThrows;
  final bool probeThrows;
  final bool bindThrows;
  final List<DapBindableSession> sessions;

  final bindings = <(DapInboundMode, String?, String?)>[];

  @override
  Future<DapHubSnapshot> load() async {
    if (loadThrows) throw StateError('unreadable config');
    return snapshot;
  }

  @override
  Future<DapHubSnapshot> probe() async {
    if (probeThrows) throw StateError('dead hub');
    return snapshot.withProbe(true);
  }

  @override
  Future<void> saveConnection({
    required String url,
    required String name,
    String? secret,
  }) async {}

  @override
  Future<List<DapBindableSession>> listBindableSessions() async => sessions;

  @override
  Future<void> saveBinding(
    DapInboundMode mode, {
    String? sessionId,
    String? sessionTitle,
  }) async {
    if (bindThrows) throw StateError('bind rejected');
    bindings.add((mode, sessionId, sessionTitle));
  }
}

/// A scripted extension backend: in-memory `chrome.storage` + a scripted
/// service-worker that mirrors connection/switch writes back into storage
/// (the real SW owns `faDap`). Same shape as the web-core test harness.
({ExtensionDapHubService service, List<Map<String, Object?>> sent})
_extensionHarness({
  Map<String, Object?> storage = const {},
  Object? Function(Map<String, Object?> message)? onMessage,
}) {
  final sent = <Map<String, Object?>>[];
  final mutable = Map<String, Object?>.of(storage);
  final service = ExtensionDapHubService(
    pollInterval: Duration.zero,
    probeTimeout: const Duration(milliseconds: 50),
    sendMessage: (message) async {
      sent.add(message);
      if (onMessage != null) {
        final scripted = onMessage(message);
        if (scripted != null) return scripted;
      }
      return switch (message['type']) {
        'status' => {
          'ok': true,
          'status': {
            'agent': {
              'booted': true,
              'hub': {'phase': 'connected', 'agentId': 'a1b2c3d4e5f60718'},
            },
          },
        },
        'hub.save' => {'ok': true},
        'hub.bind' => {'ok': true},
        'hub.sessions' => {'ok': true, 'sessions': const <Object?>[]},
        'hub.connections.set' => () {
          final faDap = Map<String, Object?>.of(
            mutable['faDap'] as Map<String, Object?>? ?? const {},
          )..['savedConnections'] = message['list'];
          mutable['faDap'] = faDap;
          return {'ok': true};
        }(),
        'hub.switch' => () {
          final faDap = Map<String, Object?>.of(
            mutable['faDap'] as Map<String, Object?>? ?? const {},
          )..['url'] = message['url'];
          mutable['faDap'] = faDap;
          return {'ok': true};
        }(),
        _ => {'ok': true},
      };
    },
    storageGet: (key) async => {key: mutable[key]},
  );
  return (service: service, sent: sent);
}
