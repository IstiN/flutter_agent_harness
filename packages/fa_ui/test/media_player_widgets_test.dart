// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeAudioController implements SandboxAudioController {
  _FakeAudioController({
    this.duration = Duration.zero,
    this.position = Duration.zero,
    bool playing = false,
  }) : _playing = playing;

  @override
  final Duration duration;
  @override
  Duration position;
  bool _playing;
  int playCount = 0;
  int pauseCount = 0;
  Duration? seekTo;
  final _playingChanges = StreamController<bool>.broadcast();

  @override
  bool get playing => _playing;

  @override
  Stream<Duration> get positionChanges => const Stream.empty();

  @override
  Stream<Duration> get durationChanges => const Stream.empty();

  @override
  Stream<bool> get playingChanges => _playingChanges.stream;

  @override
  Future<void> play() async {
    playCount++;
    _playing = true;
    _playingChanges.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing = false;
    _playingChanges.add(false);
  }

  @override
  Future<void> seek(Duration newPosition) async {
    position = newPosition;
    seekTo = newPosition;
  }

  @override
  Future<void> dispose() => _playingChanges.close();
}

final class _FakeVideoController implements SandboxVideoController {
  _FakeVideoController({
    this.ready = true,
    bool playing = false,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.muted = false,
    this.surface = const SizedBox.shrink(),
  }) : _playing = playing;

  @override
  final bool ready;
  bool _playing;
  @override
  final Duration duration;
  @override
  final Duration position;
  @override
  bool muted;
  final Widget surface;
  int playCount = 0;
  int pauseCount = 0;
  final List<bool> muteCalls = [];
  final _playingChanges = StreamController<bool>.broadcast();

  @override
  bool get playing => _playing;

  @override
  Stream<bool> get readyChanges => const Stream.empty();

  @override
  Stream<bool> get playingChanges => _playingChanges.stream;

  @override
  Stream<Duration> get positionChanges => const Stream.empty();

  @override
  Future<void> play() async {
    playCount++;
    _playing = true;
    _playingChanges.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing = false;
    _playingChanges.add(false);
  }

  @override
  Future<void> setMuted(bool value) async => muteCalls.add(value);

  @override
  Widget buildSurface(BuildContext context) => surface;

  @override
  Future<void> dispose() => _playingChanges.close();
}

const _surfaceKey = Key('video-surface');

