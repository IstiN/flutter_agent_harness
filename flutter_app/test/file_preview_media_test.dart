// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/widgets/file_preview.dart';
import 'package:fa/ui/widgets/media_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_media_controllers.dart';

/// File-preview media coverage: audio/video files open in the sandbox
/// players (not the "no preview" placeholder), unknown binaries keep the
/// placeholder.
void main() {
  Future<MemoryExecutionEnv> pumpPreview(
    WidgetTester tester,
    String path,
    List<int> bytes, {
    FakeAudioController? audio,
    FakeVideoController? video,
  }) async {
    final env = MemoryExecutionEnv();
    await env.writeBinaryFile(path, Uint8List.fromList(bytes));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: FilePreviewView(
            env: env,
            path: path,
            name: path.split('/').last,
            audioControllerFactory: audio == null ? null : (_) => audio,
            videoControllerFactory: video == null ? null : (_, _) => video,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // The player's controller factory resolves asynchronously — settle so
    // the duration readout renders.
    await tester.pumpAndSettle();
    return env;
  }

  final mp3Bytes = List<int>.filled(2048, 3);

  testWidgets('mp3 opens the audio player (paused 0:00 / 0:07)', (
    tester,
  ) async {
    await pumpPreview(
      tester,
      'generated/speech-1.mp3',
      mp3Bytes,
      audio: FakeAudioController(),
    );
    expect(find.byType(SandboxAudioPlayer), findsOneWidget);
    expect(find.text('0:00 / 0:07'), findsOneWidget);
    expect(find.textContaining('No preview available'), findsNothing);
  });

  testWidgets('wav opens the audio player too', (tester) async {
    await pumpPreview(
      tester,
      'generated/note.wav',
      mp3Bytes,
      audio: FakeAudioController(),
    );
    expect(find.byType(SandboxAudioPlayer), findsOneWidget);
  });

  testWidgets('mp4 opens the video player', (tester) async {
    await pumpPreview(
      tester,
      'generated/clip.mp4',
      mp3Bytes,
      video: FakeVideoController(),
    );
    expect(find.byType(SandboxVideoPlayer), findsOneWidget);
    expect(find.byType(SandboxAudioPlayer), findsNothing);
  });

  testWidgets('unknown binary keeps the info placeholder', (tester) async {
    final bytes = List<int>.filled(64, 0)..[0] = 1;
    await pumpPreview(tester, 'generated/blob.bin', bytes);
    expect(find.byType(SandboxAudioPlayer), findsNothing);
    expect(find.byType(SandboxVideoPlayer), findsNothing);
    expect(find.textContaining('No preview available'), findsOneWidget);
  });
}
