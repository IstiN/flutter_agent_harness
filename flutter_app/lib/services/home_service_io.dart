// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:fa/services/home_service.dart';

/// Whether the current platform has a native home backend: HomeKit is wired
/// up on iOS only (see `AppDelegate.swift` — the macOS handler in
/// `MainFlutterWindow.swift` reports unsupported, and there is no HomeKit
/// framework on the remaining platforms).
bool get homePlatformSupported => Platform.isIOS;

/// Creates the method-channel-backed [HomeApi] (IO platforms).
HomeApi createHomeService() => const MethodChannelHomeApi();

/// [HomeApi] over the `fah/home` method channel.
final class MethodChannelHomeApi implements HomeApi {
  const MethodChannelHomeApi();

  static const _channel = MethodChannel('fah/home');

  @override
  Future<bool> get isAvailable async => homePlatformSupported;

  @override
  Future<bool> requestAccess() async {
    if (!homePlatformSupported) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('requestAccess');
      return granted ?? false;
    } on MissingPluginException {
      // No native handler (e.g. unit tests) — treat as denied.
      return false;
    }
  }

  @override
  Future<List<HomeAccessory>> listAccessories() async {
    if (!homePlatformSupported) throw _unsupported();
    final List<dynamic>? raw;
    try {
      raw = await _channel.invokeListMethod<dynamic>('listAccessories');
    } on MissingPluginException {
      throw _unsupported();
    }
    return [
      for (final entry in raw ?? const [])
        if (entry is Map) _parseAccessory(entry),
    ];
  }

  static HomeAccessory _parseAccessory(Map<dynamic, dynamic> map) {
    return (
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '(unnamed)',
      room: map['room']?.toString() ?? '',
      homeName: map['homeName']?.toString() ?? '',
      category: map['category']?.toString() ?? '',
      reachable: map['reachable'] == true,
      isOn: map['isOn'] as bool?,
      brightness: (map['brightness'] as num?)?.round(),
      targetTemperature: (map['targetTemperature'] as num?)?.toDouble(),
    );
  }

  @override
  Future<void> setPower({required String id, required bool on}) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('setPower', {'id': id, 'on': on});
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<void> setBrightness({required String id, required int value}) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('setBrightness', {
        'id': id,
        'value': value,
      });
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<void> setTargetTemperature({
    required String id,
    required double celsius,
  }) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('setTargetTemperature', {
        'id': id,
        'celsius': celsius,
      });
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  static void _ensureSupported() {
    if (!homePlatformSupported) throw _unsupported();
  }

  static StateError _unsupported() =>
      StateError('Home control is not supported on this platform.');
}
