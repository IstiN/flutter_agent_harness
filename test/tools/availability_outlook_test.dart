// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// The outlook.* family (issue #327 Part 2): the office tools are
// office-host-bound, but every surface's tool list must SAY so instead of
// staying silent — the extension's Tools section renders a gated row with
// the add-in-only reason, and `tools: {outlook: false}` gates the family
// like any other.
import 'package:flutter_agent_harness/src/tools/availability.dart';
import 'package:test/test.dart';

void main() {
  group('outlook availability family', () {
    test('outlook is a known id with its three member tools', () {
      expect(knownToolIds, contains('outlook'));
      expect(coreToolFamilies['outlook'], {
        'outlook.read_current_item',
        'outlook.read_attachment',
        'outlook.insert_draft_body',
      });
    });

    test('toolAvailabilityIdOf resolves every member to the family', () {
      expect(toolAvailabilityIdOf('outlook.read_current_item'), 'outlook');
      expect(toolAvailabilityIdOf('outlook.read_attachment'), 'outlook');
      expect(toolAvailabilityIdOf('outlook.insert_draft_body'), 'outlook');
    });

    test('absent capability keeps the row visible with the host reason', () {
      final resolution = resolveToolAvailability(
        capabilities: const {
          'outlook': ToolCapability.absent(
            'available in the Outlook add-in host only',
          ),
        },
        scopes: const [],
      );
      final outlook = resolution.byId['outlook']!;
      expect(outlook.enabled, isFalse);
      expect(outlook.capabilityPresent, isFalse);
      expect(outlook.reason, 'available in the Outlook add-in host only');
    });

    test('present capability defaults on; config can gate the family', () {
      final on = resolveToolAvailability(
        capabilities: {'outlook': const ToolCapability.available()},
        scopes: const [],
      );
      expect(on.byId['outlook']!.enabled, isTrue);

      final off = resolveToolAvailability(
        capabilities: {'outlook': const ToolCapability.available()},
        scopes: [
          (
            ToolScope.runtime,
            ToolsConfig(tools: {'outlook': false}),
          ),
        ],
      );
      expect(off.byId['outlook']!.enabled, isFalse);
    });
  });
}
