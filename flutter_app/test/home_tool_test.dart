// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/home_service.dart';
import 'package:fa/services/home_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Configurable fake [HomeApi] — the host-side tests never touch the real
/// method channel.
final class FakeHomeApi implements HomeApi {
  FakeHomeApi({
    this.available = true,
    this.granted = true,
    List<HomeAccessory>? accessories,
  }) : accessoriesToReturn = accessories ?? _defaultAccessories;

  bool available;
  bool granted;
  List<HomeAccessory> accessoriesToReturn;
  int requestAccessCalls = 0;
  final powerCalls = <({String id, bool on})>[];
  final brightnessCalls = <({String id, int value})>[];
  final temperatureCalls = <({String id, double celsius})>[];
  final writeCalls = <({String id, String type, Object value})>[];

  static const _defaultAccessories = <HomeAccessory>[
    (
      id: 'a-light',
      name: 'Ceiling Light',
      room: 'Living Room',
      homeName: 'My Home',
      category: 'lightbulb',
      reachable: true,
      isOn: true,
      brightness: 80,
      targetTemperature: null,
      services: [],
    ),
    (
      id: 'a-thermo',
      name: 'Thermostat',
      room: 'Hallway',
      homeName: 'My Home',
      category: 'thermostat',
      reachable: true,
      isOn: null,
      brightness: null,
      targetTemperature: 21.5,
      services: [],
    ),
    (
      id: 'a-switch',
      name: 'Porch Switch',
      room: 'Entry',
      homeName: 'My Home',
      category: 'switch',
      reachable: false,
      isOn: false,
      brightness: null,
      targetTemperature: null,
      services: [],
    ),
  ];

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> requestAccess() async {
    requestAccessCalls++;
    return granted;
  }

  @override
  Future<List<HomeInfo>> listHomes() async => const [];

  @override
  Future<List<HomeRoom>> listRooms({String? homeId}) async => const [];

  @override
  Future<List<HomeAccessory>> listAccessories({
    String? homeId,
    String? roomId,
  }) async => accessoriesToReturn;

  @override
  Future<HomeAccessory> readAccessory({required String id}) async =>
      accessoriesToReturn.firstWhere((accessory) => accessory.id == id);

  @override
  Future<void> writeCharacteristic({
    required String id,
    required String type,
    required Object value,
  }) async {
    writeCalls.add((id: id, type: type, value: value));
  }

  @override
  Future<List<HomeScene>> listScenes({String? homeId}) async => const [];

  @override
  Future<void> executeScene({required String id}) async {}

  @override
  Future<void> setPower({required String id, required bool on}) async {
    powerCalls.add((id: id, on: on));
  }

  @override
  Future<void> setBrightness({required String id, required int value}) async {
    brightnessCalls.add((id: id, value: value));
  }

