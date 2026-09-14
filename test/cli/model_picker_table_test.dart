// Unit tests for the /model picker table (issue #278, AC2): exact rows
// from fake catalog specs, recency-then-price sorting, current marker,
// narrow-terminal elision (cost first, then provider), E3 pricing holes.
import 'package:flutter_agent_harness/src/cli/model_picker_table.dart';
import 'package:test/test.dart';

ModelRowSpec row({
  String provider = 'catalog',
  String modelId = 'model-a',
  int recency = 0,
  int? contextWindow = 200000,
  ({double input, double output})? cost = const (input: 0.30, output: 1.20),
  bool isCurrent = false,
}) => ModelRowSpec(
  provider: provider,
  modelId: modelId,
  recency: recency,
  contextWindow: contextWindow,
  cost: cost,
  isCurrent: isCurrent,
);

void main() {
  group('buildModelPickerTable', () {
    test('renders exact rows from fake catalog specs', () {
      final items = buildModelPickerTable([
        row(
          provider: 'zai',
          modelId: 'glm-5.3',
          contextWindow: 1048576,
          cost: const (input: 0.30, output: 1.20),
        ),
      ], 100);
      expect(items, hasLength(1));
      expect(items.single.key, 'zai|glm-5.3');
      expect(items.single.label, '  glm-5.3');
      expect(items.single.description, 'zai  1M  \$0.30/\$1.20');
    });

    test('sorts by recency, then cheaper total price, unpriced last', () {
      final items = buildModelPickerTable([
        row(modelId: 'pricey', recency: 1, cost: const (input: 1.0, output: 2.0)),
        row(modelId: 'unpriced', recency: 1, cost: null),
        row(modelId: 'newest', recency: 0, cost: const (input: 9.9, output: 0.0)),
        row(modelId: 'cheap', recency: 1, cost: const (input: 0.1, output: 0.2)),
      ], 200);
      expect(
        [for (final item in items) item.key],
        ['catalog|newest', 'catalog|cheap', 'catalog|pricey', 'catalog|unpriced'],
      );
    });

    test('marks the current model with ●', () {
      final items = buildModelPickerTable(
        [row(modelId: 'm', isCurrent: true)],
        100,
      );
      expect(items.single.label, startsWith('● '));
    });

    test('narrow terminals elide cost first, then provider; id + ctx stay',
        () {
      final rows = [
        row(
          modelId: 'model-one',
          provider: 'prov-A',
          contextWindow: 200000,
          cost: const (input: 0.30, output: 1.20),
        ),
        row(
          modelId: 'model-two',
          provider: 'prov-B',
          contextWindow: 128000,
          cost: const (input: 0.10, output: 0.30),
        ),
      ];
      // Wide: every column fits (elision kicks in below width 42).
      final wide = buildModelPickerTable(rows, 60);
      expect(wide.first.description, contains('prov-B'));
      expect(wide.first.description, contains(r'$0.10/$0.30'));
      // Narrow: cost column elided first, provider still visible.
      final mid = buildModelPickerTable(rows, 30);
      expect(mid.first.description, contains('prov-B'));
      expect(mid.first.description, isNot(contains(r'$')));
      // Narrower: provider elided too, id and context window remain.
      final narrow = buildModelPickerTable(rows, 20);
      expect(narrow.first.description, isNot(contains('prov-')));
      expect(
        [for (final item in narrow) item.description].join('|'),
        contains('200000'),
      );
    });

    test('E3: missing pricing renders — never 0.00', () {
      final items = buildModelPickerTable(
        [row(cost: null, contextWindow: 128000)],
        100,
      );
      expect(items.single.description, contains('—'));
      expect(items.single.description, isNot(contains('0.00')));
    });

    test('missing context window renders —', () {
      final items = buildModelPickerTable([row(contextWindow: null)], 100);
      expect(items.single.description, contains('—'));
    });
  });

  group('formatModelContextWindow', () {
    test('exact Mi/K multiples compact, others stay raw, null is —', () {
      expect(formatModelContextWindow(1048576), '1M');
      expect(formatModelContextWindow(128000), '125K');
      expect(formatModelContextWindow(2048), '2K');
      expect(formatModelContextWindow(12345), '12345');
      expect(formatModelContextWindow(null), '—');
    });
  });

  test('the picker carries a one-line footer hint', () {
    expect(modelPickerFooterHint, contains('esc'));
    expect(modelPickerFooterHint, contains('select'));
  });
}
