// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/network_mode.dart';
import 'package:fa/network/slugify.dart';
import 'package:fa/network/network_session_manager.dart';

/// Opens the create-network dialog; returns the name + password +
/// public-directory flag, or null when cancelled.
Future<({String name, String password, bool isPublic})?>
showCreateNetworkDialog(BuildContext context) =>
    showDialog<({String name, String password, bool isPublic})>(
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
      isPublic: created.isPublic,
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
  bool _isPublic = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {})); // live slug preview
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    // The human types a display name; the server wants a slug — fold it
    // (live preview under the field shows the result as they type).
    final slug = slugifyNetworkName(_name.text.trim());
    final password = _password.text;
    final nameError = slug == null ? context.l10n.networkNameInvalid : null;
    final passwordError = (password.length < 8 || password.length > 128)
        ? context.l10n.networkPasswordInvalid
        : null;
    setState(() {
      _nameError = nameError;
      _passwordError = passwordError;
    });
    if (nameError != null || passwordError != null) return;
    Navigator.of(
      context,
    ).pop((name: slug, password: _password.text, isPublic: _isPublic));
  }

  @override
  Widget build(BuildContext context) {
    final slug = slugifyNetworkName(_name.text.trim());
    final showPreview = slug != null && slug != _name.text.trim().toLowerCase();
    return AlertDialog(
      title: Text(context.l10n.networkCreateNetwork),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: context.l10n.networkNameLabel,
                helperText: context.l10n.networkNameHint,
                helperMaxLines: 2,
                errorText: _nameError,
                errorMaxLines: 2,
              ),
            ),
            if (showPreview)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    context.l10n.networkSlugPreview(slug),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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
                helperMaxLines: 2,
                errorText: _passwordError,
                errorMaxLines: 2,
              ),
            ),
            CheckboxListTile(
              key: const ValueKey('createNetworkPublic'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: Text(
                context.l10n.networkListPublic,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              value: _isPublic,
              onChanged: (value) => setState(() => _isPublic = value ?? false),
            ),
          ],
        ),
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
