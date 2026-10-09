/// The `session_search` tool (issue #1380, capability A2): archive-scale
/// recall over the WHOLE session file — keyword/regex search across every
/// record, hidden and checkpointed regions included, plus `mode: map`, the
/// structure readout (record-kind counts, hidden/compacted totals,
/// checkpoint tree with nesting depth) the agent otherwise improvises with
/// ad-hoc python over the JSONL.
///
/// Results are pointers — id, kind, timestamp, clipped preview — never
/// full content; the agent `compact_expand`s what matters, so the
/// per-turn expand budget stays the only content budget. The scan itself
/// is read-only, streamed, result-capped and time-budgeted (E4/E5); an
/// invalid query is a structured one-line error, never a hang.
///
/// The search runs through the host's [SessionSearchCallback] (the CLI's
/// streamed scan over the live session repo); a null callback (a host
/// without session-file access) yields the same graceful cannot-execute
/// result as `ask`/`request_secret`/`obligation_mark_done`.
library;

import '../agent/agent_tool.dart';
import '../agent/agent_loop.dart';
import '../approval/approval.dart';
import '../session/session_search.dart';

/// Runs one archive search for the tool. The host resolves the live
/// session per call (hosts switch sessions); returns the outcome the
/// tool formats.
typedef SessionSearchCallback =
    Future<SessionSearchOutcome> Function(SessionSearchQuery query);

/// Renders [outcome] as the tool's text result (search mode): one
/// pointer line per hit, an honest continuation footer when the scan
/// stopped early.
String formatSessionSearchOutcome(SessionSearchOutcome outcome) {
  if (outcome.map != null) return _formatArchiveMap(outcome);
  final scope = 'the session archive';
  if (outcome.hits.isEmpty) {
    return 'no records match (examined ${outcome.recordsExamined} of '
        '${outcome.recordsTotal} records)';
  }
  final lines = <String>[
    '${outcome.hits.length} hit(s) in $scope '
        '(examined ${outcome.recordsExamined} of ${outcome.recordsTotal} '
        'records):',
    for (final hit in outcome.hits)
      '- ${hit.id} [${hit.kind}] ${hit.timestamp.toIso8601String()}: '
          '${hit.preview}',
  ];
  if (outcome.truncated) {
    final reason = outcome.truncationReason.isEmpty
        ? 'scan stopped early'
        : outcome.truncationReason;
    final continuation = outcome.nextContinuation;
    lines.add(
      continuation == null
          ? 'more records may remain ($reason) — narrow with kinds/before/'
              'after and search again'
          : 'more records remain ($reason) — continue with '
              '{"continuation": $continuation}',
    );
  }
  lines.add(
    'expand what matters with compact_expand {target: <id>} — previews '
    'are pointers, not content',
  );
  return lines.join('\n');
}

String _formatArchiveMap(SessionSearchOutcome outcome) {
  final map = outcome.map!;
  final counts = map.kindCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final lines = <String>[
    'session map: ${map.recordCount} records',
    'counts: ${counts.isEmpty ? '(none)' : [for (final e in counts) '${e.key} ${e.value}'].join(', ')}',
    'hidden: ${map.hiddenRangeCount} hidden_range record(s) covering '
        '${map.hiddenRecordIdCount} record id(s)',
  ];
  if (map.checkpoints.isEmpty) {
    lines.add('checkpoints: none');
  } else {
    lines.add(
      'checkpoints: ${map.checkpoints.length} '
      '(max nesting depth ${map.maxCheckpointDepth})',
    );
    for (final checkpoint in map.checkpoints) {
      lines.add(
        '- ${checkpoint.id} covers ${checkpoint.coversCount} record(s) '
        '(${checkpoint.firstRecordId} → ${checkpoint.lastRecordId}) '
        'depth ${checkpoint.depth}',
      );
    }
  }
  lines.add(
    'active branch: ${map.branchRecordCount} record(s)'
    '${map.leafId == null ? '' : ', leaf ${map.leafId}'}',
  );
  if (outcome.truncated) {
    lines.add(
      'counts cover the records examined before the scan stopped '
      '(${outcome.truncationReason.isEmpty ? 'time budget' : outcome.truncationReason})',
    );
  }
  return lines.join('\n');
}

/// Creates the `session_search` tool bound to [search].
AgentTool sessionSearchTool({SessionSearchCallback? search}) {
  return AgentTool(
    name: 'session_search',
    label: 'session_search',
    tier: ApprovalTier.read,
    description:
        'Search the WHOLE session archive (every past turn — hidden, '
        'compacted and checkpointed regions included), not just the '
        'current context. Use it whenever the user references a past '
        'decision, rule, task or artifact ("remember when…", "the rules '
        'we made") BEFORE answering from assumption. Returns pointers '
        '(id, kind, timestamp, preview), never full content — pull the '
        'record back with compact_expand. With mode: "map" it reports '
        'the archive structure instead: record-kind counts, hidden/'
        'checkpoint totals, checkpoint tree with nesting depth.',
    parameters: const {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description':
              'The phrase to search for (keyword, or a regular '
              'expression with regex: true). Required in search mode.',
        },
        'scope': {
          'type': 'string',
          'enum': ['branch', 'tree'],
          'description':
              'branch (default) searches the active branch only; tree '
              'spans forks and abandoned branches too.',
        },
        'mode': {
          'type': 'string',
          'enum': ['search', 'map'],
          'description':
              'search (default) finds records; map reports the archive '
              'structure (counts, hidden totals, checkpoint tree).',
        },
        'kinds': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Only these record types (message, compaction, '
              'compact_checkpoint, custom, …). Empty keeps every kind.',
        },
        'before': {
          'type': 'string',
          'description': 'Only records older than this ISO-8601 instant.',
        },
        'after': {
          'type': 'string',
          'description': 'Only records newer than this ISO-8601 instant.',
        },
        'regex': {
          'type': 'boolean',
          'description': 'Match query as a case-insensitive regular '
              'expression (default: literal keyword).',
        },
        'maxHits': {
          'type': 'integer',
          'description':
              'Cap on returned pointers (default 40, max 200). A capped '
              'scan returns a continuation token.',
        },
        'continuation': {
          'type': 'integer',
          'description':
              'The token a previous capped call returned — resumes the '
              'scan after the records already examined.',
        },
      },
    },
    execute: (arguments, cancelToken, onUpdate) async {
      cancelToken?.throwIfCancelled();
      final runner = search;
      if (runner == null) {
        return ToolExecutionResult.text(
          'This host has no session file to search.',
        );
      }
      final SessionSearchQuery query;
      try {
        query = SessionSearchQuery.fromArgs(arguments);
      } on FormatException catch (error) {
        return ToolExecutionResult.text('error: ${error.message}');
      }
      final outcome = await runner(query);
      return ToolExecutionResult.text(formatSessionSearchOutcome(outcome));
    },
  );
}