void main() {
  group('sandboxMediaKind', () {
    test('classifies audio extensions (case-insensitive)', () {
      expect(sandboxMediaKind('song.mp3'), SandboxMediaKind.audio);
      expect(sandboxMediaKind('SONG.WAV'), SandboxMediaKind.audio);
      expect(sandboxMediaKind('notes.M4A'), SandboxMediaKind.audio);
    });

    test('classifies video extensions (case-insensitive)', () {
      expect(sandboxMediaKind('clip.mp4'), SandboxMediaKind.video);
      expect(sandboxMediaKind('CLIP.MOV'), SandboxMediaKind.video);
      expect(sandboxMediaKind('take.webm'), SandboxMediaKind.video);
    });

    test('strips a leading slash before reading the extension', () {
      expect(sandboxMediaKind('/media/song.mp3'), SandboxMediaKind.audio);
      expect(sandboxMediaKind('/CLIP.MP4'), SandboxMediaKind.video);
    });

    test('rejects URLs and data URIs regardless of extension', () {
      expect(sandboxMediaKind('https://example.com/song.mp3'), isNull);
      expect(sandboxMediaKind('http://example.com/clip.mp4'), isNull);
      expect(sandboxMediaKind('data:audio/mpeg;base64,AAAA'), isNull);
    });

    test('rejects paths without a known extension', () {
      expect(sandboxMediaKind('no-extension'), isNull);
      expect(sandboxMediaKind('file.txt'), isNull);
      expect(sandboxMediaKind(''), isNull);
    });
  });

  group('SandboxAudioPlayer', () {
    testWidgets('shows a loading panel while bytes are unresolved', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxAudioPlayer(bytes: NeverEndingBytes.future),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.music_off_outlined), findsNothing);
    });

    testWidgets('null bytes degrade to the missing-file line', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxAudioPlayer(bytes: Future<Uint8List?>.value(null)),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.music_off_outlined), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a loaded controller renders the player panel and seeks', (
      tester,
    ) async {
      final controller = _FakeAudioController(
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 90),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxAudioPlayer(
              bytes: Future.value(Uint8List(4)),
              controllerFactory: (bytes) => controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.text('0:30 / 1:30'), findsOneWidget);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.max, 90000);
      expect(slider.onChanged, isNotNull);

      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await tester.pump();
      expect(controller.seekTo, isNotNull);
    });

    testWidgets('tapping play flips the button to pause', (tester) async {
      final controller = _FakeAudioController(
        duration: const Duration(seconds: 90),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxAudioPlayer(
              bytes: Future.value(Uint8List(4)),
              controllerFactory: (bytes) => controller,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();

      expect(controller.playCount, 1);
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      expect(controller.pauseCount, 1);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('an unknown duration disables the slider and shows a playing '
        'state', (tester) async {
      final controller = _FakeAudioController(playing: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxAudioPlayer(
              bytes: Future.value(Uint8List(4)),
              controllerFactory: (bytes) => controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.text('0:00 / 0:00'), findsOneWidget);
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.max, 1);
      expect(slider.onChanged, isNull);
    });
  });

  group('SandboxVideoPlayer', () {
    testWidgets('shows a loading panel while bytes are unresolved', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxVideoPlayer(
              path: 'media/clip.mp4',
              bytes: NeverEndingBytes.future,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('null bytes degrade to the missing-file line', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxVideoPlayer(
              path: 'media/clip.mp4',
              bytes: Future<Uint8List?>.value(null),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.music_off_outlined), findsOneWidget);
    });

    testWidgets('an unready controller shows a spinner with tap disabled', (
      tester,
    ) async {
      final controller = _FakeVideoController(ready: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxVideoPlayer(
              path: 'media/clip.mp4',
              bytes: Future.value(Uint8List(4)),
              controllerFactory: (path, bytes) => controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsNothing);
      final detector = tester.widget<GestureDetector>(
        find.ancestor(
          of: find.byType(CircularProgressIndicator),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(detector.onTap, isNull);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(progress.value, 0);
    });

    testWidgets('a ready paused video shows its surface and the play overlay', (
      tester,
    ) async {
      final controller = _FakeVideoController(
        position: const Duration(seconds: 10),
        duration: const Duration(seconds: 100),
        // A real surface: sized and painted, so taps land inside the
        // player's GestureDetector both with and without the play overlay.
        surface: const ColoredBox(
          key: _surfaceKey,
          color: Color(0xFF223344),
          child: SizedBox(width: 320, height: 180),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxVideoPlayer(
              path: 'media/clip.mp4',
              bytes: Future.value(Uint8List(4)),
              controllerFactory: (path, bytes) => controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(_surfaceKey), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(progress.value, closeTo(0.1, 0.001));

      // The play overlay is the deepest hit target at the surface center;
      // the tap still reaches the wrapping GestureDetector.
      await tester.tap(find.byKey(_surfaceKey), warnIfMissed: false);
      await tester.pump();
      expect(controller.playCount, 1);
      expect(find.byIcon(Icons.play_circle_outline), findsNothing);

      await tester.tap(find.byKey(_surfaceKey));
      await tester.pump();
      expect(controller.pauseCount, 1);
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    });

    testWidgets('the mute button starts from the controller and toggles it', (
      tester,
    ) async {
      final controller = _FakeVideoController(muted: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SandboxVideoPlayer(
              path: 'media/clip.mp4',
              bytes: Future.value(Uint8List(4)),
              controllerFactory: (path, bytes) => controller,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      await tester.tap(find.byIcon(Icons.volume_up));
      await tester.pump();

      expect(controller.muteCalls, [true]);
      expect(find.byIcon(Icons.volume_off), findsOneWidget);
    });
  });
}

/// Bytes that never resolve — keeps the player in its loading state.
class NeverEndingBytes {
  static final Future<Uint8List?> future = Completer<Uint8List?>().future;
}
