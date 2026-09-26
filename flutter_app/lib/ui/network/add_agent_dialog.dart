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
    this.initialScope = AgentInviteScope.channel,
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

  /// The channel the agent is invited into (channel scope). Null when the
  /// dialog is opened from the NETWORK header — the only scope then is
  /// the whole network (the scope switch is hidden).
  final Channel? channel;

  /// The env var name shown as the master-secret field's prefix — an
  /// identifier, not prose, so it stays a constant rather than an l10n key.
  static const masterSecretPrefix = 'DAP_MASTER_SECRET=';

  /// The scope the dialog opens on (channel scope by default).
  final AgentInviteScope initialScope;

  @override
  State<AddAgentDialog> createState() => _AddAgentDialogState();
}

class _AddAgentDialogState extends State<AddAgentDialog> {
  late AgentInviteScope _scope;
  AgentInviteFormat _format = AgentInviteFormat.link;

  /// The hub master secret — a RUNNER-side value this dialog never holds:
  /// the user types it here once, then copies it row-by-row (or inside the
  /// full launch line). Never persisted.
  late final TextEditingController _secretCtrl;

  @override
  void initState() {
    super.initState();
    _scope = widget.channel == null
        ? AgentInviteScope.network
        : widget.initialScope;
    _secretCtrl = TextEditingController()..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _secretCtrl.dispose();
    super.dispose();
  }

  /// One monospace `key=value` line with its own copy button.
  Widget _envCopyRow(
    BuildContext context, {
    required String keyName,
    required String display,
    required String copyText,
  }) {
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: Text(
            display,
            key: ValueKey('envRow:$keyName'),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        IconButton(
          key: ValueKey('envCopy:$keyName'),
          icon: const Icon(Icons.copy, size: 16),
          tooltip: l10n.networkCopy,
          visualDensity: VisualDensity.compact,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: copyText));
            if (context.mounted) {
              showFahSnack(context, l10n.networkInviteCopied);
            }
          },
        ),
      ],
    );
  }

  /// The channel-scope invite string, or null when this device cannot
  /// produce one (private channel without keys in the wallet).
  String? get _channelInvite {
    final channel = widget.channel;
    if (channel == null) return null;
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
  /// (`fa dap import '…'`), or the hub-only env launch line for CI
  /// runners: `fa dap import '…' && DAP_HUB_URL=…
  /// DAP_MASTER_SECRET=… DAP_AGENT_NAME=… fa`. Provider/model config is
  /// the runner's own business (fa config / its own env) — the invite
  /// line carries ONLY the hub connection; the master secret stays a
  /// placeholder (a runner-side value this dialog never holds).
  String? get _payload {
    final invite = _invite;
    if (invite == null) return null;
    if (_format == AgentInviteFormat.link) return invite;
    if (_format == AgentInviteFormat.env) {
      final import = _scope == AgentInviteScope.channel
          ? "fa dap import '$invite' && "
          : '';
      final secret = _secretCtrl.text.isEmpty
          ? '<hub master secret>'
          : _secretCtrl.text;
      return "$import"
          'DAP_HUB_URL=${AddAgentDialog.hubUrl} '
          "DAP_MASTER_SECRET='$secret' "
          'DAP_AGENT_NAME=$_agentName fa';
    }
    if (_scope == AgentInviteScope.network) return invite;
    return "fa dap import '$invite'";
  }

  /// Suggested DAP_AGENT_NAME: a runner-friendly slug of the channel
  /// (plain `fa-agent` for the network scope).
  String get _agentName {
    final channel = widget.channel;
    if (_scope == AgentInviteScope.network || channel == null) {
      return 'fa-agent';
    }
    final name = channel.name ?? channel.id;
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    return '${slug.isEmpty ? 'channel' : slug}-agent';
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    final l10n = context.l10n;
    final payload = _payload;
    final isPublicChannel = widget.channel?.isPublic ?? false;
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
                  : isPublicChannel
                  ? l10n.networkAddAgentPublicHint
                  : l10n.networkAddAgentWarning,
              key: ValueKey(
                _scope == AgentInviteScope.network
                    ? 'inviteScopeHint'
                    : 'inviteHint',
              ),
              style: TextStyle(
                color: _scope == AgentInviteScope.network || isPublicChannel
                    ? colors.dim
                    : colors.error,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 12),
            if (widget.channel != null) ...[
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
            ],
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
              const SizedBox(height: 8),
              // Per-variable rows with their own copy buttons — CI/CD
              // secrets/vars are pasted one key=value at a time.
              if (_scope == AgentInviteScope.channel && _invite != null)
                _envCopyRow(
                  context,
                  keyName: 'IMPORT',
                  display: "fa dap import '$_invite'",
                  copyText: "fa dap import '$_invite'",
                ),
              _envCopyRow(
                context,
                keyName: 'DAP_HUB_URL',
                display: 'DAP_HUB_URL=${AddAgentDialog.hubUrl}',
                copyText: 'DAP_HUB_URL=${AddAgentDialog.hubUrl}',
              ),
              _envCopyRow(
                context,
                keyName: 'DAP_AGENT_NAME',
                display: 'DAP_AGENT_NAME=$_agentName',
                copyText: 'DAP_AGENT_NAME=$_agentName',
              ),
              // The master secret is a runner-side value: the user types
              // it here once, then copies the pair (the full line below
              // picks the typed value up too).
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('envRow:DAP_MASTER_SECRET'),
                      controller: _secretCtrl,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixText: AddAgentDialog.masterSecretPrefix,
                        prefixStyle: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        hintText: l10n.networkAddAgentSecretHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('envCopy:DAP_MASTER_SECRET'),
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: l10n.networkCopy,
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(
                          text: 'DAP_MASTER_SECRET=${_secretCtrl.text}',
                        ),
                      );
                      if (context.mounted) {
                        showFahSnack(context, l10n.networkInviteCopied);
                      }
                    },
                  ),
                ],
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
