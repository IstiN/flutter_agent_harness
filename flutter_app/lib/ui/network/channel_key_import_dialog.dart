// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session.dart';

/// Imports a private-channel key invite into this device's wallet, then
/// rebuilds the open channel's decoded history with the newly available key.
Future<bool> showChannelKeyImportDialog(
  BuildContext context, {
  required KeyWallet wallet,
  required NetworkSession session,
  required String networkId,
  required String channelId,
}) async {
  final imported = await showDialog<bool>(
    context: context,
    builder: (_) => _ChannelKeyImportDialog(
      wallet: wallet,
      session: session,
      networkId: networkId,
      channelId: channelId,
    ),
  );
  return imported ?? false;
}

class _ChannelKeyImportDialog extends StatefulWidget {
  const _ChannelKeyImportDialog({
    required this.wallet,
    required this.session,
    required this.networkId,
    required this.channelId,
  });

  final KeyWallet wallet;
  final NetworkSession session;
  final String networkId;
  final String channelId;

  @override
  State<_ChannelKeyImportDialog> createState() =>
      _ChannelKeyImportDialogState();
}

class _ChannelKeyImportDialogState extends State<_ChannelKeyImportDialog> {
  final _inviteController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _inviteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final invite = parseAgentInvite(_inviteController.text.trim());
      if (invite.channel != widget.channelId) {
        throw AgentInviteFormatException(l10n.networkChannelKeyWrongChannel);
      }
      // A length check alone cannot catch a torn invite pairing one keypair's
      // public half with another's private half. Such a wallet can encrypt but
      // never decrypt, so reject it before persisting anything.
      const codec = EnvelopeCodec();
      final keyPair = await codec.keyPairFromPriv(invite.priv);
      final derivedPub = base64UrlEncode(
        (await keyPair.extractPublicKey()).bytes,
      );
      if (derivedPub != invite.pub) {
        throw AgentInviteFormatException(l10n.networkChannelKeyMismatch);
      }
      if (!mounted) return;
      await widget.wallet.addChannelKeys(
        networkId: widget.networkId,
        channel: widget.channelId,
        pub: invite.pub,
        priv: invite.priv,
      );
      await widget.session.reloadChannel(widget.channelId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on InviteFormatException catch (e) {
      _showError(e.message);
    } on Object {
      _showError(l10n.networkChannelKeyImportFailed);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.networkChannelKeyImport),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('channelKeyInviteField'),
              controller: _inviteController,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.networkChannelKeyInviteLabel,
                helperText: l10n.networkChannelKeyImportHint,
                errorText: _error,
              ),
              onSubmitted: (_) {
                if (!_busy) unawaited(_submit());
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('channelKeyImportSubmit'),
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.networkImport),
        ),
      ],
    );
  }
}
