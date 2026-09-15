// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The continuation notice's recoverables line (issue #438 AC4).
///
/// After the over-window guard's post-run compaction, the continuation
/// notice names what the fold hid — record kinds + turn span per
/// hidden_range — and points at `compact_expand` so the continuation turn
/// can pull specific records back. E4: the enumeration caps at
/// [maxSpans] (the first and the last spans win); the full list stays in
/// the session file.
library;

import '../../session/session_record.dart';
import 'expand_tool.dart' show compactExpandToolName;
import 'projection.dart' show RecordSeqIndex, markerKindFor;

/// Builds the recoverables line for the session's hidden ranges, or the
/// empty string when nothing is hidden (classic compaction leaves no
/// hidden ranges — the notice then stays as it was).
String hiddenRecoverablesSummary(
  List<SessionRecord> entries, {
  int maxSpans = 3,
}) {
  final seqs = RecordSeqIndex(entries);
  final spans = <String>[];
  for (final hidden in entries.whereType<HiddenRangeRecord>()) {
    final nums = [for (final id in hidden.recordIds) ?seqs.seqOf(id)]..sort();
    if (nums.isEmpty) continue;
    final counts = <String, int>{};
    for (final id in hidden.recordIds) {
      final record = seqs.recordAt(seqs.seqOf(id)!);
      if (record == null) continue;
      final kind = markerKindFor(record);
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
    final kinds = [
      for (final e in counts.entries) '${e.key}×${e.value}',
    ].join(' ');
    spans.add('records ${nums.first}–${nums.last} ($kinds)');
  }
  if (spans.isEmpty) return '';
  final shown = spans.length <= maxSpans
      ? spans
      : [...spans.take(maxSpans - 1), spans.last];
  final more = spans.length - shown.length;
  final tail = more > 0
      ? ' · +$more more — the full list is in the session file'
      : '';
  return 'Hidden by compaction (recoverable via $compactExpandToolName): '
      '${shown.join(' · ')}$tail';
}
