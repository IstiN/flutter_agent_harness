// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import '../theme/fa2_tokens.dart';
import 'chat_strings.dart';
import 'fa_chat_service.dart';
import 'obligations_ledger_presentation.dart';

/// Compact, neutral presentation for consecutive agent-facing system notices.
///
/// Collapsed, only the newest status is visible; expanding reveals every
/// notice without its XML envelope (ledgers use a structured task view).
/// This is a display grouping only — the
/// session records and their positional message ids remain unchanged.
class SystemNoticeTile extends StatefulWidget {
  const SystemNoticeTile({super.key, required this.notices});

  final List<String> notices;

  @override
  State<SystemNoticeTile> createState() => _SystemNoticeTileState();
}

class _SystemNoticeTileState extends State<SystemNoticeTile> {
  bool _expanded = false;

  Widget _expandedNotice(String notice, FaDesignTokens tokens) {
    final ledger = parseFaObligationsLedger(notice);
    if (ledger != null) {
      return ObligationsLedgerView(ledger: ledger, expanded: true);
    }
    return Text(
      faSystemNoticeText(notice),
      style: TextStyle(color: tokens.ink2, fontSize: 12, height: 1.35),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final strings = FaChatStrings.of(context);
    final notices = widget.notices;
    final latest = faSystemNoticeText(notices.last);
    final latestLedger = parseFaObligationsLedger(notices.last);
    final singleLedger = notices.length == 1 ? latestLedger : null;
    final waiting = latest.contains('Waiting heartbeat:');
    return Container(
      key: const ValueKey('faSystemNoticeGroup'),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tokens.surface1.withValues(alpha: .88),
        border: Border.all(color: tokens.hairline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      singleLedger != null
                          ? Icons.fact_check_outlined
                          : waiting
                          ? Icons.schedule_outlined
                          : Icons.notifications_none_outlined,
                      size: 15,
                      color: tokens.ink2,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        singleLedger != null
                            ? strings.chatOpenObligations(
                                singleLedger.openTotal,
                              )
                            : strings.chatSystemNotices(notices.length),
                        style: TextStyle(
                          color: tokens.ink2,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Tooltip(
                      message: _expanded
                          ? strings.chatShowLess
                          : strings.chatShowMore,
                      child: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 17,
                        color: tokens.ink3,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                if (_expanded)
                  SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < notices.length; i++)
                          Padding(
                            padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                            child: _expandedNotice(notices[i], tokens),
                          ),
                      ],
                    ),
                  )
                else if (latestLedger != null)
                  ObligationsLedgerView(ledger: latestLedger, expanded: false)
                else
                  Text(
                    latest,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tokens.ink2,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
