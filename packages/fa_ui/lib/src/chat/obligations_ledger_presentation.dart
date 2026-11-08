// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import '../theme/fa2_tokens.dart';
import 'chat_strings.dart';
import 'fa_chat_service.dart';

/// One unique visible obligation; identical engine entries share [repeats].
final class FaObligationEntry {
  const FaObligationEntry({
    required this.status,
    required this.kind,
    required this.text,
    this.repeats = 1,
  });

  final String status;
  final String kind;
  final String text;
  final int repeats;
}

/// Display projection of the engine-maintained obligations notice.
final class FaObligationsLedger {
  const FaObligationsLedger({
    required this.entries,
    required this.openTotal,
    required this.surplus,
  });

  /// Unique entries, newest first.
  final List<FaObligationEntry> entries;
  final int openTotal;
  final int surplus;
}

final _entryStart = RegExp(r'- \[([^\]]+)\]\s+([a-z][a-z0-9-]*):\s*');
final _surplus = RegExp(r'… and (\d+) more open obligations');
final _surplusTail = RegExp(
  r'\s*… and \d+ more open obligations(?:\s*\([^)]*\))?\s*$',
);
final _technicalTail = RegExp(r'\s*\(id\s+[^)]+,\s*record\s+[^)]+\)\s*$');

/// Parses the current engine ledger envelope without exposing internal ids.
///
/// Unknown statuses and kinds are retained. Malformed/no-entry content returns
/// null so the caller can fall back to the ordinary system-notice text.
FaObligationsLedger? parseFaObligationsLedger(String content) {
  final text = faSystemNoticeText(content);
  if (!text.startsWith('obligations ledger')) return null;
  final starts = _entryStart.allMatches(text).toList(growable: false);
  if (starts.isEmpty) return null;
  final parsed = <FaObligationEntry>[];
  var openCount = 0;
  for (var i = 0; i < starts.length; i++) {
    final match = starts[i];
    final status = match.group(1)!.trim();
    final kind = match.group(2)!;
    final end = i + 1 < starts.length ? starts[i + 1].start : text.length;
    final task = text
        .substring(match.end, end)
        .replaceFirst(_surplusTail, '')
        .replaceFirst(_technicalTail, '')
        .trim();
    if (task.isEmpty) continue;
    parsed.add(FaObligationEntry(status: status, kind: kind, text: task));
    if (status == 'open') openCount++;
  }
  if (parsed.isEmpty) return null;

  final surplus = int.tryParse(_surplus.firstMatch(text)?.group(1) ?? '') ?? 0;
  final grouped = <String, FaObligationEntry>{};
  for (final entry in parsed.reversed) {
    final key = '${entry.status}\u0000${entry.kind}\u0000${entry.text}';
    final previous = grouped[key];
    grouped[key] = previous == null
        ? entry
        : FaObligationEntry(
            status: entry.status,
            kind: entry.kind,
            text: entry.text,
            repeats: previous.repeats + 1,
          );
  }
  return FaObligationsLedger(
    entries: List.unmodifiable(grouped.values),
    openTotal: openCount + surplus,
    surplus: surplus,
  );
}

/// Structured ledger body: latest task collapsed, unique task rows expanded.
class ObligationsLedgerView extends StatelessWidget {
  const ObligationsLedgerView({
    super.key,
    required this.ledger,
    required this.expanded,
  });

  final FaObligationsLedger ledger;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final strings = FaChatStrings.of(context);
    final bodyStyle = TextStyle(color: tokens.ink2, fontSize: 12, height: 1.35);
    if (!expanded) {
      return Text(
        ledger.entries.first.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: bodyStyle,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < ledger.entries.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
            child: _ObligationRow(
              entry: ledger.entries[i],
              bodyStyle: bodyStyle,
            ),
          ),
        if (ledger.surplus > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              strings.chatObligationsSurplus(ledger.surplus),
              style: TextStyle(
                color: tokens.ink3,
                fontSize: 11.5,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}

class _ObligationRow extends StatelessWidget {
  const _ObligationRow({required this.entry, required this.bodyStyle});

  final FaObligationEntry entry;
  final TextStyle bodyStyle;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final strings = FaChatStrings.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            entry.kind == 'pending-wait'
                ? Icons.schedule_outlined
                : Icons.radio_button_unchecked,
            size: 14,
            color: tokens.ink3,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    strings.chatObligationKind(entry.kind),
                    style: TextStyle(
                      color: tokens.ink3,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (entry.repeats > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '×${entry.repeats}',
                      style: TextStyle(
                        color: tokens.ink3,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 3),
              Text(entry.text, style: bodyStyle),
            ],
          ),
        ),
      ],
    );
  }
}
