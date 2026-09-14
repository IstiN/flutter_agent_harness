// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #381: sessions over the instant-open budget (64 MiB) open through
/// the WINDOWED loader instead of being refused — the refuse-gate of the
/// freeze era moves behind the windowed loader and survives only as the
/// guard on the full-open fallback (a failed windowed open of an
/// over-budget file must never degrade to a whole-file read).
library;

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/boot_oversize_notice.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

// The counting/flaky file systems come from the windowed-loader suite: the
// same fixtures prove zero bulk-read regression on the new route.
import 'agent_service_windowed_test.dart'
    show CountingFileSystem, FlakyFileSystem;

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

Agent _createAgent() {
  return Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'You are Fa.',
    streamFunction: _singleTextResponse('ok'),
    toolRegistry: ToolRegistry(const []),
  );
}

final _config = AgentConfig(
  providerKind: 'test',
  modelId: 'test-model',
  baseUrl: 'https://example.com',
  apiKey: '',
);

/// Builds a session file body in one string — thousands of awaited storage
/// appends would dominate the test runtime (the windowed-suite pattern).
String _sessionBody(String id, int count) {
  const iso = '2026-01-01T00:00:00.000Z';
  final buffer = StringBuffer(
    '{"type":"session","version":3,"id":"$id","timestamp":"$iso",'
    '"cwd":"/work"}\n',
  );
  for (var i = 0; i < count; i++) {
    buffer.write(
      '{"type":"message","id":"e$i","parentId":'
      '${i == 0 ? 'null' : '"e${i - 1}"'},"timestamp":"$iso",'
      '"message":{"role":"user","content":[{"type":"text","text":'
      '"message $i with a bit of body to be realistic"}]}}\n',
    );
  }
  return buffer.toString();
}

