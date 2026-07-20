import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('AgentOutputManager', () {
    test('first allocation keeps the name, repeats get numeric suffixes', () {
      final manager = AgentOutputManager();
      expect(manager.allocate('Explore'), 'Explore');
      expect(manager.allocate('Explore'), 'Explore-2');
      expect(manager.allocate('Explore'), 'Explore-3');
      expect(manager.allocate('Other'), 'Other');
    });

    test('parent prefix nests ids dot-qualified', () {
      final manager = AgentOutputManager(parentPrefix: 'Parent');
      expect(manager.allocate('Child'), 'Parent.Child');
      expect(manager.allocate('Child'), 'Parent.Child-2');
    });
  });

  group('AgentOutputStore', () {
    test('allocates ids and stores content', () {
      final store = AgentOutputStore();
      final id = store.allocateId('Task');
      expect(id, 'Task');
      expect(store.contains(id), isFalse);
      store.put(id, 'output text');
      expect(store.get(id), 'output text');
      expect(store.availableIds, ['Task']);
      store.put(id, 'replaced');
      expect(store.get(id), 'replaced');
    });
  });

  group('resolveAgentUrl', () {
    late AgentOutputStore store;

    setUp(() {
      store = AgentOutputStore();
      store.put(
        'Explorer',
        '{"summary": "s", "findings": [{"path": "a.dart", "note": "n"}, {"path": "b.dart"}]}',
      );
      store.put('Task', 'plain text output');
      store.put('Explorer.Child', 'nested output');
    });

    test('rejects non-agent URLs', () {
      expect(
        () => resolveAgentUrl('https://x', store),
        throwsA(isA<AgentUrlException>()),
      );
    });

    test('requires an output id', () {
      expect(
        () => resolveAgentUrl('agent://', store),
        throwsA(
          isA<AgentUrlException>().having(
            (e) => e.message,
            'message',
            contains('requires an output ID'),
          ),
        ),
      );
    });

    test('agent://<id> resolves the full output as markdown', () {
      final resolution = resolveAgentUrl('agent://Task', store);
      expect(resolution.id, 'Task');
      expect(resolution.content, 'plain text output');
      expect(resolution.contentType, 'text/markdown');
      expect(resolution.notes, isEmpty);
    });

    test('agent://<id>/<child> resolves the nested dot-qualified output', () {
      final resolution = resolveAgentUrl('agent://Explorer/Child', store);
      expect(resolution.id, 'Explorer.Child');
      expect(resolution.content, 'nested output');
      expect(resolution.contentType, 'text/markdown');
    });

    test('agent://<id>/<dot.path> extracts from JSON content', () {
      final resolution = resolveAgentUrl(
        'agent://Explorer/findings.0.path',
        store,
      );
      expect(resolution.content, '"a.dart"');
      expect(resolution.contentType, 'application/json');
      expect(resolution.notes, ['Extracted: findings.0.path']);
    });

    test('agent://<id>?q=<query> extracts via the query form', () {
      final resolution = resolveAgentUrl('agent://Explorer?q=summary', store);
      expect(resolution.content, '"s"');
      expect(resolution.contentType, 'application/json');
    });

    test('path and query forms cannot combine', () {
      expect(
        () => resolveAgentUrl('agent://Explorer/findings?q=x', store),
        throwsA(
          isA<AgentUrlException>().having(
            (e) => e.message,
            'message',
            contains('cannot combine'),
          ),
        ),
      );
    });

    test('unknown ids fail with the available list', () {
      expect(
        () => resolveAgentUrl('agent://Nope', store),
        throwsA(
          isA<AgentUrlException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Not found: Nope'), contains('Explorer')),
          ),
        ),
      );
    });

    test('extraction against non-JSON content fails cleanly', () {
      expect(
        () => resolveAgentUrl('agent://Task/some.path', store),
        throwsA(
          isA<AgentUrlException>().having(
            (e) => e.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
    });

    test(
      'a slash segment naming no nested output falls back to extraction',
      () {
        // `Explorer/Child` resolves nested (see above), but a store without
        // `Parent.Child` treats the segment as a JSON key.
        final json = AgentOutputStore();
        json.put('Parent', '{"Child": {"value": 42}}');
        final resolution = resolveAgentUrl('agent://Parent/Child.value', json);
        expect(resolution.content, '42');
        expect(resolution.notes, ['Extracted: Child.value']);
      },
    );

    test('missing keys and bad indices name the failing segment', () {
      expect(
        () => resolveAgentUrl('agent://Explorer/findings.9.path', store),
        throwsA(
          isA<AgentUrlException>().having(
            (e) => e.message,
            'message',
            contains('no index "9"'),
          ),
        ),
      );
      expect(
        () => resolveAgentUrl('agent://Explorer/summary.deeper', store),
        throwsA(
          isA<AgentUrlException>().having(
            (e) => e.message,
            'message',
            contains('descends into a scalar'),
          ),
        ),
      );
    });
  });
}
