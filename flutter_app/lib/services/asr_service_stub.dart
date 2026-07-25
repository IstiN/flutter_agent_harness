// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:typed_data';

import 'package:fa/services/asr_service.dart';

/// Whether the current platform has a native microphone backend (the
/// `fah/mic` channel on macOS/iOS). Always false here — this stub is
/// selected where `dart:io` is unavailable (web), so callers degrade to a
/// clean "not supported" note.
bool get asrPlatformSupported => false;

/// Creates the platform [AsrApi]. On web there is no microphone backend, so
/// the service reports itself unavailable and every call is a no-op.
AsrApi createAsrService() => const _UnavailableAsrApi();

final class _UnavailableAsrApi implements AsrApi {
  const _UnavailableAsrApi();

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<void> startRecording() => throw StateError(
    'Microphone recording is not supported on this platform.',
  );

  @override
  Future<AsrRecording> stopRecording() => throw StateError(
    'Microphone recording is not supported on this platform.',
  );

  @override
  Future<Uint8List> readRecording(String path) => throw StateError(
    'Microphone recording is not supported on this platform.',
  );
}
