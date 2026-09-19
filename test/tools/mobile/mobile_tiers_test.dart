// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// The mobile.* capability floor per tier (issue #622): UT-floor-1 (store
// hides the automation family from the registry AND the advertised tool
// list; god shows all) and UT-floor-2 (a gated call tombstones with the
// tier + sideload link reason).
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _godOnlyNames = {
  'mobile.hierarchy',
  'mobile.tap',
  'mobile.swipe',
  'mobile.text',
  'mobile.screenshot',
  'mobile.shell',
};

Model _model() => Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AgentTool _stubTool(String name) => AgentTool(
  name: name,
  description: 'stub $name',
  execute: (arguments, cancelToken, onUpdate) async =>
      ToolExecutionResult.text('ok'),
);

/// A gate over the full mobile tool set (all 8 names), the way a host
/// that COULD provide everything constructs it before the floor prunes.
ToolAvailabilityGate _mobileGate() => ToolAvailabilityGate(
  toolsById: {
    'mobile': [_stubTool('mobile.launch'), _stubTool('mobile.logs')],
    'mobile_automation': [
      _stubTool('mobile.hierarchy'),
      _stubTool('mobile.tap'),
      _stubTool('mobile.swipe'),
      _stubTool('mobile.text'),
      _stubTool('mobile.screenshot'),
    ],
    'mobile_shell': [_stubTool('mobile.shell')],
  },
);

ToolAvailabilityResolution _resolve(Map<String, ToolCapability> floor) =>
    resolveToolAvailability(
      capabilities: {
        ...mobileCapabilityFloor(tier: MobileTier.store),
        ...floor,
      },
      scopes: const [],
    );

Agent _agent(ToolRegistry registry) => Agent(
  model: _model(),
  toolRegistry: registry,
  streamFunction: (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    stream.end();
    return stream;
  },
);

void main() {
  group('mobile availability families', () {
    test('the three ids are known with their member tools', () {
      expect(knownToolIds, containsAll(['mobile', 'mobile_automation', 'mobile_shell']));
      expect(coreToolFamilies['mobile'], {'mobile.launch', 'mobile.logs'});
      expect(coreToolFamilies['mobile_automation'], {
        'mobile.hierarchy',
        'mobile.tap',
        'mobile.swipe',
        'mobile.text',
        'mobile.screenshot',
      });
      expect(coreToolFamilies['mobile_shell'], {'mobile.shell'});
      expect(toolAvailabilityIdOf('mobile.tap'), 'mobile_automation');
      expect(toolAvailabilityIdOf('mobile.shell'), 'mobile_shell');
    });
  });

  group('UT-floor-1: capability floor per tier', () {
    test('store floor: automation + shell absent with the sideload reason', () {
      final floor = mobileCapabilityFloor(tier: MobileTier.store);
      expect(floor['mobile']!.present, isTrue);
      expect(floor['mobile_automation']!.present, isFalse);
      expect(
        floor['mobile_automation']!.absentReason,
        contains('https://fa1.dev/android'),
      );
      expect(floor['mobile_shell']!.present, isFalse);
    });

    test('god floor: everything present', () {
      final floor = mobileCapabilityFloor(tier: MobileTier.god);
      expect(
        floor.values.every((capability) => capability.present),
        isTrue,
      );
    });

    test('store: mobile.* gated names absent from registry and prompt list', () {
      final registry = ToolRegistry();
      final agent = _agent(registry);
      final gate = _mobileGate();
      gate.apply(
        _resolve(mobileCapabilityFloor(tier: MobileTier.store)),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      final advertised = agent.state.tools.map((tool) => tool.name).toSet();
      expect(advertised.intersection(_godOnlyNames), isEmpty);
      expect(advertised, containsAll(['mobile.launch', 'mobile.logs']));
      // Registry agrees with the advertised list, byte-wise as a set.
      expect(registry.tools.map((tool) => tool.name).toSet(), advertised);
    });

    test('god: the whole mobile set is advertised', () {
      final registry = ToolRegistry();
      final agent = _agent(registry);
      final gate = _mobileGate();
      gate.apply(
        _resolve(mobileCapabilityFloor(tier: MobileTier.god)),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      final advertised = agent.state.tools.map((tool) => tool.name).toSet();
      expect(advertised, containsAll(_godOnlyNames));
      expect(advertised, containsAll(['mobile.launch', 'mobile.logs']));
    });
  });

  group('UT-floor-2: gated call tombstone', () {
    test('tombstone names the tier and the sideload link (reason golden)',
        () async {
      final registry = ToolRegistry();
      final agent = _agent(registry);
      final gate = _mobileGate();
      final executor = gate.wrapExecutor((toolCall, cancelToken, onUpdate) async {
        return ToolExecutionResult.text('should never run');
      });
      gate.apply(
        _resolve(mobileCapabilityFloor(tier: MobileTier.store)),
        registry,
        agent,
        rebuildPrompt: () {},
      );
      final result = await executor(
        ToolCall(id: 't1', name: 'mobile.tap', arguments: const {'x': 1, 'y': 2}),
        null,
        null,
      );
      final text = result.content.whereType<TextContent>().single.text;
      // Golden: the honest reason names the tier and the sideload link.
      expect(
        text,
        contains(
          'requires the god tier (sideload build) — get it at '
          'https://fa1.dev/android',
        ),
      );
    });
  });
}
