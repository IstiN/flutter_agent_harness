import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart'
    show
        FaAttachGlyph,
        FaButton,
        FaButtonVariant,
        FaDesignTokens,
        FaHeaderCircularAction,
        FaIconActionBand,
        FaSectionEyebrow,
        FaVisualDirection,
        FahColors,
        buildFaTheme;
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/file_preview.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/services/upload_picker_stub.dart'
    if (dart.library.io) 'package:fa/services/upload_picker_io.dart'
    if (dart.library.html) 'package:fa/services/upload_picker_web.dart';
import 'package:fa/services/icloud_sync_service.dart';
import 'package:fa/services/project_folder_channel.dart';
import 'package:fa/ui/widgets/session_search_field.dart'
    show kSearchFieldHeight;
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/project_mount_flow.dart' show visibleFolderRoot;
import 'package:fa/services/project_mount_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassTextField;

/// Valid 1x1 transparent PNG.
const _pngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

/// Seeds an env where a file (`aaa.txt`) sorts before a directory
/// (`zzz_dir`) alphabetically, so the dirs-first ordering is observable.
Future<MemoryExecutionEnv> _seededEnv() async {
  final env = MemoryExecutionEnv();
  await env.writeFile('aaa.txt', 'first file');
  await env.createDir('zzz_dir');
  await env.writeFile('zzz_dir/inner.txt', 'inner content');
  await env.writeFile('notes.txt', 'hello notes');
  await env.writeFile(
    'readme.md',
    '# Title\n\nSome **bold** text\n\n- one\n- two\n',
  );
  await env.writeFile('page.html', '<h1>Hi</h1><p>para</p>');
  await env.writeBinaryFile('logo.png', Uint8List.fromList(_pngBytes));
  await env.writeBinaryFile('blob.bin', Uint8List.fromList([0, 1, 2, 3]));
  await env.createDir('empty_dir');
  return env;
}

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

Finder _selectableText(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is SelectableText &&
      (widget.data == text ||
          (widget.textSpan != null && widget.textSpan!.toPlainText() == text)),
);

/// Finds a `SelectableText.rich` (how flutter_markdown renders selectable
/// blocks) whose span renders exactly [plainText].
Finder _selectableRichText(String plainText) => find.byWidgetPredicate(
  (widget) =>
      widget is SelectableText &&
      widget.textSpan != null &&
      widget.textSpan!.toPlainText() == plainText,
);

List<String> _listedNames(WidgetTester tester) {
  return tester
      .widgetList<Material>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Material &&
              widget.key is ValueKey<String> &&
              (widget.key as ValueKey<String>).value.startsWith('fileRow-'),
        ),
      )
      .map((row) {
        final title = tester
            .widgetList<Text>(
              find.descendant(
                of: find.byKey(row.key!),
                matching: find.byType(Text),
              ),
            )
            .first;
        return title.data!;
      })
      .toList();
}

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

AgentService _fakeService(ExecutionEnv env) {
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
      systemPrompt: 'You are Fa.',
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
  );
}

FlutterSessionManager _fakeManager(
  ExecutionEnv env, [
  String sessionId = 'fake-session',
]) {
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  manager.addSession(sessionId, _fakeService(env));
  return manager;
}

const _testModel = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test',
  baseUrl: 'https://example.com',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: _testModel.api,
    provider: _testModel.provider,
    model: _testModel.id,
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.now(),
  );
}

/// A scripted turn: stream start, text delta, done.
List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A scripted turn that ends with tool calls.
List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: StopReason.toolUse);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

/// A service whose agent runs the REAL builtin tools against [env], fed by
/// a scripted stream that replays whole turns and then ends.
AgentService _toolService(
  ExecutionEnv env,
  List<List<AssistantMessageEvent>> turns,
) {
  final service = AgentService(
    agent: Agent(
      model: _testModel,
      systemPrompt: 'You are Fa.',
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        for (final event in turns.removeAt(0)) {
          stream.push(event);
        }
        stream.end();
        return stream;
      },
      toolRegistry: ToolRegistry(builtinTools(env)),
    ),
    env: env,
    sessionsRoot: '/sessions',
  );
  // These tests exercise fs-refresh, not approval: run tools unattended.
  service.approval.mode = ApprovalMode.yolo;
  return service;
}

/// Fake [UploadPicker] returning canned files without a platform dialog.
final class _FakePicker implements UploadPicker {
  _FakePicker(this.files);

  List<UploadFile> files;
  Object? error;
  int calls = 0;

  @override
  Future<List<UploadFile>> pick() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return files;
  }
}

UploadFile _uploadFile(String name, String content) =>
    (name: name, bytes: Uint8List.fromList(content.codeUnits));

/// A service whose [AgentService.sendAttachments] fails, so the composer
/// must hand the pending chips and the typed text back to the user.
final class _ThrowingSendService extends AgentService {
  _ThrowingSendService(ExecutionEnv env)
    : super(
        agent: Agent(
          model: _testModel,
          systemPrompt: 'You are Fa.',
          streamFunction: _singleTextResponse('ok'),
          toolRegistry: ToolRegistry(const []),
        ),
        env: env,
        sessionsRoot: '/sessions',
      );

  @override
  Future<void> sendAttachments({
    required List<StagedAttachment> attachments,
    String text = '',
  }) {
    throw StateError('simulated send failure');
  }
}

/// Fake [ICloudSyncService] scripting the availability check and the merge
/// outcome for the header sync button tests.
final class _FakeICloudSync implements ICloudSyncService {
  _FakeICloudSync({this.available = true, this.error});

  bool available;
  Object? error;
  int syncCalls = 0;

  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<String?> containerUrl() async => available ? 'file:///icloud' : null;

  @override
  Future<DateTime?> lastSyncAt() async => null;

  @override
  Future<ICloudSyncReport> syncNow() async {
    syncCalls++;
    final failure = error;
    if (failure != null) throw failure;
    return (
      filesCopied: 2,
      bytesCopied: 120,
      syncedAt: DateTime.utc(2026, 9, 17, 12),
    );
  }
}

/// A fake [ProjectFolderOps] whose pick result the test scripts; records
/// the started/stopped bookmarks like the channel ops would.
final class _ScriptedFolderOps implements ProjectFolderOps {
  _ScriptedFolderOps({this.pickResult, this.startAccessOk = true});

  ({String path, String bookmark})? pickResult;
  bool startAccessOk;
  final started = <String>[];
  final stopped = <String>[];

  @override
  Future<({String path, String bookmark})?> pickDirectory() async => pickResult;

  @override
  Future<bool> startAccessing(String bookmark) async {
    if (!startAccessOk) return false;
    started.add(bookmark);
    return true;
  }

  @override
  Future<void> stopAccessing(String bookmark) async => stopped.add(bookmark);
}

