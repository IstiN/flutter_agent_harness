/// Tests for the sealed [AgentHarnessException] hierarchy.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('AgentHarnessException', () {
    test('toString includes the runtime type and message', () {
      const exception = ConfigException('missing api key');
      expect(exception.toString(), 'ConfigException: missing api key');
    });

    test('carries cause and causeStack', () {
      final cause = FormatException('bad json');
      final causeStack = StackTrace.current;
      final exception = SessionException(
        'could not read session',
        cause: cause,
        causeStack: causeStack,
      );
      expect(exception.cause, same(cause));
      expect(exception.causeStack, same(causeStack));
    });

    test('cause and causeStack default to null', () {
      const exception = ConfigException('nope');
      expect(exception.cause, isNull);
      expect(exception.causeStack, isNull);
    });

    test('ToolNotFoundException composes its message from the tool name', () {
      final exception = ToolNotFoundException('search');
      expect(exception.toolName, 'search');
      expect(exception.message, 'Tool search not found in registry');
      expect(exception.toString(), contains('ToolNotFoundException'));
    });

    test('ToolValidationException carries the tool name and message', () {
      const exception = ToolValidationException(
        'search',
        'argument "query" must be a string',
      );
      expect(exception.toolName, 'search');
      expect(exception.message, 'argument "query" must be a string');
    });

    test('the hierarchy is exhaustively switchable', () {
      final exceptions = <AgentHarnessException>[
        const ConfigException('c'),
        ToolNotFoundException('t'),
        const ToolValidationException('t', 'v'),
        const SessionException('s'),
        const CompactionException('k'),
      ];
      final kinds = exceptions.map((exception) {
        return switch (exception) {
          ConfigException() => 'config',
          ToolNotFoundException() => 'tool-not-found',
          ToolValidationException() => 'tool-validation',
          SessionException() => 'session',
          CompactionException() => 'compaction',
        };
      }).toList();
      expect(kinds, [
        'config',
        'tool-not-found',
        'tool-validation',
        'session',
        'compaction',
      ]);
    });

    test('CompactionException carries its error code', () {
      const exception = CompactionException(
        'provider down',
        code: CompactionErrorCode.summarizationFailed,
      );
      expect(exception.code, CompactionErrorCode.summarizationFailed);
      expect(exception.message, 'provider down');
      expect(exception.toString(), contains('CompactionException'));
    });

    test('all subtypes implement Exception', () {
      expect(const ConfigException('c'), isA<Exception>());
      expect(ToolNotFoundException('t'), isA<Exception>());
      expect(const ToolValidationException('t', 'v'), isA<Exception>());
      expect(const SessionException('s'), isA<Exception>());
      expect(const CompactionException('k'), isA<Exception>());
    });
  });
}
