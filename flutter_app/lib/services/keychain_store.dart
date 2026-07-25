// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-scoped Keychain storage for API keys on iOS and macOS, backed by the
/// `fah/keychain` method channel (service `fa.app`; entries never leave the
/// device — `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
///
/// Every call degrades gracefully: unsupported platforms (web, Android,
/// Linux, Windows) report [isSupported] == false, and channel errors read
/// as empty / write as false so callers can fall back to file persistence.
final class KeychainStore {
  const KeychainStore();

  static const _channel = MethodChannel('fah/keychain');

  /// Whether the secure backend exists on this platform (iOS/macOS only).
  /// Platform-checks go through [defaultTargetPlatform] so this file still
  /// compiles for web (no `dart:io`).
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Probes the channel; false on any error (a broken channel must never
  /// block boot).
  Future<bool> isAvailable() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on Object {
      return false;
    }
  }

  /// Every stored entry (name → value). Values must never reach the UI.
  Future<Map<String, String>> readAll() async {
    if (!isSupported) return const {};
    try {
      final result = await _channel.invokeMethod<Map>('readAll');
      return {
        for (final entry in (result ?? const {}).entries)
          if (entry.value is String) entry.key as String: entry.value as String,
      };
    } on Object {
      return const {};
    }
  }

  /// Stores [value] under [name]; false when unavailable or failed.
  Future<bool> set(String name, String value) async {
    if (!isSupported || name.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('set', {
            'name': name,
            'value': value,
          }) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Removes [name] (true also when it was absent).
  Future<bool> delete(String name) async {
    if (!isSupported || name.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('delete', {'name': name}) ??
          false;
    } on Object {
      return false;
    }
  }
}
