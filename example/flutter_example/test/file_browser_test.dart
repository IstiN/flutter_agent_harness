import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/file_browser.dart';
import 'package:flutter_agent_example/file_preview.dart';
import 'package:flutter_agent_example/upload.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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
  (widget) => widget is SelectableText && widget.data == text,
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
      .widgetList<ListTile>(find.byType(ListTile))
      .map((tile) => (tile.title! as Text).data!)
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
      systemPrompt: 'You are fah.',
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
  );
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
      systemPrompt: 'You are fah.',
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
          systemPrompt: 'You are fah.',
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

void main() {
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

    testWidgets('host default: no platform picker, no upload button', (
      tester,
    ) async {
      final env = await _seededEnv();
      await tester.pumpWidget(_wrap(FileBrowser(env: env)));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Upload files here'), findsNothing);
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
      final context = tester.element(find.byType(FilePreviewView));
      final theme = Theme.of(context);
      final heading = tester.widget<SelectableText>(
        _selectableRichText('Title'),
      );
      expect(
        heading.textSpan!.style?.fontSize,
        theme.textTheme.headlineSmall?.fontSize,
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

  group('ChatScreen integration', () {
    testWidgets('wide surface: Files icon toggles the right files panel', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);

      final env = await _seededEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(service: _fakeService(env))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsNothing);

      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      // The panel is docked on the RIGHT edge of the surface.
      expect(tester.getTopLeft(find.byType(FileBrowser)).dx, greaterThan(1000));

      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsNothing);
    });

    testWidgets('narrow surface: Files icon opens the files end drawer; file '
        'tap pushes a preview route', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(500, 900);
      addTearDown(tester.view.reset);

      final env = await _seededEnv();
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(service: _fakeService(env))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsNothing);

      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.byType(FileBrowser), findsOneWidget);

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
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(service: service, uploadPicker: picker),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
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
      expect(
        service.messages.first.content,
        contains('[attached file: uploads/chat.txt — read it with your tools]'),
      );
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
          home: ChatScreen(service: _fakeService(env), uploadPicker: picker),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
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
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(service: service, uploadPicker: picker),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
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

      // Sent as a path reference with no inline image bytes.
      expect(service.messages.first.imageBytes, isNull);
      expect(
        service.messages.first.content,
        contains('[attached file: uploads/icon.svg — read it with your tools]'),
      );
    });

    testWidgets('a failed send restores the pending chips and the typed '
        'text', (tester) async {
      final env = await _seededEnv();
      final picker = _FakePicker([_uploadFile('chat.txt', 'via chat')]);
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            service: _ThrowingSendService(env),
            uploadPicker: picker,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
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
          home: ChatScreen(service: _fakeService(env), uploadPicker: picker),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach file'));
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      expect(find.textContaining('Upload failed'), findsOneWidget);
      expect(find.textContaining('broken.bin'), findsOneWidget);
    });
  });
}
