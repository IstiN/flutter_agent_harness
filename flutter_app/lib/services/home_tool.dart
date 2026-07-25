// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/services/home_service.dart';

/// Name of the agent tool that lists the user's smart-home accessories.
const homeDevicesToolName = 'home_devices';

/// Names of the agent tools that control the user's smart-home accessories.
const homeTurnOnToolName = 'home_turn_on';
const homeTurnOffToolName = 'home_turn_off';
const homeSetToolName = 'home_set';

/// The shared availability gate: `null` when the home may be controlled,
/// otherwise the user-facing explanation (unsupported platform, or access
/// denied with where to enable it). Requests OS access on the first call.
Future<String?> _unavailable(HomeApi home) async {
  if (!await home.isAvailable) {
    return 'Home control is not supported on this platform (HomeKit is '
        'available on iOS only).';
  }
  // The OS shows its access prompt at most once; later calls return the
  // stored decision without prompting again.
  if (!await home.requestAccess()) {
    return 'Home access was denied. The user can enable it in Settings → '
        'Privacy & Security → HomeKit (iOS), then ask again.';
  }
  return null;
}

/// Creates the `home_devices` tool bound to [home].
///
/// Read-only: the tool lists homes, rooms, and accessories with their
/// current state and never writes. When the OS has not granted access yet
/// the first call requests it (the platform prompt appears once); a denial
/// is reported with where to enable it. The description/result texts are
/// LLM-facing and stay literal English (not UI copy).
AgentTool homeDevicesTool(HomeApi home) {
  return AgentTool(
    name: homeDevicesToolName,
    label: 'home_devices',
    // Listing accessories mutates nothing.
    tier: ApprovalTier.read,
    description:
        "List the user's smart-home accessories (read-only, iOS HomeKit). "
        'Use for questions like "which lights are on?" and before '
        'home_turn_on/home_turn_off/home_set. Returns rooms with their '
        'accessories and current state (on/off, brightness, target '
        'temperature).',
    parameters: const {'type': 'object', 'properties': {}},
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(home);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final accessories = await home.listAccessories();
      return ToolExecutionResult.text(_render(accessories));
    },
  );
}

/// The `match` parameter schema the control tools share.
const _matchProperties = {
  'match': {
    'type': 'string',
    'description':
        'Which accessory: name text (case-insensitive) as listed by '
        'home_devices (required)',
  },
};

