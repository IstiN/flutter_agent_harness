// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:fa/services/app_log.dart';
import 'package:fa/services/home_service.dart';

/// Whether the current platform has a native home backend: HomeKit is wired
/// up on iOS only (see `AppDelegate.swift` — the macOS handler in
/// `MainFlutterWindow.swift` reports unsupported, and there is no HomeKit
/// framework on the remaining platforms).
bool get homePlatformSupported => Platform.isIOS;

/// Creates the method-channel-backed [HomeApi] (IO platforms).
HomeApi createHomeService() => const MethodChannelHomeApi();

/// [HomeApi] over the `fah/home` method channel. List sizes and failures
/// are mirrored into [AppLog] under the `home` tag (the native side logs
/// the same tag via NSLog).
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
      AppLog.i('home', 'requestAccess → $granted');
      return granted ?? false;
    } on MissingPluginException {
      // No native handler (e.g. unit tests) — treat as denied.
      return false;
    }
  }

  @override
  Future<List<HomeInfo>> listHomes() async {
    final raw = await _invokeList('listHomes');
    final homes = [
      for (final entry in raw)
        if (entry is Map)
          (
            id: entry['id']?.toString() ?? '',
            name: entry['name']?.toString() ?? '(unnamed)',
            primary: entry['primary'] == true,
            roomCount: (entry['roomCount'] as num?)?.toInt() ?? 0,
            accessoryCount: (entry['accessoryCount'] as num?)?.toInt() ?? 0,
          ),
    ];
    AppLog.i('home', 'listHomes → ${homes.length} homes');
    return homes;
  }

  @override
  Future<List<HomeRoom>> listRooms({String? homeId}) async {
    final raw = await _invokeList('listRooms', {'homeId': ?homeId});
    final rooms = [
      for (final entry in raw)
        if (entry is Map)
          (
            id: entry['id']?.toString() ?? '',
            name: entry['name']?.toString() ?? '(unnamed)',
            homeName: entry['homeName']?.toString() ?? '',
            accessoryCount: (entry['accessoryCount'] as num?)?.toInt() ?? 0,
          ),
    ];
    AppLog.i('home', 'listRooms → ${rooms.length} rooms');
    return rooms;
  }

  @override
  Future<List<HomeAccessory>> listAccessories({
    String? homeId,
    String? roomId,
  }) async {
    final raw = await _invokeList('listAccessories', {
      'homeId': ?homeId,
      'roomId': ?roomId,
    });
    final accessories = [
      for (final entry in raw)
        if (entry is Map) _parseAccessory(entry),
    ];
    AppLog.i('home', 'listAccessories → ${accessories.length} accessories');
    return accessories;
  }

  @override
  Future<HomeAccessory> readAccessory({required String id}) async {
    _ensureSupported();
    final Map<dynamic, dynamic>? raw;
    try {
      raw = await _channel.invokeMapMethod<dynamic, dynamic>('readAccessory', {
        'id': id,
      });
    } on MissingPluginException {
      throw _unsupported();
    } on PlatformException catch (error) {
      AppLog.i('home', 'readAccessory failed: ${error.message}');
      rethrow;
    }
    if (raw == null) throw StateError('no accessory with this id');
    return _parseAccessory(raw);
  }

  @override
  Future<void> writeCharacteristic({
    required String id,
    required String type,
    required Object value,
    String? name,
    String? room,
  }) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('writeCharacteristic', {
        'id': id,
        'type': type,
        'value': value,
        'name': ?name,
        'room': ?room,
      });
      AppLog.i('home', 'writeCharacteristic $type → ok ($id)');
    } on MissingPluginException {
      throw _unsupported();
    } on PlatformException catch (error) {
      AppLog.i('home', 'writeCharacteristic $type failed: ${error.message}');
      rethrow;
    }
  }

  @override
  Future<List<HomeScene>> listScenes({String? homeId}) async {
    final raw = await _invokeList('listScenes', {'homeId': ?homeId});
    final scenes = [
      for (final entry in raw)
        if (entry is Map)
          (
            id: entry['id']?.toString() ?? '',
            name: entry['name']?.toString() ?? '(unnamed)',
            homeName: entry['homeName']?.toString() ?? '',
            actionCount: (entry['actionCount'] as num?)?.toInt() ?? 0,
            executing: entry['executing'] == true,
          ),
    ];
    AppLog.i('home', 'listScenes → ${scenes.length} scenes');
    return scenes;
  }

  @override
  Future<void> executeScene({required String id}) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('executeScene', {'id': id});
      AppLog.i('home', 'executeScene → ok ($id)');
    } on MissingPluginException {
      throw _unsupported();
    } on PlatformException catch (error) {
      AppLog.i('home', 'executeScene failed: ${error.message}');
      rethrow;
    }
  }

  @override
  Future<void> setPower({
    required String id,
    required bool on,
    String? name,
    String? room,
  }) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('setPower', {
        'id': id,
        'on': on,
        'name': ?name,
        'room': ?room,
      });
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<void> setBrightness({
    required String id,
    required int value,
    String? name,
    String? room,
  }) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('setBrightness', {
        'id': id,
        'value': value,
        'name': ?name,
        'room': ?room,
      });
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  @override
  Future<void> setTargetTemperature({
    required String id,
    required double celsius,
    String? name,
    String? room,
  }) async {
    _ensureSupported();
    try {
      await _channel.invokeMethod<void>('setTargetTemperature', {
        'id': id,
        'celsius': celsius,
        'name': ?name,
        'room': ?room,
      });
    } on MissingPluginException {
      throw _unsupported();
    }
  }

  /// Shared list-call wrapper: platform gating, the unsupported mapping,
  /// and failure logging.
  Future<List<dynamic>> _invokeList(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (!homePlatformSupported) throw _unsupported();
    try {
      return await _channel.invokeListMethod<dynamic>(method, args) ?? const [];
    } on MissingPluginException {
      throw _unsupported();
    } on PlatformException catch (error) {
      AppLog.i('home', '$method failed: ${error.message}');
      rethrow;
    }
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
      services: [
        for (final service in map['services'] as List? ?? const [])
          if (service is Map) _parseService(service),
      ],
    );
  }

  static HomeServiceInfo _parseService(Map<dynamic, dynamic> map) {
    return (
      type: map['type']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      characteristics: [
        for (final characteristic
            in map['characteristics'] as List? ?? const [])
          if (characteristic is Map)
            (
              type: characteristic['type']?.toString() ?? '',
              value: characteristic['value'] as Object?,
              readable: characteristic['readable'] == true,
              writable: characteristic['writable'] == true,
            ),
      ],
    );
  }

  static void _ensureSupported() {
    if (!homePlatformSupported) throw _unsupported();
  }

  static StateError _unsupported() =>
      StateError('Home control is not supported on this platform.');
}
