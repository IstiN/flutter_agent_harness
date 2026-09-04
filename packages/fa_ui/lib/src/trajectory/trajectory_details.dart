// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'trajectory_details_tabs.dart';
import 'trajectory_strings.dart';

/// Session-scoped last-open tab per selection, keyed by record id (or
/// `request\0seq` for request sheets) so reopening a record restores the
/// most recent tab that is still available.
// ponytail: session-scoped map, never cleared except in tests; records are
// bounded by what the host opens.
final Map<String, String> _lastTabBySelection = {};

/// Clears the tab-history map (test seam).
@visibleForTesting
void resetTrajectoryTabHistory() => _lastTabBySelection.clear();

/// Opens the details sheet for one ledger [record]: a modal bottom sheet
/// (max height 85% of the screen, drag to dismiss) whose tabs follow the
/// record kind — see [trajectoryDetailTabs].
Future<void> showTrajectoryDetails(
  BuildContext context, {
  required TrajectoryRecord record,
  TrajectorySnapshot? snapshot,
}) {
  final strings = TrajectoryStrings.of(context);
  return _showTabbedSheet(
    context,
    historyKey: record.recordId,
    title: strings.detailsEvent,
    tabs: trajectoryDetailTabs(record, snapshot, strings),
  );
}

/// Opens the details sheet for one captured provider [request]: tabs are
/// Summary, Usage, Timing; the title carries the session request number
/// (`Request #N · Compaction` for compaction requests).
Future<void> showTrajectoryRequestDetails(
  BuildContext context, {
  required TrajectoryRequestNumber request,
  TrajectorySnapshot? snapshot,
}) {
  final strings = TrajectoryStrings.of(context);
  return _showTabbedSheet(
    context,
    historyKey: 'request\u0000${request.seq}',
    title: request.purpose == TrajectoryRequestPurpose.compaction
        ? strings.requestLabelCompaction(request.seq)
        : strings.requestLabel(request.seq),
    tabs: trajectoryRequestDetailTabs(request, snapshot, strings),
  );
}

Future<void> _showTabbedSheet(
  BuildContext context, {
  required String historyKey,
  required String title,
  required List<TrajectoryDetailsTab> tabs,
}) {
  final stored = _lastTabBySelection[historyKey];
  final initialIndex = tabs.indexWhere((tab) => tab.id == stored);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    ),
    builder: (sheetContext) => DefaultTabController(
      length: tabs.length,
      initialIndex: initialIndex < 0 ? 0 : initialIndex,
      child: _DetailsSheet(historyKey: historyKey, title: title, tabs: tabs),
    ),
  );
}

class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({
    required this.historyKey,
    required this.title,
    required this.tabs,
  });

  final String historyKey;
  final String title;
  final List<TrajectoryDetailsTab> tabs;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: Theme.of(context).dividerColor,
          onTap: (index) => _lastTabBySelection[historyKey] = tabs[index].id,
          tabs: [for (final tab in tabs) Tab(text: tab.label)],
        ),
        Flexible(
          child: TabBarView(
            children: [for (final tab in tabs) Builder(builder: tab.build)],
          ),
        ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom),
      ],
    );
  }
}
