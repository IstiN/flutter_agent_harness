// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by an MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';

/// What the invited agent gets access to (issue #955 steering): the ONE
/// channel (chankey E2E in the fragment) or the WHOLE network (join
/// link + password — a full member seeing every channel).
enum AgentInviteScope { channel, network }

/// The invite's consumer format: a bare link for desktop/mobile apps, a
/// ready CLI command for `fa`, or env variables for the CLI harness on
/// a CI runner (GitHub Actions: paste straight into a step).
enum AgentInviteFormat { link, cli, env }

/// The AC-B17 minimal agent pairing (issue #955): the agent invite
/// string for a channel or the whole network, as a link or a CLI
/// command. PRIVATE channels carry the keypair in the URI fragment —
/// `wss://<hub>?channel=<id>#pub=…&priv=…` (client-side only per RFC
/// 3986); PUBLIC channels have no chankey (showcase contract), so their
/// invite is the bare `wss://<hub>?channel=<id>`. The channel id is what
/// fa_network relays onto the DAP hub. The network scope shares the
/// human join link (`https://<host>/join?network=<id>#pw=…`). The string
/// never leaves the device except through the user's explicit Copy.
class AddAgentDialog extends StatefulWidget {
  const AddAgentDialog({
    super.key,
    required this.wallet,
    required this.networkId,
    required this.channel,
  });

  /// The fa_network hub agents connect to. Placeholder constant until hubs
  /// become configurable — documented in issue #955.
  static const hubUrl = 'wss://hub.fa1.dev/ws';

  /// The web join-page origin for network-scope invites (the app parses
  /// `…/join?network=…` links itself). Same placeholder caveat.
  static const networkJoinHost = 'https://network.fa1.dev';

  /// The device wallet holding the channel keys and the network password.
  final KeyWallet wallet;

  /// The network the channel belongs to.
  final String networkId;

  /// The channel the agent is invited into (channel scope).
  final Channel channel;

  @override
  State<AddAgentDialog> createState() => _AddAgentDialogState();
}

class _AddAgentDialogState extends State<AddAgentDialog> {
  AgentInviteScope _scope = AgentInviteScope.channel;
  AgentInviteFormat _format = AgentInviteFormat.link;

  /// The channel-scope invite string, or null when this device cannot
  /// produce one (private channel without keys in the wallet).
  String? get _channelInvite {
    final channel = widget.channel;
    if (channel.isPublic) {
      return buildPublicAgentInvite(
        hubUri: Uri.parse(AddAgentDialog.hubUrl),
        channel: channel.id,
      );
    }
    final keys = widget.wallet.channelKeysFor(widget.networkId, channel.id);
    if (keys == null) return null;
    return buildAgentInvite(
      hubUri: Uri.parse(AddAgentDialog.hubUrl),
      channel: channel.id,
      pub: keys.pub,
      priv: keys.priv,
    );
  }

  /// The network-scope join link. Always producible; the password rides
  /// the fragment when this device has it.
  String get _networkInvite {
    final entry = widget.wallet.networks[widget.networkId];
    return buildNetworkJoinLink(
      host: Uri.parse(AddAgentDialog.networkJoinHost),
      networkId: widget.networkId,
      password: entry?.password,
    );
  }

  bool get _hasNetworkPassword =>
      widget.wallet.networks[widget.networkId]?.password?.isNotEmpty ?? false;

  String? get _invite =>
      _scope == AgentInviteScope.channel ? _channelInvite : _networkInvite;

  /// What the user copies: the bare link, the CLI one-liner wrapping it
  /// (`fa dap import '…'`), or the env-var launch line for CI runners:
  /// `fa dap import '…' && FA_PROVIDER_TYPE=… FA_PROVIDER_CONFIG='…'
  /// DAP_HUB_URL=… DAP_MASTER_SECRET=… DAP_AGENT_NAME=… fa` — the vars
  /// the CLI harness documents (cli_help §Env preconfig + the DAP hub
  /// plugin). The provider pair and the hub master secret are
  /// runner-side values this dialog cannot know: placeholders.
  String? get _payload {
    final invite = _invite;
    if (invite == null) return null;
    if (_format == AgentInviteFormat.link) return invite;
    if (_format == AgentInviteFormat.env) {
      final import = _scope == AgentInviteScope.channel
          ? "fa dap import '$invite' && "
          : '';
      const providerConfig =
          '{"baseUrl":"http://your-litellm:8080/anthropic",'
          '"model":"your-model","apiKeyEnvVar":"MY_API_KEY"}';
      return "$import"
          'FA_PROVIDER_TYPE=anthropic '
          "FA_PROVIDER_CONFIG='$providerConfig' "
          'DAP_HUB_URL=${AddAgentDialog.hubUrl} '
          "DAP_MASTER_SECRET='<hub master secret>' "
          'DAP_AGENT_NAME=$_agentName fa';
    }
    if (_scope == AgentInviteScope.network) return invite;
    return "fa dap import '$invite'";
  }

