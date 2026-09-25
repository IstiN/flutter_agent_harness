// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';

/// The AC-B17 minimal agent pairing (issue #955): shows the agent invite
/// string for a PRIVATE channel — `wss://<hub>?channel=<name>#pub=…&priv=…`.
/// The channel keys travel in the URI fragment (client-side only per
/// RFC 3986) and the string never leaves the device except through the
/// user's explicit Copy.
class AddAgentDialog extends StatelessWidget {
  const AddAgentDialog({
    super.key,
    required this.wallet,
    required this.networkId,
    required this.channel,
  });

  /// The fa_network hub agents connect to. Placeholder constant until hubs
  /// become configurable — documented in issue #955.
  static const hubUrl = 'wss://hub.fa1.dev/ws';

  /// The device wallet holding the channel keys.
  final KeyWallet wallet;

  /// The network the channel belongs to.
  final String networkId;

  /// The private channel the agent is invited into.
  final Channel channel;

  /// The invite string, or null when this device holds no keys for the
  /// channel (an owner who never opened it, an imported wallet, …).
  String? get invite {
    final keys = wallet.channelKeysFor(networkId, channel.id);
    if (keys == null) return null;
    return buildAgentInvite(
      hubUri: Uri.parse(hubUrl),
      channel: channel.name ?? channel.id,
      pub: keys.pub,
      priv: keys.priv,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final invite = this.invite;
    return AlertDialog(
      title: Text(context.l10n.networkAddAgentTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.networkAddAgentWarning,
            style: TextStyle(color: colors.error, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.codeBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.border),
            ),
            child: Text(
              invite ?? context.l10n.networkAddAgentNoKeys,
              key: const ValueKey('agentInvite'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.networkClose),
        ),
        FilledButton.icon(
          key: const ValueKey('copyInvite'),
          onPressed: invite == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: invite));
                  if (context.mounted) {
                    showFahSnack(context, context.l10n.networkInviteCopied);
                  }
                },
          icon: const Icon(Icons.copy, size: 16),
          label: Text(context.l10n.networkCopy),
        ),
      ],
    );
  }
}
