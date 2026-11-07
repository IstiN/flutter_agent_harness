// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'wide_layout_shell.dart';

/// Narrow overflow navigation presentation shared by the phone dock's More
/// action and its responsive secondary destinations.
extension _WideLayoutShellNavigation on _WideLayoutShellState {
  Future<void> _showNarrowMoreSheet(
    List<MessengerRailDestination> destinations,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (sheetContext) {
        final tokens = FaDesignTokens.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FaSurface(
              key: const ValueKey('narrowShellMoreSheet'),
              glass: tokens.direction == FaVisualDirection.glass,
              useBackdropGroup: true,
              borderRadius: BorderRadius.circular(tokens.radiusLg),
              color: tokens.direction == FaVisualDirection.glass
                  ? tokens.surface1.withValues(alpha: .92)
                  : tokens.surface1,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            sheetContext.l10n.commonMore,
                            style: TextStyle(
                              color: tokens.ink1,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        FaIconActionButton(
                          buttonKey: const ValueKey('narrowShellMoreClose'),
                          tooltip: MaterialLocalizations.of(
                            sheetContext,
                          ).closeButtonTooltip,
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          diameter: 32,
                          glyphSize: 20,
                          glass: false,
                          child: const FaIcon(FaSemanticIcon.close),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                  const FaHairline(symmetry: 0),
                  for (var index = 0; index < destinations.length; index++) ...[
                    _narrowMoreTile(sheetContext, destinations[index]),
                    if (index < destinations.length - 1)
                      const FaHairline(symmetry: 0, indent: 72),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _narrowMoreTile(
    BuildContext sheetContext,
    MessengerRailDestination destination,
  ) {
    final tokens = FaDesignTokens.of(sheetContext);
    final name = (destination.rowKey as ValueKey<String>).value;
    final showBadge = destination.badge != null && destination.badge! > 0;
    return Semantics(
      button: true,
      selected: destination.selected,
      label: destination.label,
      child: FaSettingsTile(
        key: ValueKey('narrowShellMore-$name'),
        leading: SizedBox(
          width: 38,
          height: 32,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 5,
                child: Icon(
                  destination.icon,
                  size: 22,
                  color: destination.selected ? tokens.accent : tokens.ink2,
                ),
              ),
              if (showBadge)
                Positioned(
                  right: 0,
                  top: 0,
                  child: MessengerRailBadge(
                    count: destination.badge!,
                    muted: destination.badgeMuted,
                  ),
                ),
            ],
          ),
        ),
        title: Text(
          destination.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: destination.selected ? tokens.accent : tokens.ink1,
          ),
        ),
        trailing: Icon(
          destination.selected
              ? Icons.check_rounded
              : Icons.chevron_right_rounded,
          color: destination.selected ? tokens.accent : tokens.ink2,
        ),
        onTap: () {
          Navigator.of(sheetContext).pop();
          destination.onTap?.call(context);
        },
      ),
    );
  }
}
