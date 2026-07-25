// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [AsrApi] — widget tests never touch the real method channel.
final class _FakeAsrApi implements AsrApi {
  bool granted = true;
  int requestAccessCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  final readPaths = <String>[];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async {
    requestAccessCalls++;
    return granted;
  }

  @override
  Future<void> startRecording() async {
    startCalls++;
  }

  @override
  Future<AsrRecording> stopRecording() async {
    stopCalls++;
    return (path: '/tmp/fah-mic-test.m4a', durationMs: 5000, sampleRate: 44100);
  }

  @override
  Future<Uint8List> readRecording(String path) async {
    readPaths.add(path);
    return Uint8List.fromList(const [1, 2, 3]);
  }
}

/// Fake [AsrTranscriber] returning a fixed transcript.
final class _FakeAsrTranscriber implements AsrTranscriber {
  String transcript = 'hello world';

  @override
  Future<String> transcribe({
    required Uint8List bytes,
    required String filename,
    String? language,
  }) async => transcript;
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

FlutterSessionManager _fakeManager(ExecutionEnv env) {
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  manager.addSession(
    'fake-session',
    AgentService(
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
      config: AgentConfig(
        providerKind: 'test',
        modelId: 'test-model',
        baseUrl: 'https://example.com',
        apiKey: '',
      ),
    ),
  );
  return manager;
}

String _composerText(WidgetTester tester) {
  for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
    final text = field.controller?.text ?? '';
    if (text.isNotEmpty) return text;
  }
  return '';
}

void main() {
  void useWideSurface(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
  }

  testWidgets('mic button records on tap, stops + transcribes on the '
      'second tap, and inserts the transcript', (tester) async {
    useWideSurface(tester);
    final env = MemoryExecutionEnv();
    final asr = _FakeAsrApi();
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          manager: _fakeManager(env),
          asr: asr,
          asrTranscriber: _FakeAsrTranscriber(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Idle state: a plain mic button.
    expect(find.byIcon(Icons.mic_none), findsOneWidget);

    // First tap: permission granted, recording starts, the button turns
    // into the red stop state.
    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.pump();
    expect(asr.requestAccessCalls, 1);
    expect(asr.startCalls, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.mic), findsOneWidget);

    // Second tap: stop → transcribe → the transcript lands in the input.
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(asr.stopCalls, 1);
    expect(asr.readPaths, ['/tmp/fah-mic-test.m4a']);
    expect(_composerText(tester), 'hello world');
    // Back to idle.
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });

  testWidgets('denied microphone access shows the settings snackbar and '
      'never records', (tester) async {
    useWideSurface(tester);
    final env = MemoryExecutionEnv();
    final asr = _FakeAsrApi()..granted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          manager: _fakeManager(env),
          asr: asr,
          asrTranscriber: _FakeAsrTranscriber(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(asr.requestAccessCalls, 1);
    expect(asr.startCalls, 0);
    expect(find.textContaining('Microphone access was denied'), findsOneWidget);
    expect(
      find.textContaining('Privacy & Security → Microphone'),
      findsOneWidget,
    );
    // Let the snackbar's display timer run out before the tree is torn down.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('without an ASR-capable endpoint the snackbar says what to '
      'configure', (tester) async {
    useWideSurface(tester);
    final env = MemoryExecutionEnv();
    final asr = _FakeAsrApi();
    // No asrTranscriber injected and the fake provider kind ('test') is
    // not OpenAI-compatible — the transcriber resolves to none.
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(manager: _fakeManager(env), asr: asr),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic_none));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(asr.stopCalls, 1);
    expect(find.textContaining('No ASR-capable endpoint'), findsOneWidget);
    // Let the snackbar's display timer run out before the tree is torn down.
    await tester.pump(const Duration(seconds: 4));
  });
}
