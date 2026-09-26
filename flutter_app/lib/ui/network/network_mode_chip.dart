// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';

/// The compact `Local | Network` segmented chip (issue #955) — the app's
/// mode toggle. Lives in the wide shell's brand header, the narrow
/// launcher's header, and the network surface's own header.
///
/// Tapping **Network** re-enters the last selected network when the
/// controller still holds one ([NetworkModeController.enterNetwork]),
/// otherwise the networks picker ([NetworkModeController.backToNetworks]).
/// Tapping **Local** exits to the classic surface and disconnects every
/// live session (the wallet keeps all keys).
class NetworkModeChip extends StatelessWidget {
  const NetworkModeChip({
    super.key,
    required this.controller,
    required this.manager,
  });

  /// The mode navigation state machine the chip drives.
  final NetworkModeController controller;

  /// The session owner — exiting to local disconnects all sessions.
  final NetworkSessionManager manager;

  void _enterNetwork() {
    final last = controller.networkId;
    unawaited(
      (last == null || last.isEmpty)
          ? controller.backToNetworks()
          : controller.enterNetwork(last),
    );
  }

  void _exitToLocal() {
    unawaited(controller.exitToLocal());
    unawaited(manager.disconnectAll());
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final network = controller.mode == AppMode.network;
        return Container(
          key: const ValueKey('networkModeChip'),
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: colors.panelAlt,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Segment(
                label: context.l10n.networkModeLocal,
                selected: !network,
                onTap: _exitToLocal,
              ),
              _Segment(
                label: context.l10n.networkModeNetwork,
                selected: network,
                onTap: _enterNetwork,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Material(
      color: selected
          ? (isLight ? const Color(0xFFEEF2FF) : colors.panel)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected
                  ? (isLight ? colors.indigo : colors.teal)
                  : colors.dim,
            ),
          ),
        ),
      ),
    );
  }
}
