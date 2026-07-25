// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/notify_service.dart';

/// Whether the current platform has a native local-notifications backend
/// (macOS/iOS). Always false here — this stub is selected where `dart:io`
/// is unavailable (web), so callers degrade to a clean "not supported" note.
bool get notifyPlatformSupported => false;

/// Creates the platform [NotifyApi]. On web there is no notification
/// backend, so the service reports itself unavailable and every call is a
/// no-op.
NotifyApi createNotifyService() => const _UnavailableNotifyApi();

final class _UnavailableNotifyApi implements NotifyApi {
  const _UnavailableNotifyApi();

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<String> schedule({
    required String title,
    String? body,
    String? id,
    double? delaySeconds,
  }) => throw StateError(
    'Local notifications are not supported on this platform.',
  );

  @override
  Future<void> cancel({required String id}) => throw StateError(
    'Local notifications are not supported on this platform.',
  );

  @override
  Future<void> cancelAll() => throw StateError(
    'Local notifications are not supported on this platform.',
  );
}
