// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/media_player.dart';
import 'package:flutter/material.dart';

/// Deterministic [SandboxAudioController] for widget/golden tests: paused
/// at 0:00 with a fixed [duration]; play/pause/seek are recorded and emit
/// on the change streams so StreamBuilders rebuild.
class FakeAudioController implements SandboxAudioController {
  /// Creates a fake with a fixed [duration].
  FakeAudioController({this.duration = const Duration(seconds: 7)});

  @override
  Duration position = Duration.zero;

  @override
  final Duration duration;

  @override
  bool playing = false;

  /// Recorded calls, for assertions.
  int playCalls = 0;
  // ignore: public_member_api_docs
  int pauseCalls = 0;
  // ignore: public_member_api_docs
  final seeks = <Duration>[];
  // ignore: public_member_api_docs
  bool disposed = false;

  final _positionChanges = StreamController<Duration>.broadcast();
  final _durationChanges = StreamController<Duration>.broadcast();
  final _playingChanges = StreamController<bool>.broadcast();

  @override
  Stream<Duration> get positionChanges => _positionChanges.stream;

  @override
  Stream<Duration> get durationChanges => _durationChanges.stream;

  @override
  Stream<bool> get playingChanges => _playingChanges.stream;

  @override
  Future<void> play() async {
    playCalls++;
    playing = true;
    _playingChanges.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
    _playingChanges.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    this.position = position;
    _positionChanges.add(position);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(_positionChanges.close());
    unawaited(_durationChanges.close());
    unawaited(_playingChanges.close());
  }
}

/// Deterministic [SandboxVideoController] for widget/golden tests: ready
/// and paused at 0:00 with a fixed duration; [buildSurface] paints a static
/// teal→indigo gradient box (no real video texture).
class FakeVideoController implements SandboxVideoController {
  /// Creates a fake with a fixed [duration].
  FakeVideoController({this.duration = const Duration(seconds: 7)});

  @override
  bool ready = true;

  @override
  bool playing = false;

  @override
  bool muted = false;

  @override
  Duration position = Duration.zero;

  @override
  final Duration duration;

  /// Recorded calls, for assertions.
  int playCalls = 0;
  // ignore: public_member_api_docs
  int pauseCalls = 0;
  // ignore: public_member_api_docs
  bool disposed = false;

  final _readyChanges = StreamController<bool>.broadcast();
  final _playingChanges = StreamController<bool>.broadcast();
  final _positionChanges = StreamController<Duration>.broadcast();

  @override
  Stream<bool> get readyChanges => _readyChanges.stream;

  @override
  Stream<bool> get playingChanges => _playingChanges.stream;

  @override
  Stream<Duration> get positionChanges => _positionChanges.stream;

  @override
  Future<void> play() async {
    playCalls++;
    playing = true;
    _playingChanges.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
    _playingChanges.add(false);
  }

  @override
  Future<void> setMuted(bool muted) async {
    this.muted = muted;
  }

  @override
  Widget buildSurface(BuildContext context) {
    // Ultra-wide so a full tool tile fits into a chat golden frame without
    // scrolling the tile header off the top.
    return AspectRatio(
      aspectRatio: 21 / 9,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [FahPalette.teal, FahPalette.indigo],
          ),
        ),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(_readyChanges.close());
    unawaited(_playingChanges.close());
    unawaited(_positionChanges.close());
  }
}
