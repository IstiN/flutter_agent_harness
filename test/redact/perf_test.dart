import 'dart:math';

import 'package:flutter_agent_harness/src/redact/redaction_pipeline.dart';
import 'package:test/test.dart';

/// 100 KB of ordinary prose without any secret-shaped content.
String buildPlain(int size) {
  const words =
      'the quick brown fox jumps over a lazy dog while reviewing logs '
      'and writing summaries of the deployed release notes today ';
  final buf = StringBuffer();
  while (buf.length < size) {
    buf.write(words);
  }
  return buf.toString().substring(0, size);
}

/// [count] random base64-ish tokens (40 chars) spread over ~100 KB.
String buildWithTokens(int size, int count) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final rng = Random(42);
  final buf = StringBuffer();
  for (var i = 0; i < count; i++) {
    buf.write('tok ');
    for (var c = 0; c < 40; c++) {
      buf.write(alphabet[rng.nextInt(alphabet.length)]);
    }
    buf.write(' end of line item number $i ');
  }
  while (buf.length < size) {
    buf.write('filler prose without secrets at all ');
  }
  return buf.toString().substring(0, size);
}

void main() {
  final pipeline = RedactionPipeline(registeredSecrets: const []);

  test('100 KB clean text redacts in < 100ms (generous CI bound)', () {
    // gh-1357 class (run 37550915894, core shard 1/4): the arm64 runner
    // measured EXACTLY 50ms against the old `lessThan(50)` bound — the
    // clean-text pass sits at the bound on that hardware, so any shard
    // load tips it red. Headroom, not a pipeline regression: the same
    // run's 1000-token test passed with 3x margin, and the gate still
    // catches the order-of-magnitude regression it exists for.
    final plain = buildPlain(100 * 1024);
    // JIT warm-up, not counted.
    pipeline.redact(plain.substring(0, 512));
    final sw = Stopwatch()..start();
    pipeline.redact(plain);
    sw.stop();
    expect(
      sw.elapsedMilliseconds,
      lessThan(100),
      reason: 'took ${sw.elapsedMilliseconds}ms',
    );
  });

  test('100 KB + 1000 base64 tokens redacts in < 150ms', () {
    final loaded = buildWithTokens(100 * 1024, 1000);
    pipeline.redact(loaded.substring(0, 512));
    final sw = Stopwatch()..start();
    final out = pipeline.redact(loaded);
    sw.stop();
    expect(out.contains('[REDACTED:High Entropy String]'), isTrue);
    expect(
      sw.elapsedMilliseconds,
      lessThan(150),
      reason: 'took ${sw.elapsedMilliseconds}ms',
    );
  });
}
