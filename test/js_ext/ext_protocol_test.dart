/// Tests for the commit wire contract: [parseExtCommit] on a fully-populated
/// payload, defaults for omitted optional fields, tolerance for absent
/// sections and unknown keys, and problem ACCUMULATION into a single
/// [ExtProtocolException].
library;

import 'package:flutter_agent_harness/src/js_ext/ext_bridge.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_manifest.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_protocol.dart';
import 'package:test/test.dart';

/// Parses [payload], expecting failure; returns the exception message.
String problemsOf(Object? payload) {
  late ExtProtocolException caught;
  try {
    parseExtCommit(payload);
  } on ExtProtocolException catch (e) {
    caught = e;
  }
  expect(
    caught,
    isNotNull,
    reason: 'expected ExtProtocolException for $payload',
  );
  return caught.message;
}

void main() {
  group('parseExtCommit valid payloads', () {
    test('full payload maps every section', () {
      final commit = parseExtCommit({
        'tools': [
          {
            'name': 'fetch_stats',
            'description': 'Fetches stats',
            'parameters': {'type': 'object'},
            'tier': 'read',
            'handle': 3,
          },
        ],
        'hooks': [
          {'event': 'afterToolCall', 'handle': 4},
          {'event': 'onSessionEnd', 'handle': 5},
        ],
        'slash': [
          {'name': 'hello-ext', 'description': 'Say hi', 'handle': 6},
        ],
        'flows': [
          {
            'id': 'add-provider',
            'title': 'Add provider',
            'description': 'd',
            'handle': 7,
            'fields': [
              {'name': 'base_url', 'label': 'Base URL'},
              {'name': 'api_key', 'label': 'Key', 'secret': true},
            ],
          },
        ],
      });
      final tool = commit.tools.single;
      expect(tool.name, 'fetch_stats');
      expect(tool.description, 'Fetches stats');
      expect(tool.parameters, {'type': 'object'});
      expect(tool.tier, 'read');
      expect(tool.handle, 3);
      expect(commit.hooks.map((h) => h.event), [
        ExtHookEvent.afterToolCall,
        ExtHookEvent.sessionEnd,
      ]);
      expect(commit.hooks.map((h) => h.handle), [4, 5]);
      final slash = commit.slash.single;
      expect(slash.name, 'hello-ext'); // stored without leading slash
      expect(slash.description, 'Say hi');
      expect(slash.handle, 6);
      final flow = commit.flows.single;
      expect(flow.id, 'add-provider');
      expect(flow.title, 'Add provider');
      expect(flow.fields, hasLength(2));
      expect(flow.fields[0].secret, isFalse);
      expect(flow.fields[1].secret, isTrue);
      expect(flow.handle, 7);
    });

    test(
      'omitted optional fields get documented defaults; unknown keys tolerated',
      () {
        final commit = parseExtCommit({
          'tools': [
            {'name': 'abc', 'handle': 2, 'extra': 'ignored'},
          ],
        });
        final tool = commit.tools.single;
        expect(tool.description, '');
        expect(tool.parameters, isEmpty);
        expect(tool.tier, 'exec');
        expect(tool.handle, 2);
      },
    );

    test('absent sections mean nothing registered, not an error', () {
      final commit = parseExtCommit({});
      expect(commit.tools, isEmpty);
      expect(commit.hooks, isEmpty);
      expect(commit.slash, isEmpty);
      expect(commit.flows, isEmpty);
    });
  });

  group('parseExtCommit accumulates every problem', () {
    test('non-map payloads', () {
      expect(problemsOf(null), contains('must be a JSON object'));
      expect(problemsOf(42), contains('must be a JSON object'));
      expect(problemsOf([1]), contains('must be a JSON object'));
      expect(problemsOf('x'), contains('must be a JSON object'));
    });

    test('one exception names every problem across all sections', () {
      final message = problemsOf({
        'tools': [
          {'name': 'BadName', 'handle': 1}, // pattern violation
          {
            'name': 'ok_name',
            'tier': 'mega',
            'handle': 2,
            'parameters': 'nope',
          },
          'not-a-map',
          {'name': 'ok2_name'}, // missing handle
        ],
        'hooks': [
          {'event': 'nope', 'handle': 5},
          {'handle': 6}, // missing event
        ],
        'slash': [
          {'name': '/lead', 'handle': 7},
          {'name': 'UPPER', 'handle': 8},
        ],
        'flows': [
          {'id': 'ok-flow', 'handle': 9, 'fields': <String>[]},
          {
            'id': 'ok2',
            'handle': 10,
            'fields': [
              {'name': 'f', 'label': ''},
            ],
          },
        ],
      });
      for (final fragment in [
        'tools[0]',
        'BadName',
        'tier must be one of',
        'parameters must be a JSON object',
        'tools[2] must be a JSON object',
        'tools[3]: handle must be an integer',
        'hooks[0]: event must be a known hook event name',
        'hooks[1]: event must be a known hook event name',
        '/lead',
        'UPPER',
        'flows[0].fields must be a non-empty list',
        'flows[1].fields[0]: label must be a non-empty string',
      ]) {
        expect(
          message,
          contains(fragment),
          reason: 'missing problem: $fragment',
        );
      }
      // Exactly the 11 enumerated problems, '; '-joined.
      expect(message.split('; ').length, 11);
    });

    test('wrong section types and wrong field types are problems', () {
      final message = problemsOf({
        'tools': 5,
        'hooks': 'nope',
        'slash': [
          {'name': 3, 'handle': '4'},
        ],
      });
      expect(message, contains('tools must be a list'));
      expect(message, contains('hooks must be a list'));
      expect(message, contains('slash[0]: name must be a non-empty string'));
      expect(message, contains('slash[0]: handle must be an integer'));
    });

    test('empty and missing required names', () {
      final message = problemsOf({
        'tools': [
          {'handle': 1},
        ],
        'flows': [
          {
            'handle': 2,
            'fields': [{}],
          },
        ],
      });
      expect(message, contains('tools[0]: name is required'));
      expect(message, contains('flows[0]: id is required'));
      expect(message, contains('flows[0].fields[0]: name is required'));
      expect(message, contains('flows[0].fields[0]: label is required'));
    });
  });

  group('ExtProtocolException', () {
    test('carries the message and toString is the message', () {
      const e = ExtProtocolException('boom');
      expect(e.message, 'boom');
      expect(e.toString(), 'boom');
    });
  });
}
