// gh-2098 bench: fire points + compaction frequency of the auto-compact
// trigger policies on a RECORDED session's observed-usage curve.
//
//   dart bench/compaction_trigger_sim.dart <session.jsonl> \
//       [--window N]... [--scale X]
//
// Replays the recorded per-request observed context sizes
// (`usage.input + usage.cacheRead`, the gh-1742 anchor) as a sawtooth:
// each policy compacts when the context crosses its trigger line, the
// context then restarts at the policy's keepRecentTokens and continues
// riding the recorded per-request growth deltas (`--scale X` multiplies
// the deltas — a documented emulation of a large-window marathon riding
// the same per-request growth shape). Reports, per policy: the trigger
// line, where it first fired, and the total fire count over the curve.
//
// The policies: the gh-1742 legacy curve (`CompactionSettings.forWindow`
// — 6.25% headroom on the proportional band, i.e. a 0.9375 trigger) and
// the gh-2098 `compaction.triggerRatio` overrides 0.80 / 0.75.
//
// Pure dart:io + dart:convert; no package imports — standalone by
// design (a recorded session is a private artifact; the sim never
// ships inside the harness).
import 'dart:convert';
import 'dart:io';

const _policies = ['legacy(0.9375)', '0.80', '0.75'];
const _ratios = {'legacy(0.9375)': 15 / 16, '0.80': 0.80, '0.75': 0.75};

void main(List<String> args) {
  if (args.isEmpty || !File(args.first).existsSync()) {
    stderr.writeln(
      'usage: dart bench/compaction_trigger_sim.dart <session.jsonl> '
      '[--window N]... [--scale X]',
    );
    exit(2);
  }
  final windows = <int>[];
  var scale = 1.0;
  for (var i = 1; i < args.length - 1; i++) {
    if (args[i] == '--window') {
      windows.add(int.parse(args[i + 1]));
    } else if (args[i] == '--scale') {
      scale = double.parse(args[i + 1]);
    }
  }
  if (windows.isEmpty) windows.addAll([128000, 200000, 400000]);

  final observed = <int>[];
  for (final line in File(args.first).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    Object? record;
    try {
      record = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (record is! Map || record['type'] != 'message') continue;
    final message = record['message'];
    if (message is! Map) continue;
    final usage = message['usage'];
    if (usage is! Map) continue;
    final input = (usage['input'] as num?)?.toInt() ?? 0;
    final cacheRead = (usage['cacheRead'] as num?)?.toInt() ?? 0;
    final size = input + cacheRead;
    if (size > 0) observed.add(size);
  }
  if (observed.length < 2) {
    stderr.writeln('no usable usage observations in ${args.first}');
    exit(2);
  }
  final maxObserved = observed.reduce((a, b) => a > b ? a : b);
  stderr.writeln(
    'recorded curve: ${observed.length} requests, observed context '
    '${observed.first} → $maxObserved tokens'
    '${scale == 1 ? '' : ' (deltas scaled ×$scale)'}',
  );

  for (final window in windows) {
    // The legacy curve (CompactionSettings.forWindow): reserve =
    // min(65536, max(window ~/ 16, min(16384, max(1024, window ~/ 4)))),
    // degenerate guards included; keep = min(131072, max(window ~/ 8,
    // min(20000, max(2048, window ~/ 2)))), same guards. The ratio
    // policies keep the legacy keep curve (only the trigger line moves).
    final legacyReserve = _legacyReserve(window);
    final legacyKeep = _legacyKeep(window);

    stdout.writeln('');
    stdout.writeln(
      'window $window — legacy trigger ${window - legacyReserve} '
      '(${(_pct(window - legacyReserve, window))}%), keep $legacyKeep',
    );
    for (final policy in _policies) {
      final trigger = policy == 'legacy(0.9375)'
          ? window - legacyReserve
          : (window * _ratios[policy]!).floor();
      var context = observed.first;
      var fires = 0;
      int? firstFire;
      if (context > trigger) {
        fires++;
        firstFire = context;
        context = legacyKeep;
      }
      var previous = observed.first;
      for (final size in observed.skip(1)) {
        final delta = ((size - previous) * scale).round();
        previous = size;
        context += delta;
        if (context > trigger) {
          fires++;
          firstFire ??= context;
          context = legacyKeep;
        }
      }
      stdout.writeln(
        '  ${policy.padRight(15)} trigger $trigger '
        '(${_pct(trigger, window)}%) — first fire: '
        '${firstFire == null ? 'never over the curve' : '${_pct(firstFire, window)}% of the window'}'
        ', fires over the curve: $fires',
      );
    }
  }
}

String _pct(int part, int whole) => (100 * part / whole).toStringAsFixed(2);

int _legacyReserve(int window) {
  var reserve = window ~/ 16;
  final flat = (window ~/ 4).clamp(1024, 16384);
  if (reserve < flat) reserve = flat;
  if (reserve > 65536) reserve = 65536;
  if (reserve >= window ~/ 2) {
    final relaxed = window ~/ 4;
    reserve = relaxed >= 128 ? relaxed : 128;
  }
  return reserve;
}

int _legacyKeep(int window) {
  var keep = window ~/ 8;
  final flatKeep = (window ~/ 2).clamp(2048, 20000);
  if (keep < flatKeep) keep = flatKeep;
  if (keep > 131072) keep = 131072;
  if (keep >= window) {
    final relaxed = window ~/ 2;
    keep = relaxed >= 256 ? relaxed : 256;
  }
  return keep;
}
