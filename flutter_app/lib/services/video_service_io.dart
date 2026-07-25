// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:fa/services/video_service.dart';

/// Whether the current platform has a native video-frame backend: the
/// `fah/video` channel is wired up on macOS and iOS only (see
/// `MainFlutterWindow.swift` / `AppDelegate.swift`).
bool get videoPlatformSupported => Platform.isMacOS || Platform.isIOS;

/// Creates the method-channel-backed [VideoApi] (IO platforms).
VideoApi createVideoService() => const MethodChannelVideoApi();

/// [VideoApi] over the `fah/video` method channel.
final class MethodChannelVideoApi implements VideoApi {
  const MethodChannelVideoApi();

  static const _channel = MethodChannel('fah/video');

  @override
  Future<bool> get isAvailable async => videoPlatformSupported;

  @override
  Future<List<VideoFrame>> extractFrames({
    required String path,
    required int count,
  }) async {
    if (!videoPlatformSupported) throw _unsupported();
    final List<dynamic>? raw;
    try {
      raw = await _channel.invokeListMethod<dynamic>('extractFrames', {
        'path': path,
        'count': count,
      });
    } on MissingPluginException {
      throw _unsupported();
    }
    if (raw == null) return const [];
    return [
      for (final entry in raw)
        if (entry is Map)
          (
            bytes: base64Decode(entry['bytes']?.toString() ?? ''),
            positionMs: (entry['positionMs'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  static StateError _unsupported() =>
      StateError('Video frame extraction is not supported on this platform.');
}
