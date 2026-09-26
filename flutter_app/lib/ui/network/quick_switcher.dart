// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/ui/network/create_network_dialog.dart';
import 'package:fa/ui/network/join_sheet.dart';

/// Whether the network keyboard shortcuts (⌘K switcher, ⌘1 create,
/// ⌘2 join, ⌘3… recents) register. Desktop only (macOS/Windows/Linux —
/// on web-desktop [defaultTargetPlatform] reports the host OS); on mobile
/// nothing is registered and the sidebar's explicit buttons cover the
/// flows (issue #955 platform facts).
bool get networkShortcutsEnabled => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.linux ||
  TargetPlatform.windows => true,
  _ => false,
};

const _digitKeys = {
  1: LogicalKeyboardKey.digit1,
  2: LogicalKeyboardKey.digit2,
  3: LogicalKeyboardKey.digit3,
  4: LogicalKeyboardKey.digit4,
  5: LogicalKeyboardKey.digit5,
  6: LogicalKeyboardKey.digit6,
  7: LogicalKeyboardKey.digit7,
  8: LogicalKeyboardKey.digit8,
  9: LogicalKeyboardKey.digit9,
};

/// The ⌘K quick switcher of the network surface (AC-N2): wraps the
/// network home with the desktop shortcuts and shows the dropdown dialog
/// listing create (⌘1), join (⌘2) and the memberships as recents
/// (⌘3, ⌘4, … last-used first). Both the meta (⌘) and control variants
/// are registered, so the same gestures work on macOS and Windows/Linux.
class NetworkQuickSwitcher extends StatelessWidget {
  const NetworkQuickSwitcher({
    super.key,
    required this.controller,
    required this.manager,
    required this.child,
  });

  /// The mode navigation state machine.
  final NetworkModeController controller;

  /// The session manager (memberships, resume, create).
  final NetworkSessionManager manager;

  /// The network surface below.
  final Widget child;

  /// The recents: the mode store's last network first, then the remaining
  /// memberships in membership (wallet insertion) order.
  List<String> _recentNetworkIds() {
    final ids = manager.wallet.networks.keys.toList();
    final last = controller.networkId;
    if (last != null && ids.remove(last)) ids.insert(0, last);
    return ids;
  }

  Map<ShortcutActivator, VoidCallback> _both(
    LogicalKeyboardKey key,
    VoidCallback action,
  ) => {
    SingleActivator(key, meta: true): action,
    SingleActivator(key, control: true): action,
  };

  void _create(BuildContext context) => unawaited(
    runCreateNetworkFlow(context, controller: controller, manager: manager),
  );

  void _join(BuildContext context) => unawaited(
    showJoinSheet(context, controller: controller, manager: manager),
  );

  /// The same path as tapping a sidebar row: enter the network in the
  /// mode store, resume the session through the manager.
  void _switchTo(BuildContext context, String networkId) {
    unawaited(controller.enterNetwork(networkId));
    unawaited(() async {
      try {
        await manager.resume(networkId);
      } on StateError catch (e) {
        if (context.mounted) showFahErrorSnack(context, e.message);
      } on FaNetworkException catch (e) {
        if (context.mounted) showFahErrorSnack(context, e.message);
      } on Object catch (e) {
        if (context.mounted) showFahErrorSnack(context, '$e');
      }
    }());
  }

  void _openSwitcher(BuildContext context) {
    final recents = _recentNetworkIds();
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('networkQuickSwitcher'),
          title: Text(context.l10n.networkQuickSwitcherTitle),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (manager.hasJwt)
                  _row(
                    dialogContext,
                    key: const ValueKey('quickSwitcher:create'),
                    label: context.l10n.networkCreateNetwork,
                    hint: '⌘1', // l10n:ignore
                    action: () => _create(context),
                  ),
                _row(
                  dialogContext,
                  key: const ValueKey('quickSwitcher:join'),
                  label: context.l10n.networkJoinTitle,
                  hint: '⌘2', // l10n:ignore
                  action: () => _join(context),
                ),
                for (var i = 0; i < recents.length && i < 7; i++)
                  _row(
                    dialogContext,
                    key: ValueKey('quickSwitcher:${recents[i]}'),
                    label:
                        manager.wallet.networks[recents[i]]?.name ?? recents[i],
                    hint: '⌘${i + 3}', // l10n:ignore
                    action: () => _switchTo(context, recents[i]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext dialogContext, {
    required Key key,
    required String label,
    required String hint,
    required VoidCallback action,
  }) {
    return ListTile(
      key: key,
      dense: true,
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        hint,
        style: TextStyle(color: FahColors.of(dialogContext).dim, fontSize: 12),
      ),
      onTap: () {
        Navigator.of(dialogContext).pop();
        action();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!networkShortcutsEnabled) return child;
    final recents = _recentNetworkIds();
    final bindings = <ShortcutActivator, VoidCallback>{
      ..._both(LogicalKeyboardKey.keyK, () => _openSwitcher(context)),
      if (manager.hasJwt)
        ..._both(LogicalKeyboardKey.digit1, () => _create(context)),
      ..._both(LogicalKeyboardKey.digit2, () => _join(context)),
      for (var i = 0; i < recents.length && i < 7; i++)
        ..._both(_digitKeys[i + 3]!, () => _switchTo(context, recents[i])),
    };
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(autofocus: true, child: child),
    );
  }
}
