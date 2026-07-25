// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:fa/services/asr_service.dart';

/// Whether the current platform has a native microphone backend: the
/// `fah/mic` channel is wired up on macOS and iOS only (see
/// `MainFlutterWindow.swift` / `AppDelegate.swift`).
bool get asrPlatformSupported => Platform.isMacOS || Platform.isIOS;

/// Creates the method-channel-backed [AsrApi] (IO platforms).
AsrApi createAsrService() => const MethodChannelAsrApi();

/// [AsrApi] over the `fah/mic` method channel.
final class MethodChannelAsrApi implements AsrApi {
  const MethodChannelAsrApi();

  static const _channel = MethodChannel('fah/mic');

  @override
  Future<bool> get isAvailable async => asrPlatformSupported;

  @override
  Future<bool> requestAccess() async {
    if (!asrPlatformSupported) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('requestAccess');
      return granted ?? false;
    } on MissingPluginException {
      // No native handler (e.g. unit tests) — treat as denied.
      return false;
    }
  }

  @override
  Future<void> startRecording() async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('startRecording');
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<AsrRecording> stopRecording() async {
    _ensureSupported();
    final Map<dynamic, dynamic>? raw;
    try {
      raw = await _channel.invokeMapMethod<dynamic, dynamic>('stopRecording');
    } on MissingPluginException {
      throw _unsupported();
    }
    if (raw == null) throw StateError('No recording was in progress.');
    return (
      path: raw['path']?.toString() ?? '',
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
      sampleRate: (raw['sampleRate'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<Uint8List> readRecording(String path) => File(path).readAsBytes();

  static void _ensureSupported() {
    if (!asrPlatformSupported) throw _unsupported();
  }

  static StateError _unsupported() =>
      StateError('Microphone recording is not supported on this platform.');
}
