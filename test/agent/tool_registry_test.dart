import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

AgentTool _tool(
  String name, {
  Map<String, dynamic> parameters = const {},
  AgentToolExecute? execute,
  ToolExecutionMode? executionMode,
}) {
  return AgentTool(
    name: name,
    description: '$name tool',
    parameters: parameters,
    execute:
        execute ??
        (args, cancelToken, onUpdate) async => ToolExecutionResult.text('ok'),
    executionMode: executionMode,
  );
}

ToolCall _call(String name, [Map<String, dynamic> args = const {}]) {
  return ToolCall(id: 'id-1', name: name, arguments: args);
}

void main() {
  group('AgentTool', () {
    test('is a Tool usable in a Context', () {
      final tool = _tool('read');
      final context = Context(messages: const [], tools: [tool]);
      expect(context.tools!.single.name, 'read');
      expect(context.tools!.single, isA<Tool>());
    });

    test('label and executionMode are optional', () {
      final plain = _tool('a');
      expect(plain.label, isNull);
      expect(plain.executionMode, isNull);
      final fancy = AgentTool(
        name: 'b',
        description: 'b tool',
        execute: (args, cancelToken, onUpdate) async =>
            ToolExecutionResult.text('ok'),
        label: 'B',
        executionMode: ToolExecutionMode.sequential,
      );
      expect(fancy.label, 'B');
      expect(fancy.executionMode, ToolExecutionMode.sequential);
    });
  });

  group('ToolRegistry', () {
    test('registers and looks up tools by name', () {
      final registry = ToolRegistry([_tool('read'), _tool('write')]);
      expect(registry.length, 2);
      expect(registry.contains('read'), isTrue);
      expect(registry.contains('nope'), isFalse);
      expect(registry.lookup('write')!.description, 'write tool');
      expect(registry.lookup('nope'), isNull);
      expect(registry.names, ['read', 'write']);
    });

    test('operator [] throws ToolNotFoundException for unknown tool', () {
      final registry = ToolRegistry();
      expect(
        () => registry['ghost'],
        throwsA(
          isA<ToolNotFoundException>().having(
            (e) => e.toolName,
            'toolName',
            'ghost',
          ),
        ),
      );
    });

    test('duplicate name throws ConfigException', () {
      expect(
        () => ToolRegistry([_tool('read'), _tool('read')]),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('read'),
          ),
        ),
      );
    });

    test('empty name throws ConfigException', () {
      expect(() => ToolRegistry([_tool('')]), throwsA(isA<ConfigException>()));
    });

    test('register and unregister mutate the registry', () {
      final registry = ToolRegistry();
      registry.register(_tool('read'));
      expect(registry.contains('read'), isTrue);
      expect(registry.unregister('read'), isTrue);
      expect(registry.unregister('read'), isFalse);
      expect(registry.contains('read'), isFalse);
    });

    test('tools getter exposes Tool list for Context building', () {
      final registry = ToolRegistry([_tool('read')]);
      final tools = registry.tools;
      expect(tools, hasLength(1));
      expect(tools.single, isA<Tool>());
      expect(() => tools.add(registry.tools.single), throwsUnsupportedError);
    });

    test('agentTools getter exposes the registered AgentTools', () {
      final registry = ToolRegistry([_tool('read')]);
      expect(registry.agentTools.single, isA<AgentTool>());
      expect(
        () => registry.agentTools.add(_tool('write')),
        throwsUnsupportedError,
      );
    });

    group('executor', () {
      test('throws ToolNotFoundException for unknown tool', () {
        final registry = ToolRegistry([_tool('read')]);
        expect(
          registry.executor(_call('ghost'), null, null),
          throwsA(isA<ToolNotFoundException>()),
        );
      });

      test('throws ToolValidationException for invalid arguments', () async {
        var executed = false;
        final registry = ToolRegistry([
          _tool(
            'read',
            parameters: const {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
              },
              'required': ['path'],
            },
            execute: (args, cancelToken, onUpdate) async {
              executed = true;
              return ToolExecutionResult.text('ok');
            },
          ),
        ]);
        await expectLater(
          registry.executor(_call('read'), null, null),
          throwsA(
            isA<ToolValidationException>().having(
              (e) => e.toolName,
              'toolName',
              'read',
            ),
          ),
        );
        expect(executed, isFalse);
      });

      test('valid arguments reach execute coerced', () async {
        Map<String, dynamic>? received;
        final registry = ToolRegistry([
          _tool(
            'repeat',
            parameters: const {
              'type': 'object',
              'properties': {
                'count': {'type': 'integer'},
              },
              'required': ['count'],
            },
            execute: (args, cancelToken, onUpdate) async {
              received = args;
              return ToolExecutionResult.text('done');
            },
          ),
        ]);
        final result = await registry.executor(
          _call('repeat', {'count': '3'}),
          null,
          null,
        );
        expect(received, {'count': 3});
        expect(result.content, [isA<TextContent>()]);
      });

      test('cancelToken and onUpdate are passed through', () async {
        CancelToken? seenToken;
        ToolUpdateCallback? seenUpdate;
        final registry = ToolRegistry([
          _tool(
            'read',
            execute: (args, cancelToken, onUpdate) async {
              seenToken = cancelToken;
              seenUpdate = onUpdate;
              return ToolExecutionResult.text('ok');
            },
          ),
        ]);
        final source = CancelTokenSource();
        void onUpdate(ToolExecutionResult partial) {}
        await registry.executor(_call('read'), source.token, onUpdate);
        expect(identical(seenToken, source.token), isTrue);
        expect(identical(seenUpdate, onUpdate), isTrue);
      });
    });
  });
}