  /// Suggested DAP_AGENT_NAME: a runner-friendly slug of the channel
  /// (plain `fa-agent` for the network scope).
  String get _agentName {
    if (_scope == AgentInviteScope.network) return 'fa-agent';
    final name = widget.channel.name ?? widget.channel.id;
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    return '${slug.isEmpty ? 'channel' : slug}-agent';
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final l10n = context.l10n;
    final payload = _payload;
    return AlertDialog(
      title: Text(l10n.networkAddAgentTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _scope == AgentInviteScope.network
                  ? l10n.networkAddAgentNetworkHint
                  : widget.channel.isPublic
                  ? l10n.networkAddAgentPublicHint
                  : l10n.networkAddAgentWarning,
              key: ValueKey(
                _scope == AgentInviteScope.network
                    ? 'inviteScopeHint'
                    : 'inviteHint',
              ),
              style: TextStyle(
                color:
                    _scope == AgentInviteScope.network ||
                        widget.channel.isPublic
                    ? colors.dim
                    : colors.error,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<AgentInviteScope>(
              key: const ValueKey('inviteScope'),
              segments: [
                ButtonSegment(
                  value: AgentInviteScope.channel,
                  icon: const Icon(Icons.tag, size: 16),
                  label: Text(l10n.networkAddAgentScopeChannel),
                ),
                ButtonSegment(
                  value: AgentInviteScope.network,
                  icon: const Icon(Icons.hub, size: 16),
                  label: Text(l10n.networkAddAgentScopeNetwork),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (s) => setState(() => _scope = s.first),
            ),
            const SizedBox(height: 8),
            SegmentedButton<AgentInviteFormat>(
              key: const ValueKey('inviteFormat'),
              segments: [
                ButtonSegment(
                  value: AgentInviteFormat.link,
                  icon: const Icon(Icons.link, size: 16),
                  label: Text(l10n.networkAddAgentFormatLink),
                ),
                ButtonSegment(
                  value: AgentInviteFormat.cli,
                  icon: const Icon(Icons.terminal, size: 16),
                  label: Text(l10n.networkAddAgentFormatCli),
                ),
                ButtonSegment(
                  value: AgentInviteFormat.env,
                  icon: const Icon(Icons.settings_ethernet, size: 16),
                  label: Text(l10n.networkAddAgentFormatEnv),
                ),
              ],
              selected: {_format},
              onSelectionChanged: (s) => setState(() => _format = s.first),
            ),
            if (_scope == AgentInviteScope.network && !_hasNetworkPassword) ...[
              const SizedBox(height: 8),
              Text(
                l10n.networkAddAgentNetworkNoPassword,
                key: const ValueKey('inviteNoPassword'),
                style: TextStyle(color: colors.dim, fontSize: 12),
              ),
            ],
            if (_format == AgentInviteFormat.env) ...[
              const SizedBox(height: 8),
              Text(
                l10n.networkAddAgentEnvHint,
                key: const ValueKey('inviteEnvHint'),
                style: TextStyle(color: colors.dim, fontSize: 12),
              ),
            ],
            if (_format == AgentInviteFormat.cli &&
                _scope == AgentInviteScope.channel) ...[
              const SizedBox(height: 8),
              Text(
                l10n.networkAddAgentCliHint,
                key: const ValueKey('inviteCliHint'),
                style: TextStyle(color: colors.dim, fontSize: 12),
              ),
            ],
            if (_format == AgentInviteFormat.cli &&
                _scope == AgentInviteScope.network) ...[
              const SizedBox(height: 8),
              Text(
                l10n.networkAddAgentNetworkCliHint,
                key: const ValueKey('inviteNetworkCliHint'),
                style: TextStyle(color: colors.dim, fontSize: 12),
              ),
            ],
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
                payload ?? l10n.networkAddAgentNoKeys,
                key: const ValueKey('agentInvite'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.networkClose),
        ),
        FilledButton.icon(
          key: const ValueKey('copyInvite'),
          onPressed: payload == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: payload));
                  if (context.mounted) {
                    showFahSnack(context, l10n.networkInviteCopied);
                  }
                },
          icon: const Icon(Icons.copy, size: 16),
          label: Text(l10n.networkCopy),
        ),
      ],
    );
  }
}
