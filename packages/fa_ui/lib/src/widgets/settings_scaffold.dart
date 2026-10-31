// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

/// The settings-picker row: a leading icon, a title over a one-line
/// subtitle, and the trailing chevron, all inside a tap target. The
/// standard row shape of the provider/model pickers and the queue tiles —
/// extend this instead of re-rolling the tree.
class FaSettingsRow extends StatelessWidget {
  const FaSettingsRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.borderRadius,
  });

  /// The row's leading icon (filled with [ColorScheme.primary]).
  final IconData icon;

  /// The primary line.
  final String title;

  /// The one-line summary under [title].
  final String subtitle;

  /// The row's tap handler; null disables the ripple.
  final VoidCallback? onTap;

  /// Squares the ripple corners (tile-style rows inside lists).
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: borderRadius,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// The store-backed settings-section scaffold: hidden without a store
/// (hosts that did not provide one), otherwise a live stretch column that
/// rebuilds on every store change. [children] receives the promoted store.
Widget faStoreSection<TStore extends Listenable>(
  TStore? store,
  List<Widget> Function(BuildContext context, TStore store) children,
) {
  final live = store;
  if (live == null) return const SizedBox.shrink();
  return ListenableBuilder(
    listenable: live,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children(context, live),
    ),
  );
}

/// The form/editor-page error line: a hairline gap, the error in the
/// scheme's error color, then the footer gap before the action row.
/// Spread into the page column.
List<Widget> faFormErrorBlock(BuildContext context, String? error) => [
  if (error != null) ...[
    const SizedBox(height: 12),
    Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
  ],
  const SizedBox(height: 24),
];