void main() {
  group('FileBrowser session folder gate', () {
    // The reported defect: a chat session in folder X with the app mount
    // at folder Y showed Y's listing under the Files title. A foreign
    // session folder must gate the listing instead.
    testWidgets('a foreign session folder shows the access gate, not a '
        'wrong listing', (tester) async {
      final base = MemoryExecutionEnv();
      await base.writeFile('mount_file.txt', 'the active mount content');
      final env = ProjectMountEnv(base)..mountedRoot = '/Users/x/mount';
      await tester.pumpWidget(
        _wrap(
          FileBrowser(
            env: env,
            sessionFolder: '/Users/x/support',
            projectFolderOps: _ScriptedFolderOps(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The gate names the session's folder and offers the grant.
      expect(
        find.byKey(const ValueKey('filesSessionFolderGate')),
        findsOneWidget,
      );
      // The gate names the session folder in its body copy.
      expect(find.textContaining('support'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('filesSessionFolderGateAllow')),
        findsOneWidget,
      );
      // NO silent wrong listing: the active mount's content is not shown,
      // and no listing error leaks either — the gate replaces the body.
      expect(find.text('mount_file.txt'), findsNothing);
      expect(find.text('Could not list folder'), findsNothing);
    });

    testWidgets('a session folder the env can open lists directly (no gate)', (
      tester,
    ) async {
      // A sandboxed delegate roots at its own container — a relative
      // listDir('Users/…') must never resolve (the real macOS sandbox),
      // so the browser has to rebase the host initialPath onto the
      // mount namespace.
      final base = MemoryExecutionEnv(cwd: '/app-sandbox');
      await base.writeFile(
        '/Users/x/support/session_file.txt',
        'in the session folder',
      );
      final env = ProjectMountEnv(base)..mountedRoot = '/Users/x/support';
      await tester.pumpWidget(
        _wrap(
          FileBrowser(
            env: env,
            initialPath: visibleFolderRoot(env, '/Users/x/support'),
            sessionFolder: '/Users/x/support',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('filesSessionFolderGate')),
        findsNothing,
      );
      expect(find.text('session_file.txt'), findsOneWidget);
      expect(find.text('Could not list folder'), findsNothing);
    });

    testWidgets(
      'a mounted session lists through the mount namespace when opened '
      'with the host initialPath (regression: directory listing failed)',
      (tester) async {
        // The exact production seam: chat_screen passes
        // initialPath = visibleFolderRoot(env, sessionCwd) — the HOST
        // path of the mounted folder — while ProjectMountEnv.cwd is the
        // virtual '/project'. The browser must rebase that host path
        // onto the mount root, never leak raw host segments into
        // listDir.
        final base = MemoryExecutionEnv(cwd: '/app-sandbox');
        await base.writeFile(
          '/Users/x/support/opened.txt',
          'in the mounted folder',
        );
        final env = ProjectMountEnv(base)..mountedRoot = '/Users/x/support';
        await tester.pumpWidget(
          _wrap(
            FileBrowser(
              env: env,
              initialPath: visibleFolderRoot(env, '/Users/x/support'),
              sessionFolder: null,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Could not list folder'),
          findsNothing,
          reason: 'the host initialPath must rebase onto /project',
        );
        expect(find.text('opened.txt'), findsOneWidget);
      },
    );

    testWidgets('a personal session (no folder) keeps the env-root listing', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, sessionFolder: null)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('filesSessionFolderGate')),
        findsNothing,
      );
      expect(find.text('aaa.txt'), findsOneWidget);
    });

    testWidgets('mount machinery without a live mount lists the env root '
        '(regression: the virtual /project error replaced the listing)', (
      tester,
    ) async {
      // Mobile/desktop hosts always carry the project-mount env; with no
      // grant active the browser used to ask for the virtual /project
      // segment anyway and painted "Could not open folder" over the
      // personal (container/sandbox) root.
      final base = MemoryExecutionEnv(cwd: '/app/container');
      await base.writeFile('sandbox_file.txt', 'in the container root');
      final env = SecretsExecutionEnv(ProjectMountEnv(base), const {});
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();
      expect(find.text('sandbox_file.txt'), findsOneWidget);
      expect(find.text('Could not open folder'), findsNothing);
    });

    testWidgets(
      'a session folder under a stale container prefix (relocated sandbox) '
      'lists instead of gating',
      (tester) async {
        // iOS reinstall/backup-restore re-seats the app container: the
        // restored session records the OLD UUID prefix while the env root
        // carries the NEW one. The folder IS the sandbox — Files must
        // resolve it onto the live root, never gate.
        final base = MemoryExecutionEnv(
          cwd:
              '/var/mobile/Containers/Data/Application/9F2E-live/Documents/'
              'fah_sandbox',
        );
        await base.writeFile('sandbox_file.txt', 'in the sandbox');
        final env = SecretsExecutionEnv(ProjectMountEnv(base), const {});
        await tester.pumpWidget(
          _wrap(
            FileBrowser(
              env: env,
              sessionFolder:
                  '/var/mobile/Containers/Data/Application/4A7D-old/'
                  'Documents/fah_sandbox',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('filesSessionFolderGate')),
          findsNothing,
          reason: 'the stale prefix is the same sandbox folder',
        );
        expect(find.text('sandbox_file.txt'), findsOneWidget);
      },
    );

    testWidgets('granting access switches the mount and lists the session '
        'folder', (tester) async {
      // Sandboxed delegate (non-root cwd): the post-grant jump must go
      // through the mount namespace, not raw host segments.
      final base = MemoryExecutionEnv(cwd: '/app-sandbox');
      await base.writeFile(
        '/Users/x/mount/mount_file.txt',
        'the active mount content',
      );
      final env = ProjectMountEnv(base);
      // The session folder's content, as the (in-memory) host FS holds it.
      await base.writeFile('/Users/x/support/granted.txt', 'granted content');
      final ops = _ScriptedFolderOps(
        pickResult: (path: '/Users/x/support', bookmark: 'Ym9va21hcms='),
      );
      await tester.pumpWidget(
        _wrap(
          FileBrowser(
            env: env,
            sessionFolder: '/Users/x/support',
            projectFolderOps: ops,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('filesSessionFolderGate')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('filesSessionFolderGateAllow')),
      );
      await tester.pumpAndSettle();

      // The existing security-scoped flow ran: bookmark resolved, mount
      // switched (persisted), gate gone, listing = the granted folder.
      expect(ops.started, ['Ym9va21hcms=']);
      expect(env.mountedRoot, '/Users/x/support');
      final stored = await ProjectMountStore.load(env);
      expect(stored?.path, '/Users/x/support');
      expect(
        find.byKey(const ValueKey('filesSessionFolderGate')),
        findsNothing,
      );
      expect(find.text('granted.txt'), findsOneWidget);
      expect(find.text('mount_file.txt'), findsNothing);
      expect(find.text('Could not list folder'), findsNothing);
    });

    testWidgets('a failed grant keeps the gate (no silent wrong listing)', (
      tester,
    ) async {
      final base = MemoryExecutionEnv();
      await base.writeFile('mount_file.txt', 'the active mount content');
      final env = ProjectMountEnv(base);
      final ops = _ScriptedFolderOps(startAccessOk: false);
      await tester.pumpWidget(
        _wrap(
          FileBrowser(
            env: env,
            sessionFolder: '/Users/x/support',
            projectFolderOps: ops,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('filesSessionFolderGateAllow')),
      );
      await tester.pumpAndSettle();

      expect(env.mountedRoot, isNull, reason: 'the mount never switched');
      expect(
        find.byKey(const ValueKey('filesSessionFolderGate')),
        findsOneWidget,
        reason: 'the affordance stays',
      );
      expect(find.text('mount_file.txt'), findsNothing);
    });

    testWidgets('declining the picker keeps the gate', (tester) async {
      final base = MemoryExecutionEnv();
      final env = ProjectMountEnv(base);
      final ops = _ScriptedFolderOps(); // pickDirectory → null (cancel)
      await tester.pumpWidget(
        _wrap(
          FileBrowser(
            env: env,
            sessionFolder: '/Users/x/support',
            projectFolderOps: ops,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('filesSessionFolderGateAllow')),
      );
      await tester.pumpAndSettle();
      expect(env.mountedRoot, isNull);
      expect(
        find.byKey(const ValueKey('filesSessionFolderGate')),
        findsOneWidget,
      );
    });
  });

  group('FileBrowser', () {
    testWidgets('lists directories first, then files, both sorted', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      expect(_listedNames(tester), [
        'empty_dir',
        'zzz_dir',
        'aaa.txt',
        'blob.bin',
        'logo.png',
        'notes.txt',
        'page.html',
        'readme.md',
      ]);
    });

    testWidgets('compact search reveals, preserves a query, and closes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('fileBrowserSearch'));
      final reveal = find.byKey(const ValueKey('fileBrowserSearchReveal'));
      expect(search, findsNothing);
      expect(reveal, findsOneWidget);

      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(search, findsOneWidget);
      final editable = tester.widget<EditableText>(
        find.descendant(of: search, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isTrue);
      await tester.enterText(search, 'notes');
      editable.focusNode.unfocus();
      await tester.pump();
      expect(search, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('fileBrowserSearchClose')));
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      expect(reveal, findsOneWidget);
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: search, matching: find.byType(EditableText)),
            )
            .controller
            .text,
        isEmpty,
      );
    });

    testWidgets('the band capsule filters the listing live', (tester) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('logo.png'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('fileBrowserSearch')),
        'notes',
      );
      await tester.pump();
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('logo.png'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('fileBrowserSearch')),
        'zzz',
      );
      await tester.pump();
      expect(_listedNames(tester), ['zzz_dir']);

      await tester.enterText(
        find.byKey(const ValueKey('fileBrowserSearch')),
        'no-such-file',
      );
      await tester.pump();
      expect(
        find.text(
          tester.element(find.byType(FileBrowser)).l10n.filesNoSearchMatches,
        ),
        findsOneWidget,
      );
    });

    testWidgets('themed grouped cards and chrome adapt without overflow', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final env = await _seededEnv();
      for (final direction in FaVisualDirection.values) {
        for (final brightness in Brightness.values) {
          for (final width in <double>[800, 300]) {
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
            tester.view.physicalSize = Size(width, 700);
            await tester.pumpWidget(
              MaterialApp(
                theme: buildFaTheme(
                  direction: direction,
                  brightness: brightness,
                ),
                home: Scaffold(
                  body: FileBrowser(
                    env: env,
                    uploadPicker: _FakePicker(const []),
                    iCloudSyncService: _FakeICloudSync(),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            if (width < 600) {
              await tester.tap(
                find.byKey(const ValueKey('fileBrowserSearchReveal')),
              );
              await tester.pumpAndSettle();
            }
            final reason = '$direction $brightness at $width';
            // ONE band: the search capsule always fills the header, and
            // its width grows with the band — the desktop minimum holds
            // on a roomy band, and a cramped band gives the capsule
            // everything between its neighbors.
            final capsule = tester.getRect(
              find.byKey(const ValueKey('fileBrowserSearch')),
            );
            expect(
              capsule.width,
              width >= 800
                  ? greaterThanOrEqualTo(220)
                  : greaterThanOrEqualTo(160),
              reason: reason,
            );
            // The title yields to the capsule: shown out of the surplus
            // on a roomy band (never squeezed under a 24px strip), hidden
            // entirely on a cramped one.
            final titleFinder = find.descendant(
              of: find.byKey(const ValueKey('fileBrowserHeader')),
              matching: find.text('Files'),
            );
            if (width >= 800) {
              final title = tester.widget<Text>(titleFinder);
              expect(title.maxLines, 1, reason: reason);
              expect(title.overflow, TextOverflow.ellipsis, reason: reason);
              expect(
                tester.getRect(titleFinder).height,
                lessThan(24),
                reason: reason,
              );
            } else {
              expect(titleFinder, findsNothing, reason: reason);
            }
            expect(
              tester
                  .getSize(
                    find.byKey(const ValueKey('fileBrowserBreadcrumbChip')),
                  )
                  .height,
              28,
              reason: reason,
            );

            final panel = tester.widget<Material>(
              find.byKey(const ValueKey('fileBrowserPanel')),
            );
            final colors = FahColors.of(
              tester.element(find.byType(FileBrowser)),
            );
            expect(panel.color, colors.panel, reason: reason);
            // Groups are messenger-style section eyebrows over chat-density
            // rows — no slab cards anymore.
            final sections = {
              'fileBrowserFoldersCard': 'Folders',
              'fileBrowserFilesCard': 'Files',
            };
            for (final entry in sections.entries) {
              final eyebrow = tester.widget<FaSectionEyebrow>(
                find.byKey(ValueKey(entry.key)),
              );
              expect(eyebrow.label, entry.value, reason: reason);
            }
            // Rows: 12px-rounded transparent rows that fill on hover, with
            // 10px content insets (the chat list's visual density).
            final row = find.byKey(const ValueKey('fileRow-zzz_dir'));
            final rowMaterial = tester.widget<Material>(row);
            expect(rowMaterial.color, Colors.transparent, reason: reason);
            final rowShape = rowMaterial.shape as RoundedSuperellipseBorder;
            expect(
              rowShape.borderRadius.resolve(TextDirection.ltr).topLeft,
              const Radius.circular(12),
              reason: reason,
            );
            final rowInk = tester.widget<InkWell>(
              find.descendant(of: row, matching: find.byType(InkWell)).first,
            );
            expect(rowInk.hoverColor, colors.panelAlt, reason: reason);
            expect(tester.getSize(row).height, 48, reason: reason);
            final rowTitle = tester
                .widgetList<Text>(
                  find.descendant(of: row, matching: find.byType(Text)),
                )
                .first;
            expect(rowTitle.maxLines, 1, reason: reason);
            expect(rowTitle.style?.fontSize, 14, reason: reason);
            // The chrome band is glass in the glass direction (graduated
            // blur under the controls, rows scroll beneath) and flat panel
            // color in the opaque directions.
            expect(
              find.byKey(const ValueKey('fileBrowserChromeUnderlay')),
              direction == FaVisualDirection.glass
                  ? findsOneWidget
                  : findsNothing,
              reason: reason,
            );
            if (width >= 800) {
              Finder action(String key) =>
                  find.byKey(ValueKey('fileBrowser$key'));
              final upload = action('Upload');
              final sync = action('ICloudSync');
              final refresh = action('Refresh');
              for (final finder in [upload, sync, refresh]) {
                expect(
                  tester.getSize(finder),
                  const Size.square(36),
                  reason: reason,
                );
              }
              // Priority order inside ONE capsule: refresh, upload, sync.
              expect(
                tester.getRect(upload).left - tester.getRect(refresh).right,
                0,
                reason: reason,
              );
              expect(
                tester.getRect(sync).left - tester.getRect(upload).right,
                0,
                reason: reason,
              );
              final band = find
                  .ancestor(
                    of: refresh,
                    matching: find.byType(FaIconActionBand<int>),
                  )
                  .first;
              expect(
                find.descendant(
                  of: band,
                  matching: find.byType(FaHeaderCircularAction),
                ),
                findsNothing,
                reason: reason,
              );
              final material = tester.widget<Material>(
                find
                    .descendant(of: band, matching: find.byType(Material))
                    .first,
              );
              final tokens = FaDesignTokens.of(tester.element(refresh));
              expect(material.color, tokens.surface2, reason: reason);
              expect(
                material.shape,
                isA<RoundedSuperellipseBorder>(),
                reason: reason,
              );
              final shape = material.shape! as RoundedSuperellipseBorder;
              expect(shape.side.color, tokens.hairline, reason: reason);
              expect(
                shape.borderRadius.resolve(TextDirection.ltr).topLeft,
                const Radius.circular(20),
                reason: reason,
              );
            } else {
              // A middle-width band keeps the actions reachable through
              // the ⋮ menu while the capsule keeps its floor.
              expect(
                find.byKey(const ValueKey('fileBrowserOverflow')),
                findsOneWidget,
                reason: reason,
              );
            }

            final overflow = find.byKey(const ValueKey('fileBrowserOverflow'));
            if (overflow.evaluate().isNotEmpty) {
              await tester.tap(overflow);
              await tester.pumpAndSettle();
            }
            for (final label in [
              'Upload files here',
              'Sync sessions and apps with iCloud',
              'Refresh',
            ]) {
              final inline = find.byTooltip(label).evaluate().isNotEmpty;
              expect(
                inline || find.text(label).evaluate().isNotEmpty,
                isTrue,
                reason: '$label reachable: $reason',
              );
            }
            if (overflow.evaluate().isNotEmpty &&
                find.byTooltip('Refresh').evaluate().isEmpty) {
              await tester.tap(find.text('Refresh'));
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull, reason: reason);
          }
        }
      }
    });

    testWidgets('folder tap navigates; up button and breadcrumb return', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('zzz_dir'));
      await tester.pumpAndSettle();
      expect(_listedNames(tester), ['inner.txt']);

      // Up button returns to the root.
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();
      expect(find.text('aaa.txt'), findsOneWidget);

      // Breadcrumb root crumb returns to the root as well.
      await tester.tap(find.text('zzz_dir'));
      await tester.pumpAndSettle();
      expect(find.text('inner.txt'), findsOneWidget);
      await tester.tap(find.text('/'));
      await tester.pumpAndSettle();
      expect(find.text('aaa.txt'), findsOneWidget);
    });

    testWidgets('band chrome: the close circle LEADS the search capsule; '
        'capsule and grouped action targets share the composer scale', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env, onClose: () {})));
      await tester.pumpAndSettle();

      // The panel's own X is the visible close affordance, sitting
      // immediately LEFT of the search capsule (the collapse/expand
      // pattern: the same button flips to an X next to "search files").
      final close = tester.getRect(find.byKey(const ValueKey('filesAppClose')));
      final capsule = tester.getRect(
        find.byKey(const ValueKey('fileBrowserSearch')),
      );
      expect(close.right, lessThan(capsule.left));
      expect(capsule.left - close.right, 8);
      // The band renders the ONE SessionSearchField at the restored
      // sidebar-search height — the dense 32px inset, the same field the
      // chats/activity/apps headers render (user call: search files was
      // to become search chats, not the other way around).
      expect(capsule.height, kSearchFieldHeight);
      // The standalone close circle and grouped action hit targets share
      // the composer scale (shrunken from the chat header's 40pt chrome),
      // but only close owns an individual circle.
      final closeCircle = find
          .ancestor(
            of: find.byKey(const ValueKey('filesAppClose')),
            matching: find.byType(FaHeaderCircularAction),
          )
          .first;
      final refresh = find.byKey(const ValueKey('fileBrowserRefresh'));
      expect(tester.getSize(closeCircle), const Size.square(36));
      expect(tester.getSize(refresh), const Size.square(36));
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: refresh,
                matching: find.byIcon(Icons.refresh),
              ),
            )
            .size,
        18,
      );

      // P2 render-box audit (the "capsule still tiny" report was shot on
      // the pre-SizedBox build where the field painted its ~17.5pt
      // intrinsic box ~21px above the circles' centers). The envelope is
      // not enough — the kit field's painted surface (the whole
      // GlassTextField box the glass/solid well draws into) must occupy the
      // full box height, and the capsule's center must sit exactly on the
      // circles' centers.
      final fieldRect = tester.getRect(
        find
            .descendant(
              of: find.byKey(const ValueKey('fileBrowserSearch')),
              matching: find.byType(GlassTextField),
            )
            .first,
      );
      expect(
        fieldRect.height,
        kSearchFieldHeight,
        reason: 'kit field surface height',
      );
      expect(
        fieldRect.center.dy,
        moreOrLessEquals(close.center.dy, epsilon: 0.5),
        reason: 'capsule center on the close circle center',
      );
      expect(
        fieldRect.center.dy,
        moreOrLessEquals(tester.getRect(refresh).center.dy, epsilon: 0.5),
        reason: 'capsule center on the refresh action center',
      );
      // The editable text inside paints within the capsule, vertically
      // centered in it (the visual "tiny strip above the buttons" guard:
      // the pre-fix field laid its text out at the capsule's very top).
      final editableRect = tester.getRect(find.byType(EditableText).first);
      expect(
        editableRect.center.dy,
        moreOrLessEquals(close.center.dy, epsilon: 0.5),
      );
      expect(editableRect.top, greaterThanOrEqualTo(fieldRect.top));
      expect(editableRect.bottom, lessThanOrEqualTo(fieldRect.bottom));
    });

    testWidgets('breadcrumbs: one line, ellipsized, vertically centered in '
        'the path chip', (tester) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('zzz_dir'));
      await tester.pumpAndSettle();

      final chip = tester.getRect(
        find.byKey(const ValueKey('fileBrowserBreadcrumbChip')),
      );
      for (final label in <String>['/', 'zzz_dir']) {
        final crumb = tester.widget<Text>(find.text(label));
        expect(crumb.maxLines, 1, reason: label);
        expect(crumb.overflow, TextOverflow.ellipsis, reason: label);
        final rect = tester.getRect(find.text(label));
        expect(rect.center.dy, chip.center.dy, reason: label);
        expect(rect.top, greaterThanOrEqualTo(chip.top), reason: label);
        expect(rect.bottom, lessThanOrEqualTo(chip.bottom), reason: label);
      }
    });

    testWidgets('tapping a text file previews its content inline', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(_selectableText('hello notes'), findsOneWidget);

      // Back button returns to the listing.
      await tester.tap(find.byTooltip('Back to files'));
      await tester.pumpAndSettle();
      expect(find.text('aaa.txt'), findsOneWidget);
    });

    testWidgets('tapping an image file renders an Image preview', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      // runAsync lets the real image codec complete outside the fake zone.
      await tester.runAsync(() async {
        await tester.tap(find.text('logo.png'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      });
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('binary file falls back to an info placeholder', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('blob.bin'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No preview available'), findsOneWidget);
      expect(find.textContaining('4 B'), findsOneWidget);
    });

    testWidgets('empty folder shows a polite empty state', (tester) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('empty_dir'));
      await tester.pumpAndSettle();
      expect(find.text('Empty folder'), findsOneWidget);
    });

    testWidgets('retry is the styleguide secondary FaButton', (tester) async {
      // cwd '/missing' is never created, so listing '.' reports notFound.
      final env = MemoryExecutionEnv(cwd: '/missing');
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      final retry = tester.widget<FaButton>(
        find.ancestor(of: find.text('Retry'), matching: find.byType(FaButton)),
      );
      expect(retry.variant, FaButtonVariant.secondary);
      expect(retry.icon, Icons.refresh);
    });

    testWidgets('inline preview swaps into the chrome band, not a second row', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filePreviewHeader')), findsOneWidget);
      expect(find.byKey(const ValueKey('fileBrowserPathBar')), findsNothing);
      await tester.tap(find.byTooltip('Back to files'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filePreviewHeader')), findsNothing);
      expect(find.byKey(const ValueKey('fileBrowserPathBar')), findsOneWidget);
    });

    testWidgets('path bar up button shares the header action chrome', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('zzz_dir'));
      await tester.pumpAndSettle();
      final up = find
          .ancestor(
            of: find.byIcon(Icons.arrow_upward),
            matching: find.byType(FaHeaderCircularAction),
          )
          .first;
      expect(tester.getSize(up), const Size.square(36));
      final material = tester.widget<Material>(
        find.descendant(of: up, matching: find.byType(Material)).first,
      );
      expect(material.color, FaDesignTokens.of(tester.element(up)).surface2);
      expect(material.shape, isA<CircleBorder>());
    });

    testWidgets('listing failure shows an error state with retry', (
      tester,
    ) async {
      // cwd '/missing' is never created, so listing '.' reports notFound.
      final env = MemoryExecutionEnv(cwd: '/missing');
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      expect(find.text('Could not open folder'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('FileBrowser upload', () {
    testWidgets('uploaded files land in the currently viewed folder', (
      tester,
    ) async {
      final env = await _seededEnv();
      final picker = _FakePicker([
        _uploadFile('new.txt', 'brand new'),
        _uploadFile('sub/deep.txt', 'nested upload'),
      ]);
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, uploadPicker: picker)),
      );
      await tester.pumpAndSettle();

      // Navigate into zzz_dir and upload there.
      await tester.tap(find.text('zzz_dir'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Upload files here'));
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      // The listing refreshed with the new entries…
      expect(_listedNames(tester), ['sub', 'inner.txt', 'new.txt']);
      // …and the files really live in the agent's filesystem.
      expect(
        (await env.readTextFile('zzz_dir/new.txt')).getOrThrow(),
        'brand new',
      );
      expect(
        (await env.readTextFile('zzz_dir/sub/deep.txt')).getOrThrow(),
        'nested upload',
      );
      expect(find.text('Uploaded 2 files'), findsOneWidget);
    });

    testWidgets('root upload writes into the sandbox root', (tester) async {
      final env = await _seededEnv();
      final picker = _FakePicker([_uploadFile('root.txt', 'at root')]);
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, uploadPicker: picker)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Upload files here'));
      await tester.pumpAndSettle();

      expect((await env.readTextFile('root.txt')).getOrThrow(), 'at root');
      expect(find.text('root.txt'), findsOneWidget);
    });

    testWidgets('an SVG uploads like any other file (regression: file-tree '
        'SVG upload)', (tester) async {
      final env = await _seededEnv();
      final picker = _FakePicker([
        _uploadFile('icon.svg', '<svg xmlns="http://www.w3.org/2000/svg"/>'),
      ]);
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, uploadPicker: picker)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Upload files here'));
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      expect(find.text('Uploaded 1 file'), findsOneWidget);
      expect(
        (await env.readTextFile('icon.svg')).getOrThrow(),
        '<svg xmlns="http://www.w3.org/2000/svg"/>',
      );
      expect(find.text('icon.svg'), findsOneWidget);
    });

    testWidgets('files with no usable name fail loudly, with the name in '
        'the snackbar', (tester) async {
      final env = await _seededEnv();
      final picker = _FakePicker([
        _uploadFile('..', 'traversal'),
        _uploadFile('ok.txt', 'fine'),
      ]);
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, uploadPicker: picker)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Upload files here'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Uploaded 1 file'), findsOneWidget);
      expect(find.textContaining('1 failed: ..'), findsOneWidget);
      expect((await env.readTextFile('ok.txt')).getOrThrow(), 'fine');
    });

    testWidgets('an oversized batch is refused before anything is written', (
      tester,
    ) async {
      final env = await _seededEnv();
      final picker = _FakePicker([
        _uploadFile('big.bin', '0123456789'),
        _uploadFile('overflow.bin', 'x'),
      ]);
      await tester.pumpWidget(
        _wrap(
          FileBrowser(env: env, uploadPicker: picker, maxUploadBatchBytes: 10),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Upload files here'));
      await tester.pumpAndSettle();

      expect(find.textContaining('too large'), findsOneWidget);
      expect((await env.exists('big.bin')).getOrThrow(), isFalse);
      expect((await env.exists('overflow.bin')).getOrThrow(), isFalse);
    });

    testWidgets('host default: the native picker wires the upload button '
        '(issue #1979 — createUploadPicker is the file_selector-backed '
        'IoUploadPicker on VM builds)', (tester) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();
      expect(createUploadPicker(), isNotNull);
      expect(find.byTooltip('Upload files here'), findsOneWidget);
    });

    test('uploadBatchSizeError enforces the cap over the batch total', () {
      expect(uploadBatchSizeError([_uploadFile('a', 'x')]), isNull);
      expect(
        uploadBatchSizeError([_uploadFile('a', 'x' * kMaxUploadBatchBytes)]),
        isNull,
      );
      final over = uploadBatchSizeError([
        _uploadFile('a', 'x' * kMaxUploadBatchBytes),
        _uploadFile('b', 'y'),
      ]);
      expect(over, contains('too large'));
      expect(over, contains('25.0 MB'));
    });

    test('sanitizeUploadName strips traversal and keeps subdirectories', () {
      expect(sanitizeUploadName('plain.txt'), 'plain.txt');
      expect(sanitizeUploadName('sub/dir/file.txt'), 'sub/dir/file.txt');
      expect(sanitizeUploadName('../../etc/passwd'), 'etc/passwd');
      expect(sanitizeUploadName('..'), isEmpty);
      expect(sanitizeUploadName(r'a\b\c.txt'), 'a/b/c.txt');
      expect(sanitizeUploadName('./dot/./file.txt'), 'dot/file.txt');
    });
  });

  group('FileBrowser rich previews', () {
    testWidgets('markdown renders formatted; Source shows the raw file', (
      tester,
    ) async {
      const raw = '# Title\n\nSome **bold** text\n\n- one\n- two\n';
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('readme.md'));
      await tester.pumpAndSettle();

      // Default pane is the formatted preview: the heading is an
      // h1-styled selectable rich text, not the raw '# Title' source.
      // The shared fa_ui markdown sheet scales headings off the body size
      // (h1 = 2x bodyMedium), not the theme's headline styles.
      final context = tester.element(find.byType(FilePreviewView));
      final theme = Theme.of(context);
      final heading = tester.widget<SelectableText>(
        _selectableRichText('Title'),
      );
      expect(
        heading.textSpan!.style?.fontSize,
        theme.textTheme.bodyMedium!.fontSize! * 2,
      );
      expect(
        heading.textSpan!.style?.fontSize,
        greaterThan(theme.textTheme.bodyMedium!.fontSize!),
      );

      // Bold renders as a bold span inside the paragraph, no asterisks.
      final paragraph = tester.widget<SelectableText>(
        _selectableRichText('Some bold text'),
      );
      final spans = paragraph.textSpan!.children!.whereType<TextSpan>();
      final bold = spans.singleWhere((span) => span.text == 'bold');
      expect(bold.style?.fontWeight, FontWeight.bold);

      // Raw markdown is nowhere until Source is selected.
      expect(_selectableText(raw), findsNothing);
      await tester.tap(find.text('Source'));
      await tester.pumpAndSettle();
      expect(_selectableText(raw), findsOneWidget);
      expect(_selectableRichText('Title'), findsNothing);

      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(_selectableRichText('Title'), findsOneWidget);
    });

    testWidgets('html preview renders via the injected builder; Source shows '
        'raw markup', (tester) async {
      const raw = '<h1>Hi</h1><p>para</p>';
      final env = await _seededEnv();
      await tester.pumpWidget(
        _wrap(
          FileBrowser(
            env: env,
            // The host test runner has no webview platform implementation,
            // so a fake stands in for the real HtmlFilePreview and records
            // the markup it was asked to render. The real webview is
            // exercised on device; the web iframe path is covered by
            // `flutter build web` compiling html_preview_web.dart.
            htmlPreviewBuilder: (context, html) => ColoredBox(
              color: const Color(0xFF112233),
              child: Center(child: Text('webview: $html')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('page.html'));
      await tester.pumpAndSettle();

      expect(find.text('webview: $raw'), findsOneWidget);

      await tester.tap(find.text('Source'));
      await tester.pumpAndSettle();
      expect(_selectableText(raw), findsOneWidget);
      expect(find.text('webview: $raw'), findsNothing);

      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('webview: $raw'), findsOneWidget);
    });
  });

  group('FileBrowser fsRevision auto-refresh', () {
    testWidgets('a write tool result bumps fsRevision and refreshes the '
        'current listing', (tester) async {
      final env = await _seededEnv();
      final service = _toolService(env, [
        _toolTurn([
          const ToolCall(
            id: 'c1',
            name: 'write',
            arguments: {'path': 'agent.md', 'content': '# by agent'},
          ),
        ]),
        _textTurn('done'),
      ]);
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, fsRevision: service.fsRevision)),
      );
      await tester.pumpAndSettle();
      expect(find.text('agent.md'), findsNothing);

      // runAsync: the agent loop consumes a real event stream, which the
      // widget test's fake-async zone would starve.
      await tester.runAsync(() async {
        await service.sendText('go');
        await service.waitForIdle();
      });
      await tester.pumpAndSettle();

      expect(service.fsRevision.value, 1);
      expect(find.text('agent.md'), findsOneWidget);
    });

    testWidgets('an open preview reloads when the agent rewrites the viewed '
        'file', (tester) async {
      final env = await _seededEnv();
      final service = _toolService(env, [
        _toolTurn([
          const ToolCall(
            id: 'c1',
            name: 'write',
            arguments: {'path': 'notes.txt', 'content': 'changed by agent'},
          ),
        ]),
        _textTurn('done'),
      ]);
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, fsRevision: service.fsRevision)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(_selectableText('hello notes'), findsOneWidget);

      // runAsync: the agent loop consumes a real event stream, which the
      // widget test's fake-async zone would starve.
      await tester.runAsync(() async {
        await service.sendText('go');
        await service.waitForIdle();
      });
      await tester.pumpAndSettle();

      expect(_selectableText('changed by agent'), findsOneWidget);
    });

    test(
      'a bash tool result bumps fsRevision even when the shell errors',
      () async {
        // MemoryExecutionEnv has no shell, so bash returns an error result;
        // a partially-run command could still have mutated files, so the
        // bump fires on any bash completion.
        final env = await _seededEnv();
        final service = _toolService(env, [
          _toolTurn([
            const ToolCall(
              id: 'c1',
              name: 'bash',
              arguments: {'command': 'echo hi'},
            ),
          ]),
          _textTurn('done'),
        ]);

        await service.sendText('go');
        await service.waitForIdle();

        expect(service.fsRevision.value, 1);
      },
    );

    test('a read-only tool result does not bump fsRevision', () async {
      final env = await _seededEnv();
      final service = _toolService(env, [
        _toolTurn([
          const ToolCall(
            id: 'c1',
            name: 'read',
            arguments: {'path': 'notes.txt'},
          ),
        ]),
        _textTurn('done'),
      ]);

      await service.sendText('go');
      await service.waitForIdle();

      expect(service.fsRevision.value, 0);
    });
  });

  group('Files chrome band', () {
    /// The shared band as the presented panes render it: header on, a
    /// close circle (the panel's own X), a narrow 300px docked width.
    FileBrowser band(MemoryExecutionEnv env) =>
        FileBrowser(env: env, onClose: () {});

    Future<void> pumpBand(
      WidgetTester tester,
      MemoryExecutionEnv env, {
      double width = 300,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, height: 600, child: band(env)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets("the band X sits ~4pt from the band's left edge", (
      tester,
    ) async {
      await pumpBand(tester, await _seededEnv());
      // At the docked 300px width the title is squeezed out, so the X is
      // the band's leading control.
      final browserLeft = tester
          .getTopLeft(find.byKey(const ValueKey('fileBrowserPanel')))
          .dx;
      final closeLeft = tester
          .getTopLeft(find.byKey(const ValueKey('filesAppClose')))
          .dx;
      expect(closeLeft - browserLeft, 4);
    });

    testWidgets("the search capsule mirrors the chat composer's field "
        'height', (tester) async {
      final env = await _seededEnv();
      // The composer's single-line field row IS the reference: its 36px
      // control + 2+2px row padding (faChatComposerFieldRow). Pump the
      // real composer next to the band and compare live sizes, so a
      // composer geometry change cannot silently desync the band.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  height: 120,
                  child: ChatComposer(
                    service: _fakeService(env),
                    autofocus: false,
                  ),
                ),
                Expanded(child: band(env)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final composerRow = tester.getSize(
        find.byKey(const ValueKey('faChatComposerFieldRow')),
      );
      final capsule = tester.getSize(
        find.byKey(const ValueKey('fileBrowserSearch')),
      );
      // The band field is the ONE shared SessionSearchField — the old
      // sidebar-search 32px inset (the composer's 40px row is its own
      // thing; the retired Files capsule no longer mirrors it).
      expect(capsule.height, kSearchFieldHeight);
      expect(capsule.height, isNot(composerRow.height));
    });
  });

  group('FileBrowser initialPath', () {
    testWidgets('absolute session path opens the listing in that folder', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      await env.writeFile('root-only.txt', 'at the env root');
      await env.writeFile('sessions/demo/notes.md', '# demo');
      await env.createDir('sessions/demo/sub');
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, initialPath: '/sessions/demo')),
      );
      await tester.pumpAndSettle();
      // The FIRST listing is the session folder — its own files, not the
      // env root's.
      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('sub'), findsOneWidget);
      expect(find.text('root-only.txt'), findsNothing);
      // The breadcrumb carries the session folder's segments.
      expect(find.byTooltip('Up'), findsOneWidget);
    });

    testWidgets('a relative initial path resolves against the env cwd', (
      tester,
    ) async {
      final env = MemoryExecutionEnv(cwd: '/sessions/demo');
      await env.writeFile('notes.md', '# demo');
      await env.writeFile('sub/deep.txt', 'deeper');
      await tester.pumpWidget(_wrap(FileBrowser(env: env, initialPath: 'sub')));
      await tester.pumpAndSettle();
      expect(find.text('deep.txt'), findsOneWidget);
      expect(find.text('notes.md'), findsNothing);
    });

    testWidgets('an initial path equal to the env cwd keeps the root '
        'listing', (tester) async {
      final env = MemoryExecutionEnv(cwd: '/sessions/demo');
      await env.writeFile('notes.md', '# demo');
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, initialPath: '/sessions/demo')),
      );
      await tester.pumpAndSettle();
      expect(find.text('notes.md'), findsOneWidget);
      // The breadcrumb sits at the root crumb — no session subfolder.
      expect(find.text('/'), findsOneWidget);
      expect(find.text('demo'), findsNothing);
    });
  });

  group('ChatScreen integration', () {
    testWidgets('wide surface: Files icon toggles the right files panel', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);

      final env = await _seededEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(manager: _fakeManager(env))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsNothing);

      await tester.tap(find.byTooltip('Open files'));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      // The panel is docked on the RIGHT edge of the surface, FLUSH
      // against the transcript (no divider), and the floating chat
      // header belongs ONLY to the remaining center content.
      expect(tester.getTopLeft(find.byType(FileBrowser)).dx, greaterThan(1000));
      final header = tester.getRect(
        find.byKey(const ValueKey('faChatFloatingHeader')),
      );
      final panel = tester.getRect(
        find.byKey(const ValueKey('faChatFilesPanel')),
      );
      expect(panel.width, 300);
      expect(header.right, panel.left);
      expect(
        find.byKey(const ValueKey('faChatFilesPanelResizeHandle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('faChatFloatingHeader')),
        findsOneWidget,
      );
      final title = tester.getRect(
        find.byKey(const ValueKey('faChatHeaderTitlePill')),
      );
      expect(title.right, lessThanOrEqualTo(panel.left));
      expect(title.left, greaterThanOrEqualTo(header.left));
      // Toggle-as-part-of-panel: the header Files entry hides while the
      // panel is open (the band's X is the visible toggle), and no
      // divider renders between the transcript and the panel.
      expect(find.byTooltip('Open files'), findsNothing);
      expect(find.byType(VerticalDivider), findsNothing);
      expect(find.byKey(const ValueKey('filesAppClose')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('filesAppClose')));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsNothing);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('faChatFloatingHeader')))
            .right,
        1400,
      );
    });

    testWidgets('wide Files panel drag is live, clamped, and retained', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      final env = await _seededEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(manager: _fakeManager(env))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open files'));
      await tester.pumpAndSettle();

      final handle = find.byKey(const ValueKey('faChatFilesPanelResizeHandle'));
      final panel = find.byKey(const ValueKey('faChatFilesPanel'));
      final header = find.byKey(const ValueKey('faChatFloatingHeader'));
      void expectBoundary(double browserWidth) {
        expect(handle, findsOneWidget);
        final panelRect = tester.getRect(panel);
        expect(panelRect.width, browserWidth);
        expect(tester.getRect(header).right, panelRect.left);
        expect(
          tester
              .getRect(find.byKey(const ValueKey('faChatFloatingComposer')))
              .right,
          lessThanOrEqualTo(panelRect.left - 8),
        );
        expect(tester.takeException(), isNull);
      }

      expectBoundary(300);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      expectBoundary(360);
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      expectBoundary(420);
      await gesture.up();
      await tester.pumpAndSettle();
      expectBoundary(420);

      // While the panel is open the header's Files entry is hidden — the
      // band's X is the close toggle.
      await tester.tap(find.byKey(const ValueKey('filesAppClose')));
      await tester.pumpAndSettle();
      expect(handle, findsNothing);
      await tester.tap(find.byTooltip('Open files'));
      await tester.pumpAndSettle();
      expectBoundary(420);

      await tester.drag(handle, const Offset(-200, 0));
      await tester.pump();
      expectBoundary(520);
      await tester.drag(handle, const Offset(400, 0));
      await tester.pump();
      expectBoundary(240);
      await tester.drag(handle, const Offset(-400, 0));
      await tester.pumpAndSettle();
      expectBoundary(520);

      tester.view.physicalSize = const Size(900, 900);
      await tester.pumpAndSettle();
      expectBoundary(520);
      expect(tester.getRect(panel).left, 380);
    });

    testWidgets('max Files width degrades safely inside a sidebar-narrowed '
        'center', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      final env = await _seededEnv();
      final manager = _fakeManager(env);
      Widget app(double centerWidth) => MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: centerWidth,
            height: 900,
            child: ChatScreen(manager: manager),
          ),
        ),
      );

      await tester.pumpWidget(app(900));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open files'));
      await tester.pumpAndSettle();
      final handle = find.byKey(const ValueKey('faChatFilesPanelResizeHandle'));
      await tester.drag(handle, const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('faChatFilesPanel'))).width,
        520,
      );

      for (final width in <double>[
        700,
        600,
        561,
        560,
        500,
        420,
        320,
        561,
        700,
        900,
      ]) {
        await tester.pumpWidget(app(width));
        // One layout frame at a time mirrors live window/sidebar transitions.
        await tester.pump();
        final header = tester.getRect(
          find.byKey(const ValueKey('faChatFloatingHeader')),
        );
        final panel = find.byKey(const ValueKey('faChatFilesPanel'));
        if (panel.evaluate().isEmpty) {
          expect(header.right, width, reason: 'center=$width');
        } else {
          expect(header.right, tester.getRect(panel).left);
          expect(
            tester.getRect(panel).left - header.left,
            greaterThanOrEqualTo(320),
          );
        }
        expect(tester.takeException(), isNull, reason: 'center=$width');
      }
    });

    testWidgets('narrow surface: Files icon opens the files end drawer; file '
        'tap pushes a preview route', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(500, 900);
      addTearDown(tester.view.reset);

      final env = await _seededEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(manager: _fakeManager(env))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsNothing);

      await tester.tap(find.byTooltip('Open files'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.byType(FileBrowser), findsOneWidget);
      expect(
        find.byKey(const ValueKey('faChatFilesPanelResizeHandle')),
        findsNothing,
      );
      expect(tester.widget<Drawer>(find.byType(Drawer)).width, 300);

      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(find.byType(FilePreviewScreen), findsOneWidget);
      expect(_selectableText('hello notes'), findsOneWidget);
    });

    testWidgets('attach sheet stages picked files into uploads/ at once and '
        'holds a pending chip; sending references the path without '
        'auto-sending', (tester) async {
      final env = await _seededEnv();
      final picker = _FakePicker([_uploadFile('chat.txt', 'via chat')]);
      final service = _fakeService(env);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('attach-batch-session', service);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(manager: manager, uploadPicker: picker),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FaAttachGlyph));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach file'));
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      // The file is staged into uploads/ IMMEDIATELY and waits as a
      // pending chip — nothing is sent to the model on attach.
      expect(find.textContaining('chat.txt'), findsOneWidget);
      expect(
        (await env.readTextFile('uploads/chat.txt')).getOrThrow(),
        'via chat',
      );
      expect(service.messages, isEmpty);

      await tester.enterText(find.byType(TextField), 'look at this');
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Send'));
        // The send button fires _send unawaited; poll the transcript until
        // the assistant turn lands on the real event loop.
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (service.messages.length < 2) {
          if (DateTime.now().isAfter(deadline)) {
            fail('timed out waiting for the assistant turn');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      expect(service.messages.first.role, 'user');
      expect(service.messages.first.attachments.single, (
        bytes: null,
        path: 'uploads/chat.txt',
      ));
      expect(service.messages.first.content, contains('look at this'));
      // The chip row cleared after sending.
      expect(find.byTooltip('Remove attachment'), findsNothing);
    });

    testWidgets('a pending chip is removable before sending; the staged '
        'file goes with it', (tester) async {
      final env = await _seededEnv();
      final picker = _FakePicker([
        _uploadFile('one.txt', 'first'),
        _uploadFile('two.txt', 'second'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            manager: _fakeManager(env, 'remove-attachment-session'),
            uploadPicker: picker,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FaAttachGlyph));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach file'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove attachment'), findsNWidgets(2));
      expect((await env.exists('uploads/one.txt')).getOrThrow(), isTrue);
      expect((await env.exists('uploads/two.txt')).getOrThrow(), isTrue);

      await tester.tap(find.byTooltip('Remove attachment').first);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Remove attachment'), findsOneWidget);
      expect(find.textContaining('two.txt'), findsOneWidget);
      // The removed chip's staged file is discarded; the other stays.
      expect((await env.exists('uploads/one.txt')).getOrThrow(), isFalse);
      expect((await env.exists('uploads/two.txt')).getOrThrow(), isTrue);
    });

    testWidgets('attaching an SVG stages it as a plain file reference, '
        'never an inline image', (tester) async {
      final env = await _seededEnv();
      final picker = _FakePicker([
        _uploadFile('icon.svg', '<svg xmlns="http://www.w3.org/2000/svg"/>'),
      ]);
      final service = _fakeService(env);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('svg-session', service);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(manager: manager, uploadPicker: picker),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FaAttachGlyph));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach file'));
      await tester.pumpAndSettle();

      // Generic chip (no Image.memory thumbnail), staged file present.
      expect(find.textContaining('icon.svg'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect((await env.exists('uploads/icon.svg')).getOrThrow(), isTrue);

      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Send'));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (service.messages.length < 2) {
          if (DateTime.now().isAfter(deadline)) {
            fail('timed out waiting for the assistant turn');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      // Issue #461: the reference becomes a file chip in the bubble; the
      // agent-facing line is stripped from the visible text.
      expect(service.messages.first.attachments.single, (
        bytes: null,
        path: 'uploads/icon.svg',
      ));
      expect(service.messages.first.content, isNot(contains('[attached file')));
    });

    testWidgets('a failed send restores the pending chips and the typed '
        'text', (tester) async {
      final env = await _seededEnv();
      final picker = _FakePicker([_uploadFile('chat.txt', 'via chat')]);
      final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
        ..addSession('failed-send-session', _ThrowingSendService(env));
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(manager: manager, uploadPicker: picker),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FaAttachGlyph));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach file'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove attachment'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'look at this');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      // The send failed: the chip and the typed text are handed back, with
      // a snackbar saying why — nothing the user composed is lost.
      expect(find.byTooltip('Remove attachment'), findsOneWidget);
      expect(find.textContaining('chat.txt'), findsWidgets);
      expect(find.textContaining('Could not send'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'look at this',
      );
    });

    testWidgets('a picker failure surfaces a snackbar instead of dying '
        'silently', (tester) async {
      final env = await _seededEnv();
      final picker = _FakePicker(const [])
        ..error = StateError('Could not read broken.bin');
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            manager: _fakeManager(env, 'picker-failure-session'),
            uploadPicker: picker,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FaAttachGlyph));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach file'));
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      expect(find.textContaining('Upload failed'), findsOneWidget);
      expect(find.textContaining('broken.bin'), findsOneWidget);
    });
  });
  group('FileBrowser iCloud sync', () {
    testWidgets('unavailable container shows the guidance snackbar', (
      tester,
    ) async {
      final env = await _seededEnv();
      final sync = _FakeICloudSync(available: false);
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, iCloudSyncService: sync)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sync sessions and apps with iCloud'));
      await tester.pumpAndSettle();

      expect(find.textContaining('iCloud sync is unavailable'), findsOneWidget);
      expect(sync.syncCalls, isZero);
    });

    testWidgets('a finished merge reports the copied files and reloads', (
      tester,
    ) async {
      final env = await _seededEnv();
      final sync = _FakeICloudSync();
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, iCloudSyncService: sync)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sync sessions and apps with iCloud'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Synced 2 files'), findsOneWidget);
      expect(sync.syncCalls, 1);
    });

    testWidgets('a failed merge shows the failure snackbar', (tester) async {
      final env = await _seededEnv();
      final sync = _FakeICloudSync(error: StateError('boom'));
      await tester.pumpWidget(
        _wrap(FileBrowser(env: env, iCloudSyncService: sync)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Sync sessions and apps with iCloud'));
      await tester.pumpAndSettle();

      expect(find.textContaining('iCloud sync failed'), findsOneWidget);
    });
  });
}
