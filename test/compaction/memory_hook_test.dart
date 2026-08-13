@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('CompactionManager memoryExtractionHook', () {
    test('hook is set when provided', () {
      final manager = CompactionManager(
        summarize: (request) async => SummarizationResult.success('summary'),
        memoryExtractionHook: (text) async {},
      );
      expect(manager.memoryExtractionHook, isNotNull);
    });

    test('hook defaults to null (backward compat)', () {
      final manager = CompactionManager(
        summarize: (request) async => SummarizationResult.success('summary'),
      );
      expect(manager.memoryExtractionHook, isNull);
    });
  });
}
