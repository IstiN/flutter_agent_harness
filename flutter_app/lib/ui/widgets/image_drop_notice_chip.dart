// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The chat chip for the aggregated image-cap drop notice (issue #1889
/// R5): ONE docked banner per meaningful drop-situation change — the
/// flooding per-image lines stay in the debug log ([AppLog]). Data-driven
/// (the notice comes from the shared core latch), so widget and golden
/// tests need no live [AgentService].
class ImageDropNoticeChip extends StatelessWidget {
  const ImageDropNoticeChip({
    super.key,
    required this.notice,
    this.onTap,
    this.onDismiss,
  });

  /// The latched notice to render.
  final ImageDropNoticeView notice;

  /// Opens the details panel (the `/images` equivalent).
  final VoidCallback? onTap;

  /// Clears the chip.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: notice.prominent ? scheme.errorContainer : scheme.surfaceContainerHigh,
      child: ListTile(
        dense: true,
        onTap: onTap,
        leading: Icon(
          notice.prominent ? Icons.warning_amber_outlined : Icons.image_outlined,
          color: notice.prominent ? scheme.error : scheme.onSurfaceVariant,
        ),
        title: Text(
          '[images] ${notice.line}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: onDismiss == null
            ? const Icon(Icons.chevron_right)
            : IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onDismiss,
              ),
      ),
    );
  }
}

/// The `/images` equivalent (issue #1889 R3/R5): a bottom sheet rendering
/// the shared projection lines — what rode, what dropped and why, the
/// effective cap, and the config knobs.
Future<void> showImageDropPanel(
  BuildContext context, {
  required List<String> lines,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                line,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    ),
  );
}
