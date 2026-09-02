import 'package:flutter_agent_harness/src/trajectory/formatters.dart';
import 'package:test/test.dart';

void main() {
  group('formatDurationMillis', () {
    test('returns the unknown label for null', () {
      expect(formatDurationMillis(null), '—');
    });

    test('clamps negative durations to zero', () {
      expect(formatDurationMillis(-250), '0');
    });

    test('separates thousands with commas', () {
      expect(formatDurationMillis(0), '0');
      expect(formatDurationMillis(999), '999');
      expect(formatDurationMillis(1000), '1,000');
      expect(formatDurationMillis(1234567), '1,234,567');
    });
  });

  group('formatElapsedSeconds', () {
    test('returns the unknown label for null', () {
      expect(formatElapsedSeconds(null), '—');
    });

    test('rounds to whole milliseconds', () {
      expect(formatElapsedSeconds(1.5), '1,500');
      expect(formatElapsedSeconds(0.2504), '250');
      expect(formatElapsedSeconds(18.002), '18,002');
    });

    test('clamps negative elapsed time to zero', () {
      expect(formatElapsedSeconds(-0.5), '0');
    });
  });

  group('formatTokens', () {
    test('returns the unknown label for null', () {
      expect(formatTokens(null), '—');
    });

    test('keeps small counts verbatim', () {
      expect(formatTokens(0), '0');
      expect(formatTokens(999), '999');
    });

    test('compacts thousands with one decimal', () {
      expect(formatTokens(1000), '1k');
      expect(formatTokens(12300), '12.3k');
    });

    test('compacts millions with one decimal', () {
      expect(formatTokens(1200000), '1.2M');
      expect(formatTokens(2000000), '2M');
    });
  });
}
