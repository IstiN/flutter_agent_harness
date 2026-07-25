// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:fa/services/notify_service.dart';

/// Whether the current platform has a native local-notifications backend:
/// UNUserNotificationCenter is wired up on macOS and iOS only (see
/// `MainFlutterWindow.swift` / `AppDelegate.swift`). Works inside the macOS
/// app sandbox — notifications need no entitlement.
bool get notifyPlatformSupported => Platform.isMacOS || Platform.isIOS;

/// Creates the method-channel-backed [NotifyApi] (IO platforms).
NotifyApi createNotifyService() => const MethodChannelNotifyApi();

/// [NotifyApi] over the `fah/notify` method channel.
final class MethodChannelNotifyApi implements NotifyApi {
  const MethodChannelNotifyApi();

  static const _channel = MethodChannel('fah/notify');

  @override
  Future<bool> get isAvailable async => notifyPlatformSupported;

  @override
  Future<bool> requestAccess() async {
    if (!notifyPlatformSupported) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('requestAccess');
      return granted ?? false;
    } on MissingPluginException {
      // No native handler (e.g. unit tests) — treat as denied.
      return false;
    }
  }

  @override
  Future<String> schedule({
    required String title,
    String? body,
    String? id,
    double? delaySeconds,
  }) async {
    _ensureSupported();
    // Generate the id here so the caller always knows it, even when the
    // native side is replaced by a fake in tests.
    final notificationId = id ?? newNotificationId();
    try {
      final scheduled = await _channel.invokeMethod<String>('schedule', {
        'title': title,
        'body': ?body,
        'id': notificationId,
        'delaySeconds': ?delaySeconds,
      });
      return scheduled ?? notificationId;
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<void> cancel({required String id}) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('cancel', {'id': id});
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<void> cancelAll() async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('cancelAll');
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  static void _ensureSupported() {
    if (!notifyPlatformSupported) throw _unsupported();
  }

  static StateError _unsupported() =>
      StateError('Local notifications are not supported on this platform.');
}