AgentService _service(String cwd, FileSystem fs) {
  return AgentService(
    agent: _createAgent(),
    env: LocalExecutionEnv(cwd: cwd),
    sessionsRoot: cwd,
    repo: JsonlSessionRepo(fs: fs, sessionsRoot: cwd),
    watchExternalSessions: false,
    includeSharedSessionRoots: false,
  );
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
  });

  // AC1 UT-oversized-windowed: openSession routes an over-budget file
  // through the windowed loader — tail window in memory, zero bulk reads.
  test(
    'UT-oversized-windowed: openSession on an over-budget file opens '
    'the tail window with zero bulk reads',
    () async {
      final tmp = await io.Directory.systemTemp.createTemp('fa_381_open');
      addTearDown(() => tmp.delete(recursive: true));
      await io.File('${tmp.path}/big.jsonl')
          .writeAsString(_sessionBody('big', 300));
      final counting = CountingFileSystem(LocalFileSystem(cwd: tmp.path));
      final service = _service(tmp.path, counting);
      addTearDown(service.dispose);
      await service.initialize();

      final manager = FlutterSessionManager(
        env: LocalExecutionEnv(cwd: tmp.path),
        sessionsRoot: tmp.path,
        repo: JsonlSessionRepo(fs: counting, sessionsRoot: tmp.path),
        // Far below the 300-record file: every open must take the
        // windowed route.
        maxSessionLoadBytes: 1024,
      );
      final metadata = (await manager.listPersistedSessions()).single;
      expect(metadata.sizeBytes, greaterThan(1024));
      // Count only the OPEN path: list bookkeeping may bulk-read headers.
      counting
        ..bulkBytes = 0
        ..rangedBytes = 0;

      // The old gate threw SessionTooLargeException right here.
      final managed = await manager.openSession(
        metadata,
        config: _config,
        serviceFactory: () async => service,
      );

      // The window is the newest chunk (200 records), read via ranged
      // reads; the whole file never crossed the filesystem.
      expect(managed.service.messages, hasLength(200));
      expect(managed.service.messages.last.content, contains('message 299'));
      expect(counting.rangedBytes, greaterThan(0));
      expect(counting.bulkBytes, 0);
    },
  );

  // AC2 UT-fallback-guard: a failed windowed open of an over-budget file
  // must NOT degrade to the full open — the freeze guard survives exactly
  // for that path. (The fault fixture is the windowed suite's torn-read:
  // the ranged-read path dies, the windowed open fails.)
  test(
    'UT-fallback-guard: over-budget windowed-open failure refuses the '
    'full open (SessionTooLargeException, zero bulk reads)',
    () async {
      final tmp = await io.Directory.systemTemp.createTemp('fa_381_guard');
      addTearDown(() => tmp.delete(recursive: true));
      await io.File('${tmp.path}/big.jsonl')
          .writeAsString(_sessionBody('big', 300));
      final flaky = FlakyFileSystem(LocalFileSystem(cwd: tmp.path));
      flaky.failNextReadRange = true;
      final service = _service(tmp.path, flaky);
      addTearDown(service.dispose);
      await service.initialize();

      final manager = FlutterSessionManager(
        env: LocalExecutionEnv(cwd: tmp.path),
        sessionsRoot: tmp.path,
        repo: JsonlSessionRepo(fs: flaky, sessionsRoot: tmp.path),
        maxSessionLoadBytes: 1024,
      );
      final metadata = (await manager.listPersistedSessions()).single;
      flaky.bulkBytes = 0;

      await expectLater(
        manager.openSession(
          metadata,
          config: _config,
          serviceFactory: () async => service,
        ),
        throwsA(isA<SessionTooLargeException>()),
      );
      expect(
        flaky.bulkBytes,
        0,
        reason: 'the full-open fallback must never whole-file read an '
            'over-budget session',
      );
    },
  );

  // AC3 UT-under-budget-unchanged: under-budget sessions keep today's
  // behavior — windowed first, and the full-open fallback still saves a
  // failed windowed open (the compatibility path, byte-identical route).
  test(
    'UT-under-budget-unchanged: a small session still falls back to the '
    'full open and loads completely',
    () async {
      final tmp = await io.Directory.systemTemp.createTemp('fa_381_small');
      addTearDown(() => tmp.delete(recursive: true));
      await io.File('${tmp.path}/small.jsonl')
          .writeAsString(_sessionBody('small', 5));
      final flaky = FlakyFileSystem(LocalFileSystem(cwd: tmp.path));
      flaky.failNextReadRange = true;
      final service = _service(tmp.path, flaky);
      addTearDown(service.dispose);
      await service.initialize();

      final manager = FlutterSessionManager(
        env: LocalExecutionEnv(cwd: tmp.path),
        sessionsRoot: tmp.path,
        repo: JsonlSessionRepo(fs: flaky, sessionsRoot: tmp.path),
      );
      final metadata = (await manager.listPersistedSessions()).single;
      flaky.bulkBytes = 0;

      // Default budget: the file is under it. The ranged-read path dies
      // (same fault the windowed suite uses) — the full open saves the
      // session exactly as before #381.
      final managed = await manager.openSession(
        metadata,
        config: _config,
        serviceFactory: () async => service,
      );

      expect(managed.service.messages, hasLength(5));
      expect(flaky.bulkBytes, greaterThan(0));
    },
  );

  // AC4 UT-boot-toast (manager half): boot skips the oversized last-active
  // and records it for the UI notice instead of silently swapping.
  test(
    'UT-boot-skipped: an oversized last-active session is not resumed at '
    'boot; the skip is surfaced on the manager',
    () async {
      final env = MemoryExecutionEnv();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await env.writeFile('/sessions/giant.jsonl', _sessionBody('giant', 50));
      await env.writeFile(
        '/sessions/${FlutterSessionManager.lastActiveFile}',
        '{"version":1,"id":"giant"}',
      );
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        repo: repo,
        maxSessionLoadBytes: 1024,
      );

      final booted = await manager.createOrResumeSession(
        config: _config,
        createFactory: () async => AgentService(
          agent: _createAgent(),
          env: env,
          sessionsRoot: '/sessions',
          config: _config,
          watchExternalSessions: false,
        ),
        openFactory: () async => throw StateError('must not open the giant'),
      );

      // A fresh session, not the giant; the skip is on the manager for
      // the shell notice.
      expect(booted.id, isNot('giant'));
      expect(manager.bootSkippedOversize?.id, 'giant');
      expect(manager.bootSkippedOversize?.sizeBytes, greaterThan(1024));
    },
  );

  // AC4 UT-boot-toast (UI half): the notice names the skipped session and
  // its size; tapping the action hands the metadata to the shell's open
  // path (which routes windowed — proven by UT-oversized-windowed).
  testWidgets(
    'UT-boot-toast: the boot notice shows name and size; the action opens '
    'the skipped session',
    (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      const created = 444595200; // 424 MiB
      final skipped = SessionMetadata(
        id: 'giant',
        createdAt: DateTime.utc(2026, 9, 10, 8, 30),
        cwd: '/work',
        path: '/sessions/giant.jsonl',
        sizeBytes: created,
      );
      manager.bootSkippedOversize = skipped;
      final names = SessionNamesStore.inMemory({'giant': 'The Giant'});
      final opened = <SessionMetadata>[];

      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      showBootOversizeNotice(
        tester.element(find.byType(Scaffold)),
        manager: manager,
        names: names,
        onOpen: (metadata) async => opened.add(metadata),
      );
      // Frame 1 runs the post-frame callback and starts the entrance
      // animation; the timed frame completes it so the action is
      // on-screen and hittable.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // One unobtrusive notice naming the session and its size.
      expect(find.textContaining('The Giant'), findsOneWidget);
      expect(find.textContaining('424'), findsOneWidget);
      expect(
        find.textContaining('over the instant-open budget'),
        findsOneWidget,
      );

      // Tapping opens the big session (windowed route).
      await tester.tap(find.text('Open windowed'), warnIfMissed: false);
      await tester.pump();
      expect(opened.map((m) => m.id), ['giant']);
      // Run out the snackbar hold timer so the test ends timer-free.
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
    },
  );

  // AC5 E2E (sidebar half): through the real sheet surface — drawer-open
  // an over-budget session and the chat opens with the tail window
  // instead of the old "Session too large" refusal.
  testWidgets(
    'E2E-sidebar-open: drawer-open of an over-budget session opens its '
    'windowed chat (no refusal)',
    (tester) async {
      final env = MemoryExecutionEnv();
      await env.writeFile('/sessions/giant.jsonl', _sessionBody('giant', 300));
      final service = AgentService(
        agent: _createAgent(),
        env: env,
        sessionsRoot: '/sessions',
        config: _config,
        watchExternalSessions: false,
      );
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        // The injected budget stands in for the 64 MiB ceiling: the
        // 300-record file (~36 KB) is over it — the same route a 439 MB
        // file takes.
        maxSessionLoadBytes: 1024,
      )..addSession('live-a', service);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SessionChatSheet(manager: manager, asr: _FakeAsrApi()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Drawer → persisted giant row.
      await tester.tap(find.byKey(const ValueKey('sessionChatDrawerButton')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('sessionChatDrawerEntry:giant')),
      );
      await tester.pumpAndSettle();

      // The chat opened: composer live, tail window loaded — newest
      // record visible, the file's head NOT bulk-read into memory, and
      // none of the old "too large" refusal snackbar.
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(find.textContaining('message 299'), findsOneWidget);
      expect(find.textContaining('message 0 '), findsNothing);
      expect(find.textContaining('over the instant-open budget'), findsNothing);
    },
  );

  // AC5 E2E (window + paging half): the real chat surface over the
  // opened giant — only the tail window loaded, and "Load earlier" pages
  // up through the file.
  testWidgets(
    'E2E-windowed-chat: the opened giant shows the tail window; Load '
    'earlier pages up through the file',
    (tester) async {
      final env = MemoryExecutionEnv();
      await env.writeFile('/sessions/giant.jsonl', _sessionBody('giant', 300));
      final service = AgentService(
        agent: _createAgent(),
        env: env,
        sessionsRoot: '/sessions',
        config: _config,
        watchExternalSessions: false,
      );
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
        maxSessionLoadBytes: 1024,
      )..addSession('live-a', service);
      final metadata = await service.listSessions();
      await manager.openSession(
        metadata.first,
        config: _config,
        serviceFactory: () async => service.clone(),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChatScreen(manager: manager),
        ),
      );
      await tester.pumpAndSettle();

      // The window is visible: newest records rendered, head not loaded.
      expect(find.textContaining('message 299'), findsOneWidget);
      expect(find.textContaining('message 0 '), findsNothing);
      // The composer is live (interactive chat, not a loading shell).
      expect(find.byType(ChatComposer), findsOneWidget);

      // "Load earlier" pages up: one chunk covers the remaining 100
      // records, so the head lands in the view. The list opens scrolled
      // to the tail - bring the pinned banner on-screen first.
      await tester.scrollUntilVisible(
        find.textContaining('Load earlier').first,
        -100,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 20,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Load earlier').first);
      await tester.pumpAndSettle();
      // The head decoded into the service (300 = full file); the pinned
      // "Load earlier" banner turned into its terminal state in place.
      expect(manager.active!.service.messages, hasLength(300));
      expect(manager.active!.service.historyAboveCount, 0);
      expect(find.textContaining('Load earlier'), findsNothing);
      expect(find.textContaining('Beginning of session'), findsOneWidget);
    },
  );
}

/// Fake [AsrApi] — widget tests never touch the real method channel (the
/// session_chat_sheet_test pattern).
final class _FakeAsrApi implements AsrApi {
  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<void> startRecording() async {}

  @override
  Future<AsrRecording> stopRecording() async =>
      (path: '/tmp/fah-mic-test.m4a', durationMs: 5000, sampleRate: 44100);

  @override
  Future<Uint8List> readRecording(String path) async =>
      Uint8List.fromList(const [1, 2, 3]);
}