/// Creates the `home_turn_on`/`home_turn_off` tools bound to [home].
///
/// Tier write: switching a device is a user-visible action, so the approval
/// gate applies — the tool confirms the resolved accessory in its result.
AgentTool homePowerTool(HomeApi home, {required bool turnOn}) {
  final name = turnOn ? homeTurnOnToolName : homeTurnOffToolName;
  return AgentTool(
    name: name,
    label: name,
    tier: ApprovalTier.write,
    description:
        'Turn ${turnOn ? 'on' : 'off'} a smart-home accessory (light, '
        'switch, outlet — iOS HomeKit). First list with home_devices, '
        'then call this with `match` set to the accessory name.',
    parameters: const {
      'type': 'object',
      'properties': {..._matchProperties},
      'required': ['match'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(home);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final found = await _find(home, arguments);
      if (found.error != null) return ToolExecutionResult.text(found.error!);
      final accessory = found.accessory!;
      if (accessory.isOn == null) {
        return ToolExecutionResult.text(
          '${accessory.name} has no on/off control.',
        );
      }
      await home.setPower(id: accessory.id, on: turnOn);
      return ToolExecutionResult.text(
        'Turned ${turnOn ? 'on' : 'off'} ${_renderName(accessory)}.'
        '${_unreachableNote(accessory)}',
      );
    },
  );
}

/// Creates the `home_set` tool bound to [home]: brightness (lights) or
/// target temperature (thermostats).
///
/// Tier write for the same reason as the power tools. Exactly one of
/// `brightness` / `temperature` is required per call.
AgentTool homeSetTool(HomeApi home) {
  return AgentTool(
    name: homeSetToolName,
    label: homeSetToolName,
    tier: ApprovalTier.write,
    description:
        'Set the brightness of a light (0-100) or the target temperature '
        'of a thermostat (°C) — iOS HomeKit. First list with home_devices, '
        'then call this with `match` set to the accessory name and exactly '
        'one of `brightness` / `temperature`.',
    parameters: const {
      'type': 'object',
      'properties': {
        ..._matchProperties,
        'brightness': {
          'type': 'integer',
          'description': 'Brightness 0-100 (lights only)',
        },
        'temperature': {
          'type': 'number',
          'description': 'Target temperature in °C (thermostats only)',
        },
      },
      'required': ['match'],
    },
    execute: (arguments, cancelToken, onUpdate) async {
      final unavailable = await _unavailable(home);
      if (unavailable != null) return ToolExecutionResult.text(unavailable);
      final hasBrightness = arguments['brightness'] != null;
      final hasTemperature = arguments['temperature'] != null;
      if (hasBrightness == hasTemperature) {
        return ToolExecutionResult.text(
          'Error: exactly one of brightness / temperature is required.',
        );
      }
      final found = await _find(home, arguments);
      if (found.error != null) return ToolExecutionResult.text(found.error!);
      final accessory = found.accessory!;
      if (hasBrightness) {
        if (accessory.brightness == null) {
          return ToolExecutionResult.text(
            '${accessory.name} has no brightness control.',
          );
        }
        final value = homeBrightness(arguments['brightness'] as num?);
        await home.setBrightness(id: accessory.id, value: value);
        return ToolExecutionResult.text(
          'Set ${_renderName(accessory)} to $value% brightness.'
          '${_unreachableNote(accessory)}',
        );
      }
      if (accessory.targetTemperature == null) {
        return ToolExecutionResult.text(
          '${accessory.name} has no target-temperature control.',
        );
      }
      final celsius = homeTemperature(arguments['temperature'] as num?);
      await home.setTargetTemperature(id: accessory.id, celsius: celsius);
      return ToolExecutionResult.text(
        'Set ${_renderName(accessory)} to ${celsius.toStringAsFixed(1)}°C.'
        '${_unreachableNote(accessory)}',
      );
    },
  );
}

/// Result of [_find]: either the matched [accessory] or an [error] text.
typedef _FindResult = ({HomeAccessory? accessory, String? error});

/// Resolves the `match` argument to a single accessory: an exact
/// (case-insensitive) name match wins over partial matches; an ambiguous or
/// unknown match answers with a recoverable error.
Future<_FindResult> _find(HomeApi home, Map<String, dynamic> arguments) async {
  final matchText = (arguments['match'] ?? '').toString().trim();
  if (matchText.isEmpty) {
    return (accessory: null, error: 'Error: match is required.');
  }
  final accessories = await home.listAccessories();
  final needle = matchText.toLowerCase();
  final exact = accessories
      .where((accessory) => accessory.name.toLowerCase() == needle)
      .toList();
  if (exact.length == 1) return (accessory: exact.single, error: null);
  final partial = accessories
      .where((accessory) => accessory.name.toLowerCase().contains(needle))
      .toList();
  if (exact.isEmpty && partial.length == 1) {
    return (accessory: partial.single, error: null);
  }
  final candidates = exact.isNotEmpty ? exact : partial;
  if (candidates.isEmpty) {
    return (
      accessory: null,
      error:
          'No accessory matching "$matchText" — list them with '
          'home_devices first.',
    );
  }
  final lines = [
    'Several accessories match "$matchText" — be more specific:',
    for (final accessory in candidates) '- ${_renderName(accessory)}',
  ];
  return (accessory: null, error: lines.join('\n'));
}

String _render(List<HomeAccessory> accessories) {
  if (accessories.isEmpty) {
    return 'No accessories found — the home is empty or access was not '
        'granted.';
  }
  final lines = <String>[];
  String? lastHome;
  String? lastRoom;
  for (final accessory in accessories) {
    if (accessory.homeName != lastHome) {
      lastHome = accessory.homeName;
      lastRoom = null;
      lines.add('Home "${accessory.homeName}":');
    }
    if (accessory.room != lastRoom) {
      lastRoom = accessory.room;
      lines.add('  ${accessory.room}:');
    }
    lines.add('  - ${_renderAccessory(accessory)}');
  }
  return lines.join('\n');
}

String _renderAccessory(HomeAccessory accessory) {
  final parts = <String>[
    if (accessory.isOn case final isOn?) isOn ? 'on' : 'off',
    if (accessory.brightness case final brightness?) 'brightness $brightness%',
    if (accessory.targetTemperature case final celsius?)
      'target ${celsius.toStringAsFixed(1)}°C',
    if (!accessory.reachable) 'unreachable',
  ];
  final state = parts.isEmpty ? '' : ' — ${parts.join(', ')}';
  return '${accessory.name} (${accessory.category})$state';
}

String _renderName(HomeAccessory accessory) =>
    '${accessory.name} (${accessory.room})';

String _unreachableNote(HomeAccessory accessory) => accessory.reachable
    ? ''
    : ' Note: the accessory is currently unreachable — the command may not '
          'take effect.';
