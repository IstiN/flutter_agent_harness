// Micro-bench: per-delta cost of ProviderStreamState.snapshot() while a
// long reasoning stream accumulates (issue #43 upstream path).
import 'dart:async';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart';
import 'dart:io';

void main(List<String> args) async {
  const model = Model(
    api: 'openai-completions',
    provider: 'openai',
    id: 'bench',
    baseUrl: 'http://localhost',
    contextWindow: 160000,
    maxTokens: 8192,
  );
  const deltas = 4000;
  const deltaLen = 60; // ~60 chars per thinking delta
  final state = ProviderStreamState(model);
  final block = ThinkingStreamingBlock();
  state.blocks.add(block);

  var snapshotUs = 0;
  final jitter = <int>[];
  var last = DateTime.now().microsecondsSinceEpoch;
  final ticker = Timer.periodic(const Duration(milliseconds: 4), (_) {
    final now = DateTime.now().microsecondsSinceEpoch;
    jitter.add(now - last);
    last = now;
  });

  final sw = Stopwatch()..start();
  var maxDeltaUs = 0;
  var totalUs = 0;
  for (var i = 0; i < deltas; i++) {
    final dsw = Stopwatch()..start();
    block.thinking.write('a' * deltaLen);
    final msg = state.snapshot();
    dsw.stop();
    final us = dsw.elapsedMicroseconds;
    totalUs += us;
    if (us > maxDeltaUs) maxDeltaUs = us;
    snapshotUs += us;
    if (msg.content.isEmpty) break;
    // Realistic pacing: a delta every ~5ms (~200 tokens/s).
    if (i % 20 == 0)
      await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  sw.stop();
  ticker.cancel();

  final js = List<int>.of(jitter)..sort();
  final len = block.thinking.length;
  stdout.writeln('accumulated=$len chars in $deltas deltas');
  stdout.writeln(
    'total wall=${sw.elapsedMilliseconds}ms '
    'snapshot-total=${totalUs}ms worst-single-delta=${maxDeltaUs}us',
  );
  stdout.writeln('avg snapshot=${totalUs / deltas}us/delta');
  if (js.isNotEmpty) {
    stdout.writeln(
      'ticker jitter ms: p50=${js[js.length ~/ 2] / 1000} '
      'p95=${js[(js.length * 0.95).floor()] / 1000} '
      'max=${js.last / 1000}',
    );
  }
  exit(0);
}
