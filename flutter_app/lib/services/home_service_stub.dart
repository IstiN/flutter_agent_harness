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

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> requestAccess() async => false;

  @override
  Future<List<HomeAccessory>> listAccessories() =>
      throw StateError('Home control is not supported on this platform.');

  @override
  Future<void> setPower({required String id, required bool on}) =>
      throw StateError('Home control is not supported on this platform.');

  @override
  Future<void> setBrightness({required String id, required int value}) =>
      throw StateError('Home control is not supported on this platform.');

  @override
  Future<void> setTargetTemperature({
    required String id,
    required double celsius,
  }) => throw StateError('Home control is not supported on this platform.');
}
