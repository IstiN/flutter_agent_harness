// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

export 'package:fa/services/home_service_stub.dart'
    if (dart.library.io) 'package:fa/services/home_service_io.dart';

/// One readable/writable HomeKit characteristic. [type] is the raw HomeKit
/// characteristic type string (e.g. `powerState`, `brightness`); [value] is
/// the last read value (bool/num/String) when it was read.
typedef HomeCharacteristic = ({
  String type,
  Object? value,
  bool readable,
  bool writable,
});

/// One HomeKit service of an accessory with its characteristics.
typedef HomeServiceInfo = ({
  String type,
  String name,
  List<HomeCharacteristic> characteristics,
});

/// One HomeKit accessory. [category] is one of `lightbulb`, `switch`,
/// `outlet`, `thermostat`, or the raw HomeKit category type for anything
/// else. The state fields are present only when the accessory exposed the
/// matching characteristic: [isOn] (power state), [brightness] (0–100),
/// [targetTemperature] (°C). [services] is the full service/characteristic
/// breakdown (values read for reachable accessories).
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
  List<HomeServiceInfo> services,
});

/// One HomeKit home.
typedef HomeInfo = ({
  String id,
  String name,
  bool primary,
  int roomCount,
  int accessoryCount,
});

/// One room in a HomeKit home.
typedef HomeRoom = ({
  String id,
  String name,
  String homeName,
  int accessoryCount,
});

/// One HomeKit action set (scene).
typedef HomeScene = ({
  String id,
  String name,
  String homeName,
  int actionCount,
  bool executing,
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

  /// Every home the user has; empty when access is denied.
  Future<List<HomeInfo>> listHomes();

  /// Every room (optionally limited to the home with [homeId]); empty when
  /// access is denied.
  Future<List<HomeRoom>> listRooms({String? homeId});

  /// Every accessory across all homes and rooms (optionally limited to
  /// [homeId] / [roomId]); empty when access is denied.
  Future<List<HomeAccessory>> listAccessories({String? homeId, String? roomId});

  /// Re-reads every readable characteristic of the accessory with [id] and
  /// returns it with fresh values.
  Future<HomeAccessory> readAccessory({required String id});

  /// Writes [value] (bool/num/String) to ANY writable characteristic of the
  /// accessory with [id], addressed by its HomeKit [type] string.
  Future<void> writeCharacteristic({
    required String id,
    required String type,
    required Object value,
  });

  /// Every action set (scene), optionally limited to [homeId].
  Future<List<HomeScene>> listScenes({String? homeId});

  /// Executes the action set (scene) with [id].
  Future<void> executeScene({required String id});

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
