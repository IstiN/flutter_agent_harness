// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

export 'package:fa/services/video_service_stub.dart'
    if (dart.library.io) 'package:fa/services/video_service_io.dart';

/// One frame extracted from a video: the jpeg [bytes] and the frame's
/// [positionMs] on the video timeline (used for the timeline labels the
/// vision model sees).
typedef VideoFrame = ({Uint8List bytes, int positionMs});

/// Video frame extraction (AVAssetImageGenerator on macOS/iOS via the
/// `fah/video` method channel) for the agent's `read_video` tool and the
/// `jsr.fa.media.readVideo` JS bridge.
///
/// Use [createVideoService] (conditionally imported above) to obtain the
/// platform implementation: the `fah/video` method channel on IO platforms,
/// a never-available stub on web. Tests inject fakes.
abstract interface class VideoApi {
  /// Whether this platform can extract frames from video files at all.
  Future<bool> get isAvailable;

  /// Extracts [count] evenly spaced frames from the video at the host
  /// [path], each jpeg-encoded with its timeline position. An unreadable or
  /// empty video yields an empty list (never a crash).
  Future<List<VideoFrame>> extractFrames({
    required String path,
    required int count,
  });
}

/// Default number of frames `read_video` extracts when `frames` is absent.
const defaultVideoFrames = 6;

/// Most frames one `read_video` call may extract (payload size guard — each
/// frame rides the vision request as a base64 data URI).
const maxVideoFrames = 12;

/// Validates a `frames` argument (1–[maxVideoFrames], default
/// [defaultFrames]) shared by the agent tool and the JS bridge.
int videoFramesCount(num? value, {int defaultFrames = defaultVideoFrames}) {
  final frames = (value ?? defaultFrames).round();
  if (frames < 1) return 1;
  if (frames > maxVideoFrames) return maxVideoFrames;
  return frames;
}
