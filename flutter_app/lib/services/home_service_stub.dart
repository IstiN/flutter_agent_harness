// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/home_service.dart';

/// Whether the current platform has a native home backend (iOS HomeKit).
/// Always false here — this stub is selected where `dart:io` is unavailable
/// (web), so callers degrade to a clean "not supported" note.
bool get homePlatformSupported => false;

/// Creates the platform [HomeApi]. On web there is no smart-home backend,
/// so the service reports itself unavailable and every call is a no-op.
HomeApi createHomeService() => const _UnavailableHomeApi();

final class _UnavailableHomeApi implements HomeApi {
  const _UnavailableHomeApi();

  static StateError _unsupported() =>
      StateError('Home control is not supported on this platform.');

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<List<HomeInfo>> listHomes() => throw _unsupported();

  @override
  Future<List<HomeRoom>> listRooms({String? homeId}) => throw _unsupported();

  @override
  Future<List<HomeAccessory>> listAccessories({
    String? homeId,
    String? roomId,
  }) => throw _unsupported();

  @override
  Future<HomeAccessory> readAccessory({required String id}) =>
      throw _unsupported();

  @override
  Future<void> writeCharacteristic({
    required String id,
    required String type,
    required Object value,
  }) => throw _unsupported();

  @override
  Future<List<HomeScene>> listScenes({String? homeId}) => throw _unsupported();

  @override
  Future<void> executeScene({required String id}) => throw _unsupported();

  @override
  Future<void> setPower({required String id, required bool on}) =>
      throw _unsupported();

  @override
  Future<void> setBrightness({required String id, required int value}) =>
      throw _unsupported();

  @override
  Future<void> setTargetTemperature({
    required String id,
    required double celsius,
  }) => throw _unsupported();
}
