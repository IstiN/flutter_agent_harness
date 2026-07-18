import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/file_browser.dart';
import 'package:flutter_agent_example/file_preview.dart';
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

  group('ChatScreen integration', () {
    testWidgets('wide surface: Files icon toggles the left panel', (
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

      await tester.tap(find.byTooltip('Files'));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowser), findsNothing);
    });

    testWidgets('narrow surface: Files icon opens a drawer; file tap pushes '
        'a preview route', (tester) async {
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
  });
}
