// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/video_service.dart';

/// Whether the current platform has a native video-frame backend (the
/// `fah/video` channel on macOS/iOS). Always false here — this stub is
/// selected where `dart:io` is unavailable (web), so callers degrade to a
/// clean "not supported" note.
bool get videoPlatformSupported => false;

/// Creates the platform [VideoApi]. On web there is no video-frame backend,
/// so the service reports itself unavailable and every call is a no-op.
VideoApi createVideoService() => const _UnavailableVideoApi();

final class _UnavailableVideoApi implements VideoApi {
  const _UnavailableVideoApi();

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<List<VideoFrame>> extractFrames({
    required String path,
    required int count,
  }) => throw StateError(
    'Video frame extraction is not supported on this platform.',
  );
}
