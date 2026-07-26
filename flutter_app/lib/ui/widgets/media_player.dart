// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/ui/app_theme.dart';

/// Audio file extensions rendered as an inline player in the chat.
const audioFileExtensions = ['mp3', 'wav', 'm4a'];

/// Video file extensions rendered as an inline player in the chat.
const videoFileExtensions = ['mp4', 'mov', 'webm'];

/// The media kind of a sandbox path, for link/extension classification.
enum SandboxMediaKind { audio, video }

/// Classifies a sandbox-relative media [path] by its extension
/// ([audioFileExtensions] / [videoFileExtensions], case-insensitive).
/// URLs (`http(s):`, `data:`) and other extensions return null.
SandboxMediaKind? sandboxMediaKind(String path) {
  if (path.contains('://') || path.startsWith('data:')) return null;
  final clean = path.startsWith('/') ? path.substring(1) : path;
  final dot = clean.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = clean.substring(dot + 1).toLowerCase();
  if (audioFileExtensions.contains(ext)) return SandboxMediaKind.audio;
  if (videoFileExtensions.contains(ext)) return SandboxMediaKind.video;
  return null;
}

/// The first path-like token in [text] ending in one of [extensions]
/// (case-insensitive) — mirrors the `generate_image` result-text path
/// sniffing in the chat screen.
String? mediaPathInText(String text, List<String> extensions) {
  final pattern = RegExp(
    '([\\w./-]+\\.(?:${extensions.join('|')}))\\b',
    caseSensitive: false,
  );
  return pattern.firstMatch(text)?.group(1);
}

/// `m:ss` rendering for player position/duration readouts.
String formatMediaDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Playback engine behind [SandboxAudioPlayer]. Tests and golden snapshots
/// inject deterministic fakes; the real implementation wraps
/// `package:audioplayers` ([AudioplayersAudioController]).
abstract interface class SandboxAudioController {
  /// Current playback position.
  Duration get position;

  /// Total media duration (zero while unknown).
  Duration get duration;

  /// Whether playback is currently running.
  bool get playing;

  /// Emits the new position as it changes.
  Stream<Duration> get positionChanges;

  /// Emits the new duration once it is known.
  Stream<Duration> get durationChanges;

  /// Emits the new playing state on play/pause/complete.
  Stream<bool> get playingChanges;

  /// Starts (or resumes) playback.
  Future<void> play();

  /// Pauses playback.
  Future<void> pause();

  /// Seeks to [position].
  Future<void> seek(Duration position);

  /// Releases all resources.
  Future<void> dispose();
}

/// Builds a [SandboxAudioController] for decoded media [bytes].
typedef SandboxAudioControllerFactory =
    FutureOr<SandboxAudioController> Function(Uint8List bytes);

/// Playback engine behind [SandboxVideoPlayer] — see
/// [SandboxAudioController] for the testing rationale.
abstract interface class SandboxVideoController {
  /// Whether the video surface is ready to paint.
  bool get ready;

  /// Whether playback is currently running.
  bool get playing;

  /// Whether the audio track is muted.
  bool get muted;

  /// Current playback position.
  Duration get position;

  /// Total media duration (zero while unknown).
  Duration get duration;

  /// Emits true once the surface is ready.
  Stream<bool> get readyChanges;

  /// Emits the new playing state on play/pause.
  Stream<bool> get playingChanges;

  /// Emits the new position as it changes.
  Stream<Duration> get positionChanges;

  /// Starts (or resumes) playback.
  Future<void> play();

  /// Pauses playback.
  Future<void> pause();

  /// Mutes/unmutes the audio track.
  Future<void> setMuted(bool muted);

  /// The video surface, only called when [ready].
  Widget buildSurface(BuildContext context);

  /// Releases all resources (including any temp file).
  Future<void> dispose();
}

/// Builds a [SandboxVideoController] for the sandbox file at [path] with
/// decoded [bytes].
typedef SandboxVideoControllerFactory =
    FutureOr<SandboxVideoController> Function(String path, Uint8List bytes);

/// [SandboxAudioController] over `package:audioplayers`: plays the media
/// bytes straight from memory ([BytesSource]) — works on every target,
/// including the web build.
final class AudioplayersAudioController implements SandboxAudioController {
  /// Creates a controller and starts buffering [bytes] (without playing).
  AudioplayersAudioController(Uint8List bytes) {
    _subscriptions = [
      _player.onPositionChanged.listen((position) {
        _position = position;
        _positionChanges.add(position);
      }),
      _player.onDurationChanged.listen((duration) {
        _duration = duration;
        _durationChanges.add(duration);
      }),
      _player.onPlayerStateChanged.listen((state) {
        final playing = state == PlayerState.playing;
        if (playing == _playing) return;
        _playing = playing;
        _playingChanges.add(playing);
      }),
      _player.onPlayerComplete.listen((_) {
        _position = Duration.zero;
        _positionChanges.add(Duration.zero);
      }),
    ];
    unawaited(_player.setSource(BytesSource(bytes)));
  }

