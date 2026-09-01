import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:fa/services/app_log.dart';
import 'package:flutter/widgets.dart';
import 'package:js_widget_runtime/js_widget_runtime.dart';
import 'package:video_player/video_player.dart';

/// Fa's [JsMediaHost] — backs the renderer's `video`/`audio` nodes with
/// `video_player` surfaces and `audioplayers` transport (both already
/// ship with the app for chat media). Faithful port of the runtime's
/// `example/lib/media_host.dart` (keep them in sync); adapted in naming.
///
/// Supported `src` schemes:
/// - `https://…` / `http://…` — network stream (CORS applies on web)
/// - `assets/…` — bundled asset
class FaMediaHost extends JsMediaHost {
  const FaMediaHost();

  @override
  JsVideoController createVideoController(String src) {
    AppLog.i('media', 'video controller: $src');
    return VideoPlayerJsController(src);
  }

  @override
  JsAudioController createAudioController(String src) {
    AppLog.i('media', 'audio controller: $src');
    return AudioPlayersJsController(src);
  }
}

/// Forwards `VideoPlayerController` value-listenable state into the
/// stream-based [JsMediaController] interface.
class VideoPlayerJsController extends JsVideoController {
  VideoPlayerJsController(String src) {
    _controller = src.startsWith('http')
        ? VideoPlayerController.networkUrl(Uri.parse(src))
        : VideoPlayerController.asset(src);
    _controller.addListener(_onUpdate);
    _initFuture = _controller.initialize().then(
      (_) {
        _aspect = _controller.value.aspectRatio;
        _aspectCtrl.add(_aspect);
        _durationCtrl.add(_controller.value.duration);
        _onUpdate();
        AppLog.i(
          'media',
          'video initialized: $src '
              '(${_controller.value.duration.inSeconds}s, '
              '${_controller.value.size.width.toInt()}x'
              '${_controller.value.size.height.toInt()})',
        );
      },
      onError: (Object error) {
        // Swallowed init errors were the "black 00:00 player" reports —
        // surface them in the app log instead.
        AppLog.i('media', 'video init FAILED: $src — $error');
        throw error;
      },
    );
  }

  late final VideoPlayerController _controller;
  late final Future<void> _initFuture;

  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _aspectCtrl = StreamController<double?>.broadcast();
  double? _aspect;

  void _onUpdate() {
    final v = _controller.value;
    if (!v.isInitialized) return;
    _positionCtrl.add(v.position);
    _durationCtrl.add(v.duration);
    _playingCtrl.add(v.isPlaying);
  }

  @override
  double? get aspectRatio => _aspect;

  @override
  Stream<double?> get aspectRatioStream => _aspectCtrl.stream;

  @override
  Stream<Duration> get positionStream => _positionCtrl.stream;

  @override
  Stream<Duration> get durationStream => _durationCtrl.stream;

  @override
  Stream<bool> get playingStream => _playingCtrl.stream;

  @override
  Future<void> play() async {
    try {
      await _initFuture;
      await _controller.play();
      AppLog.i('media', 'video play: ${_controller.dataSource}');
    } on Object catch (error) {
      AppLog.i(
        'media',
        'video play FAILED: ${_controller.dataSource} — $error',
      );
      rethrow;
    }
  }

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seek(Duration position) async {
    await _initFuture;
    await _controller.seekTo(position);
  }

  @override
  Future<void> setVolume(double volume) =>
      _controller.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<void> setLoop(bool loop) => _controller.setLooping(loop);

  @override
  Widget buildVideo(
    BuildContext context, {
    BoxFit fit = BoxFit.contain,
    double? width,
    double? height,
  }) => FutureBuilder<void>(
    future: _initFuture,
    builder: (context, snap) {
      if (snap.connectionState != ConnectionState.done) {
        return const SizedBox.expand();
      }
      return SizedBox(
        width: width,
        height: height,
        child: FittedBox(
          fit: fit,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: _controller.value.size.width,
            height: _controller.value.size.height,
            child: VideoPlayer(_controller),
          ),
        ),
      );
    },
  );

  @override
  Future<void> dispose() async {
    _controller.removeListener(_onUpdate);
    await _controller.dispose();
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _playingCtrl.close();
    await _aspectCtrl.close();
  }
}

/// Adapts an `audioplayers` [AudioPlayer] to [JsAudioController]; the
/// plugin already exposes the needed streams.
class AudioPlayersJsController extends JsAudioController {
  AudioPlayersJsController(String src) {
    _player = AudioPlayer();
    _source = src.startsWith('http') ? UrlSource(src) : AssetSource(src);
  }

  late final AudioPlayer _player;
  late final Source _source;
  bool _started = false;

  Future<void> _ensureStarted() async {
    if (_started) return;
    _started = true;
    try {
      await _player.play(_source);
      AppLog.i('media', 'audio play: $_source');
    } on Object catch (error) {
      AppLog.i('media', 'audio play FAILED: $_source — $error');
      rethrow;
    }
  }

  @override
  Stream<Duration> get positionStream => _player.onPositionChanged;

  @override
  Stream<Duration> get durationStream => _player.onDurationChanged;

  @override
  Stream<bool> get playingStream =>
      _player.onPlayerStateChanged.map((s) => s == PlayerState.playing);

  @override
  Future<void> play() async {
    if (!_started) return _ensureStarted();
    await _player.resume();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<void> setLoop(bool loop) =>
      _player.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.release);

  @override
  Future<void> dispose() => _player.dispose();
}
