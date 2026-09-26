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
  String? _nameError;
  String? _passwordError;

  /// The server's exact rules (fa_network `validNetworkName` /
  /// `validNetworkCreate`): a lowercase slug and an 8–128 char password —
  /// validated client-side so the user never round-trips a 400.
  static final _namePattern = RegExp(
    r'^[a-z0-9][a-z0-9-]*[REDACTED:Sensitive Value]',
  );

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final password = _password.text;
    final nameError =
        (name.length < 3 || name.length > 64 || !_namePattern.hasMatch(name))
        ? context.l10n.networkNameInvalid
        : null;
    final passwordError = (password.length < 8 || password.length > 128)
        ? context.l10n.networkPasswordInvalid
        : null;
    setState(() {
      _nameError = nameError;
      _passwordError = passwordError;
    });
    if (nameError != null || passwordError != null) return;
    Navigator.of(context).pop((name: name, password: _password.text));
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
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: context.l10n.networkNameLabel,
              helperText: context.l10n.networkNameHint,
              errorText: _nameError,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: context.l10n.networkPasswordLabel,
              helperText: context.l10n.networkPasswordHint,
              errorText: _passwordError,
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
          onPressed: _submit,
          child: Text(context.l10n.networkCreate),
        ),
      ],
    );
  }
}
