// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/network_session_manager.dart';

/// Opens the create-network dialog; returns the name + password, or null
/// when cancelled.
Future<({String name, String password})?> showCreateNetworkDialog(
  BuildContext context,
) => showDialog<({String name, String password})>(
  context: context,
  builder: (_) => const CreateNetworkDialog(),
);

/// The full create-network flow (owner flow; requires a JWT — callers only
/// offer it then): prompt for name + password, create via the manager
/// (dev-login token accepted by the backend), enter the new network.
/// Server errors surface as a snackbar (e.g. 401 without a JWT).
Future<void> runCreateNetworkFlow(
  BuildContext context, {
  required NetworkModeController controller,
  required NetworkSessionManager manager,
}) async {
  final created = await showCreateNetworkDialog(context);
  if (created == null || !context.mounted) return;
  try {
    final session = await manager.createNetwork(
      name: created.name,
      password: created.password,
    );
    await controller.enterNetwork(session.networkId);
  } on FaNetworkException catch (e) {
    if (context.mounted) showFahErrorSnack(context, e.message);
  } on Object catch (e) {
    if (context.mounted) showFahErrorSnack(context, '$e');
  }
}

/// The create-network dialog (owner flow; requires a JWT — the entry
/// points are only shown then). Returns the name + password, or null when
/// cancelled.
class CreateNetworkDialog extends StatefulWidget {
  const CreateNetworkDialog({super.key});

  @override
  State<CreateNetworkDialog> createState() => _CreateNetworkDialogState();
}

class _CreateNetworkDialogState extends State<CreateNetworkDialog> {
  final _name = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.networkCreateNetwork),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: context.l10n.networkNameLabel,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: context.l10n.networkPasswordLabel,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('createNetworkConfirm'),
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty || _password.text.isEmpty) return;
            Navigator.of(context).pop((name: name, password: _password.text));
          },
          child: Text(context.l10n.networkCreate),
        ),
      ],
    );
  }
}
