import 'redaction_pipeline.dart';

/// The outcome of a `/redact [args]` line: the lines to print and the
/// pipeline config to install ([newConfig] null = keep the current one).
///
/// Pure so both the CLI command and its tests render the same output.
class RedactCommandOutcome {
  const RedactCommandOutcome(this.lines, {this.newConfig});

  /// Lines to print to the user.
  final List<String> lines;

  /// The config to install on the pipeline (live toggle), if any.
  final RedactionConfig? newConfig;
}

const _usage = 'usage: /redact [on|off|block on|block off|stats|layers]';
const _disabled =
    'redaction disabled (set `redact: { enabled: true }` in the config '
    'to turn it on)';

/// Handles a `/redact` command line against [pipeline] (null = redaction
/// disabled by config).
RedactCommandOutcome handleRedactCommand(
  RedactionPipeline? pipeline,
  List<String> args,
) {
  if (pipeline == null) return RedactCommandOutcome([_disabled]);
  final sub = args.isEmpty ? '' : args.first.toLowerCase();
  return switch (sub) {
    '' => RedactCommandOutcome(['${_statusLine(pipeline)}\n$_usage']),
    'on' || 'off' => _toggleEnabled(pipeline, sub == 'on'),
    'block' => _toggleBlock(pipeline, args),
    'stats' => RedactCommandOutcome(_statsLines(pipeline)),
    'layers' => RedactCommandOutcome(_layerLines(pipeline)),
    _ => RedactCommandOutcome([_usage]),
  };
}

RedactCommandOutcome _toggleEnabled(RedactionPipeline pipeline, bool on) {
  return RedactCommandOutcome([
    'redaction ${on ? 'enabled' : 'disabled'}',
  ], newConfig: pipeline.config.copyWith(enabled: on));
}

RedactCommandOutcome _toggleBlock(
  RedactionPipeline pipeline,
  List<String> args,
) {
  final value = args.length > 1 ? args[1].toLowerCase() : '';
  if (value != 'on' && value != 'off') {
    return RedactCommandOutcome(['usage: /redact block on|off']);
  }
  return RedactCommandOutcome([
    'blockMode ${value == 'on' ? 'on' : 'off'}',
  ], newConfig: pipeline.config.copyWith(blockMode: value == 'on'));
}

String _statusLine(RedactionPipeline pipeline) =>
    'redaction: ${pipeline.config.enabled ? 'on' : 'off'}, '
    'blockMode: ${pipeline.config.blockMode ? 'on' : 'off'}, '
    '${pipeline.registeredSecrets.length} registered secret(s), '
    '${pipeline.stats.total} match(es) this session';

List<String> _statsLines(RedactionPipeline pipeline) {
  final stats = pipeline.stats;
  final lines = <String>['redaction stats: ${stats.total} match(es)'];
  lines.addAll(_sortedCounts(stats.byLayer, prefix: '  '));
  lines.addAll(_sortedCounts(stats.byTool, prefix: '  via '));
  return lines;
}

List<String> _sortedCounts(Map<String, int> counts, {required String prefix}) {
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [for (final entry in entries) '$prefix${entry.key}: ${entry.value}'];
}

List<String> _layerLines(RedactionPipeline pipeline) => [
  for (final layer in RedactionLayer.values)
    '  ${layer.name}: '
        '${pipeline.config.isLayerEnabled(layer) ? 'on' : 'off'}',
];