  final AudioPlayer _player = AudioPlayer();
  late final List<StreamSubscription<dynamic>> _subscriptions;

  final StreamController<Duration> _positionChanges =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationChanges =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playingChanges =
      StreamController<bool>.broadcast();

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  bool get playing => _playing;

  @override
  Stream<Duration> get positionChanges => _positionChanges.stream;

  @override
  Stream<Duration> get durationChanges => _durationChanges.stream;

  @override
  Stream<bool> get playingChanges => _playingChanges.stream;

  @override
  Future<void> play() => _player.resume();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    unawaited(_positionChanges.close());
    unawaited(_durationChanges.close());
    unawaited(_playingChanges.close());
  }
}

/// Default [SandboxVideoControllerFactory]: `package:video_player` needs a
/// file (or network URL), so the sandbox bytes are staged into a temp file
/// (rewritten only when the size changes, like `chatImageMessageSource`).
/// The web build is guarded at the widget level — this never runs there.
Future<SandboxVideoController> defaultVideoControllerFactory(
  String path,
  Uint8List bytes,
) async {
  final tmp = await getTemporaryDirectory();
  final name = path.split('/').last;
  final file = File('${tmp.path}/fah_media_$name');
  if (!file.existsSync() || file.lengthSync() != bytes.length) {
    await file.writeAsBytes(bytes);
  }
  return VideoPlayerSandboxController(file);
}

/// [SandboxVideoController] over `package:video_player` (file source).
final class VideoPlayerSandboxController implements SandboxVideoController {
  /// Creates a controller playing [file]; initialization runs in the
  /// background and flips [ready] via [readyChanges].
  VideoPlayerSandboxController(File file) {
    unawaited(_initialize(file));
  }

  VideoPlayerController? _controller;

  final StreamController<bool> _readyChanges =
      StreamController<bool>.broadcast();
  final StreamController<bool> _playingChanges =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _positionChanges =
      StreamController<Duration>.broadcast();

  bool _ready = false;
  bool _playing = false;
  bool _muted = false;
  bool _disposed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  Future<void> _initialize(File file) async {
    final controller = VideoPlayerController.file(file);
    _controller = controller;
    try {
      await controller.initialize();
    } on Object {
      // A corrupt/unsupported file leaves the player "not ready" — the
      // widget keeps showing the loading state rather than crashing.
      return;
    }
    if (_disposed) {
      await controller.dispose();
      return;
    }
    _duration = controller.value.duration;
    controller.addListener(_onValue);
    _ready = true;
    _readyChanges.add(true);
  }

  void _onValue() {
    final value = _controller!.value;
    if (value.position != _position) {
      _position = value.position;
      _positionChanges.add(_position);
    }
    if (value.isPlaying != _playing) {
      _playing = value.isPlaying;
      _playingChanges.add(_playing);
    }
  }

  @override
  bool get ready => _ready;

  @override
  bool get playing => _playing;

  @override
  bool get muted => _muted;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  Stream<bool> get readyChanges => _readyChanges.stream;

  @override
  Stream<bool> get playingChanges => _playingChanges.stream;

  @override
  Stream<Duration> get positionChanges => _positionChanges.stream;

  @override
  Future<void> play() async {
    if (_ready) await _controller!.play();
  }

  @override
  Future<void> pause() async {
    if (_ready) await _controller!.pause();
  }

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    if (_ready) await _controller!.setVolume(muted ? 0 : 1);
  }

  @override
  Widget buildSurface(BuildContext context) {
    final controller = _controller!;
    return AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: VideoPlayer(controller),
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    if (_ready) {
      _controller!.removeListener(_onValue);
      await _controller!.dispose();
    }
    unawaited(_readyChanges.close());
    unawaited(_playingChanges.close());
    unawaited(_positionChanges.close());
  }
}

/// Compact inline audio player for sandbox-generated media (`speak`,
/// `generate_music`, `.mp3`/`.wav`/`.m4a` links): play/pause button, seek
/// slider, and a `m:ss / m:ss` readout in the same panel/border visual
/// language as the inline image tiles.
///
/// [bytes] is the (memoized) sandbox read — see `SandboxImageResolver.load`;
/// null bytes degrade to a dim "file not found" line, never a crash. The
/// playback engine comes from [controllerFactory] (real default:
/// [AudioplayersAudioController]); tests inject fakes.
class SandboxAudioPlayer extends StatefulWidget {
  /// Creates a player for [bytes].
  const SandboxAudioPlayer({
    super.key,
    required this.bytes,
    this.controllerFactory,
  });

