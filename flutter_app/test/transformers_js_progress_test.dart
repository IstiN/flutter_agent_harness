import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// Host tests for the smooth download-progress aggregation
/// ([TransformersJsProgressAggregator]): per-file events weighted by
/// expected bytes into a monotonic overall fraction with a `%` + file-name
/// status line — the fix for the per-file resetting ("flickering") bar.
void main() {
  const files = {
    'config.json': 100,
    'onnx/small.onnx': 900,
    'onnx/big.onnx_data': 9000,
  };

  TransformersJsProgressAggregator aggregator() =>
      TransformersJsProgressAggregator(files);

  TransformersJsDownloadEvent event(
    String status, {
    String? file,
    int? loaded,
    int? total,
  }) => (status: status, file: file, loaded: loaded, total: total);

  group('TransformersJsProgressAggregator', () {
    test('weights files by expected bytes, not by count', () {
      final agg = aggregator();
      agg.update(event('initiate', file: 'onnx/small.onnx'));
      final smallDone = agg.update(event('done', file: 'onnx/small.onnx'));
      // 900 of 10000 total bytes — completing the small file alone must
      // not fill the bar.
      expect(smallDone.fraction, closeTo(0.09, 1e-9));

      final bigHalf = agg.update(
        event('progress', file: 'onnx/big.onnx_data', loaded: 4500),
      );
      expect(bigHalf.fraction, closeTo(0.09 + 0.45, 1e-9));
    });

    test('done marks the file complete regardless of reported loaded', () {
      final agg = aggregator();
      agg.update(event('progress', file: 'onnx/big.onnx_data', loaded: 120));
      final done = agg.update(event('done', file: 'onnx/big.onnx_data'));
      expect(done.fraction, closeTo(0.9, 1e-9));
    });

    test('the fraction is monotonic: per-file restarts never move it '
        'backwards', () {
      final agg = aggregator();
      agg.update(event('progress', file: 'onnx/big.onnx_data', loaded: 6000));
      final peak = agg.update(
        event('progress', file: 'onnx/big.onnx_data', loaded: 8000),
      );
      expect(peak.fraction, closeTo(0.8, 1e-9));

      // The file reports a lower loaded count again (restarted chunk
      // counting): the bar stays at the peak.
      final restarted = agg.update(
        event('progress', file: 'onnx/big.onnx_data', loaded: 100),
      );
      expect(restarted.fraction, peak.fraction);

      // A NEW file starting at zero must not pull the bar down either.
      final other = agg.update(event('initiate', file: 'onnx/small.onnx'));
      expect(other.fraction, peak.fraction);
    });

    test('loaded counts clamp at the expected size', () {
      final agg = aggregator();
      final over = agg.update(
        event('progress', file: 'onnx/big.onnx_data', loaded: 99999999),
      );
      expect(over.fraction, closeTo(0.9, 1e-9));
    });

    test('ready reports 100% and the ready status line', () {
      final agg = aggregator();
      agg.update(event('progress', file: 'onnx/big.onnx_data', loaded: 10));
      final ready = agg.update(event('ready'));
      expect(ready.fraction, 1.0);
      expect(ready.text, 'Model ready');
    });

    test('the status line carries the current file name and the percent', () {
      final agg = aggregator();
      final report = agg.update(
        event('progress', file: 'onnx/big.onnx_data', loaded: 4200),
      );
      expect(report.text, 'Downloading big.onnx_data — 42%');
    });

    test('events for files outside the expected set never move the bar', () {
      final agg = aggregator();
      final before = agg.update(
        event('progress', file: 'onnx/big.onnx_data', loaded: 1000),
      );
      final after = agg.update(
        event('progress', file: 'onnx/audio_encoder.onnx_data', loaded: 5),
      );
      expect(after.fraction, before.fraction);
      // ...but the status line still follows the activity.
      expect(after.text, contains('audio_encoder.onnx_data'));
    });

    test('prepare keeps a zero bar with the preparing status line', () {
      final agg = aggregator();
      final report = agg.update(event('prepare'));
      expect(report.fraction, 0.0);
      expect(report.text, 'Preparing model download…');
    });

    test('the preset download sizes aggregate to the advertised ~3.4 GB', () {
      final preset = transformersJsModelPresets.firstWhere(
        (p) => p.id == 'onnx-community/gemma-4-E2B-it-ONNX',
      );
      final total = preset.downloadSizes.values.fold<int>(
        0,
        (sum, n) => sum + n,
      );
      // 3.40 GB ± slack for the small config/tokenizer files.
      expect(total, greaterThan(3400000000));
      expect(total, lessThan(3500000000));
    });
  });
}
