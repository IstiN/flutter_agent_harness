// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/ui/chats/local_sessions_panel.dart' show LocalSessionsPanel;
import 'package:fa/ui/chats/messenger_list_row_style.dart';
import 'package:fa/ui/widgets/messenger_section_header.dart'
    show MessengerGlassBodyInsets;
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// Shared geometry for the Networks/Devices Telegram-style drill-down.
abstract final class MessengerDrilldownMetrics {
  static const double stripWidth = 70;
  static const double itemPitch = 70;
  static const double avatarSize = 50;
  static const double capsuleWidth = 6;
  static const double capsuleHeight = 51;
}

/// One identity in a [MessengerAvatarList] or [MessengerAvatarStrip].
/// The avatar is supplied by the caller so networks can use a letter and
/// devices can compose the same gradient with their platform/presence glyph.
final class MessengerAvatarItem {
  const MessengerAvatarItem({
    required this.key,
    required this.id,
    required this.label,
    required this.avatar,
    this.subtitle,
    this.trailing,
  });

  final Key key;
  final String id;
  final String label;
  final Widget Function(bool selected) avatar;
  final String? subtitle;
  final Widget? trailing;
}

/// Level 1: comfortable 70pt identity rows. This is the same widget used
/// by Networks and Devices; a row tap opens the strip + content level.
final class MessengerAvatarList extends StatelessWidget {
  const MessengerAvatarList({
    super.key,
    required this.items,
    required this.onOpen,
    required this.listKey,
    this.bottomReserve = 0,
  });

  final List<MessengerAvatarItem> items;
  final ValueChanged<String> onOpen;
  final Key listKey;
  final double bottomReserve;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final colors = FahColors.of(context);
    return ListView.builder(
      key: listKey,
      padding: EdgeInsets.only(
        top: MessengerGlassBodyInsets.topOf(context) + 4,
        bottom: 4 + bottomReserve,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return SizedBox(
          key: item.key,
          height: MessengerDrilldownMetrics.itemPitch,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onOpen(item.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    item.avatar(false),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: tokens.ink1,
                            ),
                          ),
                          if (item.subtitle case final subtitle?
                              when subtitle.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: colors.dim),
                            ),
                          ],
                        ],
                      ),
                    ),
                    ?item.trailing,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Level 2's mini identity rail. Selection and geometry intentionally stay
/// identical between Networks and Devices; only the supplied avatar differs.
final class MessengerAvatarStrip extends StatelessWidget {
  const MessengerAvatarStrip({
    super.key,
    required this.items,
    required this.selectedId,
    required this.onOpen,
    required this.stripKey,
    required this.selectedCapsuleKey,
  });

  final List<MessengerAvatarItem> items;
  final String selectedId;
  final ValueChanged<String> onOpen;
  final Key stripKey;
  final Key selectedCapsuleKey;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    return SizedBox(
      key: stripKey,
      width: MessengerDrilldownMetrics.stripWidth,
      child: items.isEmpty
          ? const SizedBox.shrink()
          : ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: ListView.builder(
                padding: EdgeInsets.only(
                  top: MessengerGlassBodyInsets.topOf(context) + 4,
                  bottom: 4,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final selected = item.id == selectedId;
                  return SizedBox(
                    key: item.key,
                    width: MessengerDrilldownMetrics.stripWidth,
                    height: MessengerDrilldownMetrics.itemPitch,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => onOpen(item.id),
                        child: Tooltip(
                          message: item.label,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              item.avatar(selected),
                              if (selected)
                                Positioned(
                                  // Keep the full 6pt capsule on-screen; a
                                  // zero inset clips it to an edge sliver.
                                  left: 4,
                                  top:
                                      (MessengerDrilldownMetrics.itemPitch -
                                          MessengerDrilldownMetrics
                                              .capsuleHeight) /
                                      2,
                                  child: Container(
                                    key: selectedCapsuleKey,
                                    width:
                                        MessengerDrilldownMetrics.capsuleWidth,
                                    height:
                                        MessengerDrilldownMetrics.capsuleHeight,
                                    decoration: BoxDecoration(
                                      color: tokens.accent,
                                      borderRadius: BorderRadius.circular(
                                        MessengerDrilldownMetrics.capsuleWidth /
                                            2,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// The shared level transition: the strip appears without animating while
/// only the root/detail content slides and fades into the remaining width.
final class MessengerDrilldownBody extends StatelessWidget {
  const MessengerDrilldownBody({
    super.key,
    required this.drilledIn,
    required this.contentKey,
    required this.content,
    this.strip,
  });

  final bool drilledIn;
  final Key contentKey;
  final Widget content;
  final Widget? strip;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (drilledIn && strip != null) strip!,
      Expanded(
        child: AnimatedSwitcher(
          duration: FaMotion.duration(
            context,
            const Duration(milliseconds: 200),
          ),
          switchInCurve: Curves.easeInOutCubic,
          switchOutCurve: Curves.easeInOutCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0.08, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: KeyedSubtree(key: contentKey, child: content),
        ),
      ),
    ],
  );
}

/// The common 70pt Networks channel / Devices session row. Passing no
/// [leading] removes the repeated avatar while preserving the list anatomy.
final class MessengerPanelRow extends StatelessWidget {
  const MessengerPanelRow({
    super.key,
    required this.title,
    required this.meta,
    required this.selected,
    required this.hairline,
    required this.onTap,
    this.leading,
    this.timestamp = '',
    this.metaSuffix = '',
    this.metaTrailing,
  });

  final String title;
  final String? meta;
  final bool selected;
  final bool hairline;
  final VoidCallback? onTap;
  final Widget? leading;
  final String timestamp;

  /// Non-flexing metadata (for example relative activity) that remains
  /// visible even when the flexible host/project label needs an ellipsis.
  final String metaSuffix;
  final Widget? metaTrailing;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final tokens = FaDesignTokens.of(context);
    final foreground = selected ? tokens.accentInk : colors.text;
    final subdued = selected
        ? tokens.accentInk.withValues(alpha: .82)
        : colors.dim;
    return Material(
      color: messengerListRowColor(selected: selected, accent: tokens.accent),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: LocalSessionsPanel.sessionRowPitch,
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      if (leading case final avatar?) ...[
                        avatar,
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: foreground,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                                if (timestamp.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    timestamp,
                                    style: TextStyle(
                                      color: subdued,
                                      fontSize: 10.5,
                                      height: 1.2,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if ((meta?.isNotEmpty ?? false) ||
                                metaSuffix.isNotEmpty ||
                                metaTrailing != null) ...[
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      meta ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: subdued,
                                        fontSize: 12.5,
                                        height: 1.2,
                                      ),
                                    ),
                                  ),
                                  if (metaSuffix.isNotEmpty)
                                    Text(
                                      '${(meta?.isNotEmpty ?? false) ? ' · ' : ''}$metaSuffix',
                                      maxLines: 1,
                                      style: TextStyle(
                                        color: subdued,
                                        fontSize: 12,
                                        height: 1.2,
                                      ),
                                    ),
                                  ?metaTrailing,
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (onTap != null) ...[
                        const SizedBox(width: 8),
                        FaIcon(
                          FaSemanticIcon.chevronRight,
                          size: 18,
                          color: subdued,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (hairline)
                Container(
                  height: 1,
                  margin: EdgeInsets.only(
                    left: leading == null ? 10 : 66,
                    right: 8,
                  ),
                  color: colors.border.withValues(alpha: .45),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
