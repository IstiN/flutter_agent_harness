// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:fa/network/wallet_export.dart';

/// The networks sidebar's wallet overflow menu (issue #955):
/// passphrase-protected export (to the clipboard — file save is desktop
/// polish) and import. Import replaces the live wallet's contents in place
/// via [KeyWallet.replaceWith] — only on success; a failed import leaves
/// the device wallet untouched.
class WalletMenuButton extends StatelessWidget {
  const WalletMenuButton({super.key, required this.manager, this.exportKdf});

  /// The session manager owning the wallet.
  final NetworkSessionManager manager;

  /// Argon2id cost override for tests (the spec default is deliberately
  /// expensive); production passes null.
  final WalletKdfParams? exportKdf;

  Future<void> _export(BuildContext context) async {
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => const _PassphraseDialog(),
    );
    if (passphrase == null || passphrase.isEmpty || !context.mounted) return;
    try {
      final json = await exportWallet(
        manager.wallet,
        passphrase,
        kdf: exportKdf ?? const WalletKdfParams(),
      );
      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        showFahSnack(context, context.l10n.networkWalletExported);
      }
    } on Object catch (e) {
      if (context.mounted) {
        showFahErrorSnack(
          context,
          context.l10n.networkWalletExportFailed('$e'),
        );
      }
    }
  }

  Future<void> _import(BuildContext context) async {
    final imported = await showDialog<bool>(
      context: context,
      builder: (_) => _ImportDialog(manager: manager),
    );
    if (imported == true && context.mounted) {
      showFahSnack(context, context.l10n.networkWalletImported);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const ValueKey('walletMenu'),
      icon: const Icon(Icons.more_vert, size: 20),
      tooltip: context.l10n.networkWalletTooltip,
      onSelected: (value) {
        if (value == 'export') unawaited(_export(context));
        if (value == 'import') unawaited(_import(context));
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'export',
          child: Text(context.l10n.networkWalletExport),
        ),
        PopupMenuItem(
          value: 'import',
          child: Text(context.l10n.networkWalletImport),
        ),
      ],
    );
  }
}

/// Asks for the export passphrase twice; returns it only when both entries
/// match and are non-empty (null = cancelled).
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog();

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    if (_first.text.isEmpty) {
      setState(() => _error = context.l10n.networkPassphraseEmpty);
      return;
    }
    if (_first.text != _second.text) {
      setState(() => _error = context.l10n.networkPassphraseMismatch);
      return;
    }
    Navigator.of(context).pop(_first.text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final error = _error;
    return AlertDialog(
      title: Text(context.l10n.networkWalletExport),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _first,
            obscureText: true,
            decoration: InputDecoration(
              labelText: context.l10n.networkPassphraseLabel,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _second,
            obscureText: true,
            decoration: InputDecoration(
              labelText: context.l10n.networkPassphraseRepeatLabel,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error, style: TextStyle(color: colors.error, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(context.l10n.networkExport),
        ),
      ],
    );
  }
}

/// Paste-JSON + passphrase import. The wallet is replaced ONLY on a
/// successful decrypt+parse; a [WalletImportException] keeps the dialog
/// open with the error shown inline.
class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.manager});

  final NetworkSessionManager manager;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _json = TextEditingController();
  final _passphrase = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _json.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final imported = await importWallet(_json.text, _passphrase.text);
      await widget.manager.wallet.replaceWith(imported);
      widget.manager.walletExternallyUpdated();
      if (mounted) Navigator.of(context).pop(true);
    } on WalletImportException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final error = _error;
    return AlertDialog(
      title: Text(context.l10n.networkWalletImport),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _json,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: context.l10n.networkWalletJsonLabel,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passphrase,
            obscureText: true,
            decoration: InputDecoration(
              labelText: context.l10n.networkPassphraseLabel,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.networkWalletImportWarning,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.dim),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error, style: TextStyle(color: colors.error, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: Text(context.l10n.networkImport),
        ),
      ],
    );
  }
}