  /// The media bytes, or null when the sandbox file is missing.
  final Future<Uint8List?> bytes;

  /// Playback engine factory; null uses [AudioplayersAudioController].
  final SandboxAudioControllerFactory? controllerFactory;

  @override
  State<SandboxAudioPlayer> createState() => _SandboxAudioPlayerState();
}

class _SandboxAudioPlayerState extends State<SandboxAudioPlayer> {
  SandboxAudioController? _controller;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant SandboxAudioPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes != widget.bytes) {
      unawaited(_controller?.dispose());
      _controller = null;
      _missing = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final bytes = await widget.bytes.catchError((_) => null);
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _missing = true);
      return;
    }
    final factory = widget.controllerFactory ?? AudioplayersAudioController.new;
    final controller = await factory(bytes);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = FahColors.of(context);
    if (_missing) return _missingLine(context, palette);
    final controller = _controller;
    if (controller == null) {
      return _loadingPanel(context, palette);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        decoration: BoxDecoration(
          color: palette.panelAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            StreamBuilder<bool>(
              initialData: controller.playing,
              stream: controller.playingChanges,
              builder: (context, snapshot) {
                final playing = snapshot.data ?? false;
                return IconButton(
                  icon: Icon(
                    playing ? Icons.pause : Icons.play_arrow,
                    size: 20,
                  ),
                  tooltip: playing
                      ? context.l10n.mediaPauseTooltip
                      : context.l10n.mediaPlayTooltip,
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      playing ? controller.pause() : controller.play(),
                );
              },
            ),
            Expanded(
              child: StreamBuilder<Duration>(
                initialData: controller.duration,
                stream: controller.durationChanges,
                builder: (context, durationSnapshot) {
                  final duration = durationSnapshot.data ?? Duration.zero;
                  final maxMillis = duration.inMilliseconds;
                  return StreamBuilder<Duration>(
                    initialData: controller.position,
                    stream: controller.positionChanges,
                    builder: (context, positionSnapshot) {
                      final position = positionSnapshot.data ?? Duration.zero;
                      return Slider(
                        value: maxMillis > 0
                            ? position.inMilliseconds
                                  .clamp(0, maxMillis)
                                  .toDouble()
                            : 0,
                        max: maxMillis > 0 ? maxMillis.toDouble() : 1,
                        onChanged: maxMillis > 0
                            ? (value) => controller.seek(
                                Duration(milliseconds: value.round()),
                              )
                            : null,
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: StreamBuilder<Duration>(
                initialData: controller.position,
                stream: controller.positionChanges,
                builder: (context, snapshot) {
                  final position = snapshot.data ?? Duration.zero;
                  return Text(
                    '${formatMediaDuration(position)} / '
                    '${formatMediaDuration(controller.duration)}',
                    style: palette.mono(color: palette.dim, fontSize: 11),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline video player for sandbox media (`.mp4`/`.mov`/`.webm`): a bounded
/// (~320px) rounded surface — tap toggles play/pause — over a thin progress
/// bar and a mute button.
///
/// `package:video_player` cannot play in-memory bytes, so the default
/// controller stages them into a temp file ([defaultVideoControllerFactory])
/// and the WEB BUILD (no filesystem, no file sources) shows an honest
/// "not supported" note instead — unless a [controllerFactory] is injected
/// (tests, goldens).
class SandboxVideoPlayer extends StatefulWidget {
  /// Creates a player for the sandbox file at [path] with [bytes].
  const SandboxVideoPlayer({
    super.key,
    required this.path,
    required this.bytes,
    this.controllerFactory,
  });

  /// Sandbox path the bytes came from (names the temp staging file).
  final String path;

  /// The media bytes, or null when the sandbox file is missing.
  final Future<Uint8List?> bytes;

  /// Playback engine factory; null uses [defaultVideoControllerFactory].
  final SandboxVideoControllerFactory? controllerFactory;

  @override
  State<SandboxVideoPlayer> createState() => _SandboxVideoPlayerState();
}

class _SandboxVideoPlayerState extends State<SandboxVideoPlayer> {
  SandboxVideoController? _controller;
  bool _missing = false;

  /// The web has no file sources — with no injected factory there is
  /// nothing honest to play.
  bool get _unsupported => kIsWeb && widget.controllerFactory == null;

  @override
  void initState() {
    super.initState();
    if (!_unsupported) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant SandboxVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes != widget.bytes && !_unsupported) {
      unawaited(_controller?.dispose());
      _controller = null;
      _missing = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final bytes = await widget.bytes.catchError((_) => null);
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _missing = true);
      return;
    }
    final factory = widget.controllerFactory ?? defaultVideoControllerFactory;
    final controller = await factory(widget.path, bytes);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = FahColors.of(context);
    if (_unsupported) {
      return _noteLine(context, palette, context.l10n.mediaVideoUnsupportedWeb);
    }
    if (_missing) return _missingLine(context, palette);
    final controller = _controller;
    if (controller == null) {
      return _loadingPanel(context, palette, height: 120);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 320),
              color: palette.bgAlt,
              child: StreamBuilder<bool>(
                initialData: controller.ready,
                stream: controller.readyChanges,
                builder: (context, readySnapshot) {
                  final ready = readySnapshot.data ?? false;
                  return StreamBuilder<bool>(
                    initialData: controller.playing,
                    stream: controller.playingChanges,
                    builder: (context, playingSnapshot) {
                      final playing = playingSnapshot.data ?? false;
                      return GestureDetector(
                        onTap: ready
                            ? () => playing
                                  ? controller.pause()
                                  : controller.play()
                            : null,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (ready)
                              controller.buildSurface(context)
                            else
                              SizedBox(
                                height: 180,
                                child: Center(
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: palette.dim,
                                    ),
                                  ),
                                ),
                              ),
                            if (ready && !playing)
                              Icon(
                                Icons.play_circle_outline,
                                size: 48,
                                color: palette.onAccent.withValues(alpha: 0.85),
                              ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: StreamBuilder<Duration>(
                  initialData: controller.position,
                  stream: controller.positionChanges,
                  builder: (context, snapshot) {
                    final position = snapshot.data ?? Duration.zero;
                    final duration = controller.duration;
                    return LinearProgressIndicator(
                      value: duration > Duration.zero
                          ? (position.inMilliseconds / duration.inMilliseconds)
                                .clamp(0.0, 1.0)
                          : 0,
                      minHeight: 3,
                      backgroundColor: palette.border,
                      valueColor: AlwaysStoppedAnimation(palette.teal),
                    );
                  },
                ),
              ),
              _MuteButton(controller: controller),
            ],
          ),
        ],
      ),
    );
  }
}

class _MuteButton extends StatefulWidget {
  const _MuteButton({required this.controller});

  final SandboxVideoController controller;

  @override
  State<_MuteButton> createState() => _MuteButtonState();
}

class _MuteButtonState extends State<_MuteButton> {
  late bool _muted = widget.controller.muted;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(_muted ? Icons.volume_off : Icons.volume_up, size: 18),
      tooltip: _muted
          ? context.l10n.mediaUnmuteTooltip
          : context.l10n.mediaMuteTooltip,
      visualDensity: VisualDensity.compact,
      onPressed: () {
        final muted = !_muted;
        setState(() => _muted = muted);
        unawaited(widget.controller.setMuted(muted));
      },
    );
  }
}

Widget _missingLine(BuildContext context, FahColors palette) {
  return _noteLine(context, palette, context.l10n.mediaFileMissing);
}

Widget _noteLine(BuildContext context, FahColors palette, String note) {
  return Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.music_off_outlined, size: 14, color: palette.dim),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            note,
            overflow: TextOverflow.ellipsis,
            style: palette.mono(color: palette.dim, fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

Widget _loadingPanel(
  BuildContext context,
  FahColors palette, {
  double height = 40,
}) {
  return Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Container(
      height: height,
      decoration: BoxDecoration(
        color: palette.panelAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Center(
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: palette.dim),
        ),
      ),
    ),
  );
}

/// Opens a small dialog with an inline player for the sandbox media [bytes]
/// — the `onTapLink` target for audio/video sandbox links in the chat
/// Markdown (flutter_markdown has no custom link RENDERER, only a tap
/// callback, so links open the player in a dialog instead of rendering
/// inline like images).
void showFahMediaDialog(
  BuildContext context, {
  required Future<Uint8List?> bytes,
  required SandboxMediaKind kind,
  SandboxAudioControllerFactory? audioControllerFactory,
  SandboxVideoControllerFactory? videoControllerFactory,
}) {
  showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: kind == SandboxMediaKind.video ? 480 : 360,
          ),
          child: switch (kind) {
            SandboxMediaKind.audio => SandboxAudioPlayer(
              bytes: bytes,
              controllerFactory: audioControllerFactory,
            ),
            SandboxMediaKind.video => SandboxVideoPlayer(
              path: 'media',
              bytes: bytes,
              controllerFactory: videoControllerFactory,
            ),
          },
        ),
      ),
    ),
  );
}