  @override
  Future<void> setTargetTemperature({
    required String id,
    required double celsius,
  }) async {
    temperatureCalls.add((id: id, celsius: celsius));
  }
}

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('homeDevicesTool', () {
    test('is a read-tier tool; the control tools are write-tier', () {
      final home = FakeHomeApi();
      expect(homeDevicesTool(home).tier, ApprovalTier.read);
      expect(homeDevicesTool(home).name, homeDevicesToolName);
      expect(homePowerTool(home, turnOn: true).name, homeTurnOnToolName);
      expect(homePowerTool(home, turnOn: true).tier, ApprovalTier.write);
      expect(homePowerTool(home, turnOn: false).name, homeTurnOffToolName);
      expect(homeSetTool(home).name, homeSetToolName);
      expect(homeSetTool(home).tier, ApprovalTier.write);
    });

    test('renders homes, rooms, and accessory state', () async {
      final tool = homeDevicesTool(FakeHomeApi());

      final result = await tool.execute(const {}, null, null);

      final text = _textOf(result);
      expect(text, contains('Home "My Home":'));
      expect(text, contains('Living Room:'));
      expect(
        text,
        contains('- Ceiling Light (lightbulb) — on, brightness 80%'),
      );
      expect(text, contains('- Thermostat (thermostat) — target 21.5°C'));
      expect(text, contains('- Porch Switch (switch) — off, unreachable'));
    });

    test('empty home answers with a "no accessories" text', () async {
      final tool = homeDevicesTool(FakeHomeApi(accessories: const []));

      final result = await tool.execute(const {}, null, null);

      expect(_textOf(result), contains('No accessories found'));
    });

    test('denied access requests once, then reports guidance', () async {
      final home = FakeHomeApi(granted: false);
      final tool = homeDevicesTool(home);

      final result = await tool.execute(const {}, null, null);

      expect(home.requestAccessCalls, 1);
      final text = _textOf(result);
      expect(text, contains('denied'));
      expect(text, contains('HomeKit'));
    });

    test('unsupported platform answers with a clean note', () async {
      final home = FakeHomeApi(available: false);
      final tool = homeDevicesTool(home);

      final result = await tool.execute(const {}, null, null);

      expect(_textOf(result), contains('not supported on this platform'));
      expect(home.requestAccessCalls, 0);
    });
  });

  group('home turn_on / turn_off', () {
    test('exact name match switches the accessory', () async {
      final home = FakeHomeApi();
      final tool = homePowerTool(home, turnOn: false);

      final result = await tool.execute(
        const {'match': 'ceiling light'},
        null,
        null,
      );

      expect(home.powerCalls, [(id: 'a-light', on: false)]);
      expect(_textOf(result), contains('Turned off Ceiling Light'));
    });

    test('a single partial match resolves', () async {
      final home = FakeHomeApi();
      final tool = homePowerTool(home, turnOn: true);

      final result = await tool.execute(const {'match': 'porch'}, null, null);

      expect(home.powerCalls, [(id: 'a-switch', on: true)]);
      final text = _textOf(result);
      expect(text, contains('Turned on Porch Switch'));
      // The accessory is unreachable — the result says so.
      expect(text, contains('unreachable'));
    });

    test('unknown match answers with a recoverable error', () async {
      final home = FakeHomeApi();
      final tool = homePowerTool(home, turnOn: true);

      final result = await tool.execute(const {'match': 'garage'}, null, null);

      expect(home.powerCalls, isEmpty);
      final text = _textOf(result);
      expect(text, contains('No accessory matching "garage"'));
      expect(text, contains('home_devices'));
    });

    test('ambiguous match lists the candidates', () async {
      final home = FakeHomeApi(
        accessories: [
          FakeHomeApi._defaultAccessories[0],
          (
            id: 'a-lamp',
            name: 'Ceiling Lamp',
            room: 'Bedroom',
            homeName: 'My Home',
            category: 'lightbulb',
            reachable: true,
            isOn: false,
            brightness: null,
            targetTemperature: null,
            services: const [],
          ),
        ],
      );
      final tool = homePowerTool(home, turnOn: true);

      final result = await tool.execute(const {'match': 'ceiling'}, null, null);

      expect(home.powerCalls, isEmpty);
      final text = _textOf(result);
      expect(text, contains('Several accessories match "ceiling"'));
      expect(text, contains('Ceiling Light'));
      expect(text, contains('Ceiling Lamp'));
    });

    test('an accessory without power control is reported', () async {
      final home = FakeHomeApi();
      final tool = homePowerTool(home, turnOn: true);

      final result = await tool.execute(
        const {'match': 'thermostat'},
        null,
        null,
      );

      expect(home.powerCalls, isEmpty);
      expect(_textOf(result), contains('Thermostat has no on/off control'));
    });

    test('match is required', () async {
      final home = FakeHomeApi();
      final tool = homePowerTool(home, turnOn: true);

      final result = await tool.execute(const {}, null, null);

      expect(home.powerCalls, isEmpty);
      expect(_textOf(result), contains('match is required'));
    });
  });

  group('home_set', () {
    test('sets the brightness of a light', () async {
      final home = FakeHomeApi();
      final tool = homeSetTool(home);

      final result = await tool.execute(
        const {'match': 'Ceiling Light', 'brightness': 40},
        null,
        null,
      );

      expect(home.brightnessCalls, [(id: 'a-light', value: 40)]);
      expect(
        _textOf(result),
        contains('Set Ceiling Light (Living Room) to 40% brightness'),
      );
    });

    test('sets the target temperature of a thermostat', () async {
      final home = FakeHomeApi();
      final tool = homeSetTool(home);

      final result = await tool.execute(
        const {'match': 'Thermostat', 'temperature': 22.5},
        null,
        null,
      );

      expect(home.temperatureCalls, [(id: 'a-thermo', celsius: 22.5)]);
      expect(_textOf(result), contains('Set Thermostat (Hallway) to 22.5°C'));
    });

    test('exactly one of brightness / temperature is required', () async {
      final home = FakeHomeApi();
      final tool = homeSetTool(home);

      final neither = await tool.execute(
        const {'match': 'Ceiling Light'},
        null,
        null,
      );
      expect(_textOf(neither), contains('exactly one'));

      final both = await tool.execute(
        const {'match': 'Ceiling Light', 'brightness': 40, 'temperature': 20},
        null,
        null,
      );
      expect(_textOf(both), contains('exactly one'));
      expect(home.brightnessCalls, isEmpty);
      expect(home.temperatureCalls, isEmpty);
    });

    test('brightness on a thermostat is reported as unsupported', () async {
      final home = FakeHomeApi();
      final tool = homeSetTool(home);

      final result = await tool.execute(
        const {'match': 'Thermostat', 'brightness': 40},
        null,
        null,
      );

      expect(home.brightnessCalls, isEmpty);
      expect(_textOf(result), contains('Thermostat has no brightness control'));
    });

    test('out-of-range values fail cleanly', () async {
      final home = FakeHomeApi();
      final tool = homeSetTool(home);

      await expectLater(
        tool.execute(
          const {'match': 'Ceiling Light', 'brightness': 120},
          null,
          null,
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        tool.execute(
          const {'match': 'Thermostat', 'temperature': 80},
          null,
          null,
        ),
        throwsA(isA<StateError>()),
      );
      expect(home.brightnessCalls, isEmpty);
      expect(home.temperatureCalls, isEmpty);
    });
  });
}
