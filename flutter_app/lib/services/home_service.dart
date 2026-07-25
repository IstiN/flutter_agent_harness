// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'package:fa/services/home_service_stub.dart'
    if (dart.library.io) 'package:fa/services/home_service_io.dart';

/// One HomeKit accessory. [category] is one of `lightbulb`, `switch`,
/// `outlet`, `thermostat`, or the raw HomeKit category type for anything
/// else. The state fields are present only when the accessory exposed the
/// matching characteristic: [isOn] (power state), [brightness] (0–100),
/// [targetTemperature] (°C).
typedef HomeAccessory = ({
  String id,
  String name,
  String room,
  String homeName,
  String category,
  bool reachable,
  bool? isOn,
  int? brightness,
  double? targetTemperature,
});

/// Access to the user's smart home (HomeKit on iOS — there is no HomeKit
/// framework on macOS, and no equivalent on the other platforms).
///
/// Use [createHomeService] (conditionally imported above) to obtain the
/// platform implementation: the `fah/home` method channel on IO platforms,
/// a never-available stub on web. Tests inject fakes.
abstract interface class HomeApi {
  /// Whether this platform can control the home at all.
  Future<bool> get isAvailable;

  /// Asks the OS for home-data access (prompts once, then returns the
  /// stored decision). True when accessories may be listed and controlled.
  Future<bool> requestAccess();

  /// Every accessory across all homes and rooms; empty when access is
  /// denied.
  Future<List<HomeAccessory>> listAccessories();

  /// Switches the accessory with [id] on or off.
  Future<void> setPower({required String id, required bool on});

  /// Sets the brightness (0–100) of the accessory with [id].
  Future<void> setBrightness({required String id, required int value});

  /// Sets the target temperature (°C) of the accessory with [id].
  Future<void> setTargetTemperature({
    required String id,
    required double celsius,
  });
}

/// Validates a `brightness` argument (0–100, required) shared by the agent
/// tool and the JS bridge.
int homeBrightness(num? value) {
  if (value == null) throw StateError('brightness is required');
  final brightness = value.toInt();
  if (brightness < 0 || brightness > 100) {
    throw StateError('brightness must be between 0 and 100 (got $value)');
  }
  return brightness;
}

/// Validates a `temperature` argument (°C, 0–40, required) shared by the
/// agent tool and the JS bridge.
double homeTemperature(num? value) {
  if (value == null) throw StateError('temperature is required');
  final celsius = value.toDouble();
  if (celsius < 0 || celsius > 40) {
    throw StateError('temperature must be between 0 and 40 °C (got $value)');
  }
  return celsius;
}
