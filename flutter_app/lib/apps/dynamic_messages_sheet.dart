// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/dynamic_widget_tile.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:flutter/material.dart';

/// The top-bar ✦ affordance (issue #102 AC5): opens the session's
/// dynamic-messages list. Hides itself while the session has none.
class DynamicMessagesButton extends StatelessWidget {
  const DynamicMessagesButton({
    super.key,
    required this.service,
    required this.onSaveAsApp,
  });

  /// The active session's agent service ([AgentService.dynamicMessages]
  /// is the list source; [AgentService.scrollToMessageHandler] the jump
  /// executor installed by the chat screen).
  final AgentService service;

  final Future<void> Function(DynamicMessageDefinition definition) onSaveAsApp;

  @override
  Widget build(BuildContext context) {
    final dynamicMessages = service.dynamicMessages;
    return ListenableBuilder(
      listenable: dynamicMessages,
      builder: (context, _) {
        if (dynamicMessages.widgets.isEmpty) return const SizedBox.shrink();
        return IconButton(
          tooltip: context.l10n.dynamicMessagesButtonTooltip,
          onPressed: () => unawaited(
            showDynamicMessagesSheet(
              context,
              service: service,
              onSaveAsApp: onSaveAsApp,
            ),
          ),
          icon: Badge.count(
            count: dynamicMessages.liveCount,
            isLabelVisible: dynamicMessages.liveCount > 0,
            child: const Text('✦'),
          ),
        );
      },
    );
  }
}

/// Opens the session's dynamic-messages list sheet.
Future<void> showDynamicMessagesSheet(
  BuildContext context, {
  required AgentService service,
  required Future<void> Function(DynamicMessageDefinition definition)
  onSaveAsApp,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        DynamicMessagesSheet(service: service, onSaveAsApp: onSaveAsApp),
  );
}

/// The session's dynamic messages: title, timestamp, event count, live
/// badge; tap jumps to the widget's transcript position, the archive
/// action graduates it into an installed app.
class DynamicMessagesSheet extends StatelessWidget {
  const DynamicMessagesSheet({
    super.key,
    required this.service,
    required this.onSaveAsApp,
  });

  final AgentService service;
  final Future<void> Function(DynamicMessageDefinition definition) onSaveAsApp;

  @override
  Widget build(BuildContext context) {
    final dynamicMessages = service.dynamicMessages;
    final l10n = context.l10n;
    return SafeArea(
      child: ListenableBuilder(
        listenable: dynamicMessages,
        builder: (context, _) {
          final widgets = List.of(dynamicMessages.widgets);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Text(
                  l10n.dynamicMessagesSheetTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ListView.builder(
                shrinkWrap: true,
                itemCount: widgets.length,
                itemBuilder: (context, index) {
                  final definition = widgets[index];
                  final material = MaterialLocalizations.of(context);
                  final when =
                      '${material.formatMediumDate(definition.createdAt)} '
                      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(definition.createdAt))}';
                  return ListTile(
                    leading: Text(
                      '✦',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    title: Text(
                      definition.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '$when · ${l10n.dynamicMessagesEventCount(definition.eventCount)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (dynamicMessages.engineFor(definition.id) != null)
                          const DynamicLiveBadge(),
                        IconButton(
                          tooltip: l10n.dynamicTileSaveAsApp,
                          icon: const Icon(Icons.archive_outlined, size: 20),
                          onPressed: () {
                            Navigator.of(context).pop();
                            unawaited(onSaveAsApp(definition));
                          },
                        ),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      service.scrollToMessageHandler?.call(
                        'msg-${definition.markerIndex}',
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}
