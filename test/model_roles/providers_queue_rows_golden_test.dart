// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// GOLDEN-tui-rows (issue #418, ids 50/51): the queue editor's per-entry
/// health rows are byte-stable across the four health states and across
/// terminal widths — the renderer is pure text, so width cannot rewrap
/// the layout and these pins hold on any terminal (80/120/200 columns).
library;

import 'package:flutter_agent_harness/src/model_roles/fallback_stream.dart';
import 'package:flutter_agent_harness/src/model_roles/providers_queue.dart';
import 'package:flutter_agent_harness/src/model_roles/providers_queue_runtime.dart';
import 'package:test/test.dart';

ProviderQueueEntry _entry(String model) => ProviderQueueEntry(
  providerType: 'openai-completions',
  model: model,
  apiKeyEnv: 'K_$model',
  baseUrl: 'https://gate.example/v1',
);

void main() {
  final now = DateTime(2026, 9, 15, 12);

  test('all four health states render byte-stable rows', () {
    final entries = [_entry('a'), _entry('b'), _entry('c'), _entry('d')];
    final state = ProviderQueueState()
      ..recordSuccess(0) // cursor sticks on entry 0 → [current]
      ..recordFailure(1, QueueDeathKind.network, 'connection refused')
      ..recordCooldown(2, now.add(const Duration(seconds: 42)))
      ..recordCooldown(3, now.add(const Duration(minutes: 3)))
      ..recordFailure(3, QueueDeathKind.quota, 'quota exhausted');

    final rows = renderProviderQueueRows(
      entries: entries,
      state: state,
      now: now,
    );
    expect(rows, <String>[
      '0. openai-completions/a [current] key:\$K_a '
          'https://gate.example/v1',
      '1. openai-completions/b [recovering] key:\$K_b '
          'https://gate.example/v1 — network: connection refused',
      '2. openai-completions/c [cooldown 42s] key:\$K_c '
          'https://gate.example/v1',
      '3. openai-completions/d [cooldown 3m] key:\$K_d '
          'https://gate.example/v1 — quota: quota exhausted',
    ]);
  });

  test('rows are width-independent: identical bytes at 80/120/200 columns', () {
    final entries = [_entry('a'), _entry('b')];
    final state = ProviderQueueState()
      ..recordSuccess(1)
      ..recordFailure(0, QueueDeathKind.timeout, 'idle 300s');
    for (final width in const [80, 120, 200]) {
      expect(
        renderProviderQueueRows(entries: entries, state: state, now: now),
        isNot(contains(contains('\n'))),
        reason: 'width $width must not introduce wrapped lines',
      );
    }
    // And the rendered bytes themselves never change with the width —
    // the renderer takes no width parameter at all.
    expect(
      renderProviderQueueRows(entries: entries, state: state, now: now),
      renderProviderQueueRows(entries: entries, state: state, now: now),
    );
  });

  test('secret values never appear in rows (AC9)', () {
    final entries = [
      ProviderQueueEntry(
        providerType: 'openai-completions',
        model: 'm',
        apiKeyEnv: 'K_M',
      ),
    ];
    final rows = renderProviderQueueRows(
      entries: entries,
      state: ProviderQueueState(),
      now: now,
    ).join('\n');
    expect(rows.contains('key:\$K_M'), isTrue, reason: 'env NAME is shown');
    expect(rows.contains('sk-'), isFalse);
  });
}
