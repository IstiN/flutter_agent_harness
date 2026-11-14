// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/network/device_connector_service.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/models.dart';

import 'package:fa_ui/fa_ui.dart';
// The fanet1 DM primitives are pure Dart in the messaging core.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';

/// One decrypted DM row for the conversation view.
class DeviceDmMessage {
  const DeviceDmMessage({
    required this.id,
    required this.text,
    required this.mine,
    required this.createdAt,
  });

  final String id;
  final String text;

  /// True for the local user's own messages (outgoing + echoed history).
  final bool mine;
  final DateTime? createdAt;
}

/// The remote-agent DM conversation pane (Devices → session/agent tap):
/// header with a back button, decrypted fanet1 history from
/// [FaNetworkClient.listDmInbox], and a composer sending through
/// [DeviceConnectorService.sendDmToAgent]. Empty history invites the
/// first message — the receiver wakes its offline session on delivery.
class DeviceConversationPane extends StatefulWidget {
  const DeviceConversationPane({
    super.key,
    required this.service,
    required this.deviceId,
    required this.deviceLabel,
    required this.agentAddress,
    this.sessionId,
    required this.onBack,
  });

  final DeviceConnectorService service;
  final String deviceId;
  final String deviceLabel;

  /// The FULL agent address (`name@deviceId`) the DM targets.
  final String agentAddress;

  /// The tapped session (null = the device's active/latest session).
  final String? sessionId;
  final VoidCallback onBack;

  @override
  State<DeviceConversationPane> createState() => _DeviceConversationPaneState();
}

class _DeviceConversationPaneState extends State<DeviceConversationPane> {
  final _composer = TextEditingController();
  final _messages = <DeviceDmMessage>[];
  String? _nextCursor;
  String? _error;
  var _loading = true;
  var _sending = false;

  String get _agentName {
    final at = widget.agentAddress.indexOf('@');
    return at < 0 ? widget.agentAddress : widget.agentAddress.substring(0, at);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadHistory());
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<String> _channel() => widget.service.dmChannelForAgent(
    deviceId: widget.deviceId,
    agentName: _agentName,
  );

  Future<void> _loadHistory({String? cursor}) async {
    setState(() {
      _loading = true;
      if (cursor == null) _error = null;
    });
    try {
      final client = await widget.service.sessionManager.accountClient();
      if (client == null) throw StateError('not signed in');
      final page = await client.listDmInbox(
        await _channel(),
        limit: 50,
        cursor: cursor,
      );
      final decoded = <DeviceDmMessage>[];
      for (final envelope in page.items) {
        final message = await _decode(envelope);
        if (message != null) decoded.add(message);
      }
      if (!mounted) return;
      setState(() {
        if (cursor == null) {
          _messages
            ..clear()
            ..addAll(decoded);
        } else {
          _messages.insertAll(0, decoded);
        }
        _nextCursor = page.nextCursor;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Decrypts one fanet1 inbox row. My own frames were sealed with
  /// DH(myPriv, agentPub) — the peer's roster dmPub recomputes the same
  /// shared key; their frames carry the sender pubkey in the header.
  Future<DeviceDmMessage?> _decode(Envelope envelope) async {
    try {
      final frame = hubTryOpenFanet1(envelope.payload);
      if (frame == null) return null;
      final myId = await widget.service.accountUserId();
      final mine =
          envelope.senderId == 'user:$myId' || envelope.senderId == myId;
      final senderPub = mine ? await _peerPubkey() : frame.senderPubkey;
      if (senderPub == null) return null;
      final plaintext = await hubDecryptPayloadWithKeyPair(
        recipientDhKeyPair: await widget.service.sessionManager.wallet
            .identityKeyPair(),
        senderDhPubkey: senderPub,
        frameId: envelope.id,
        aadTarget: envelope.channelId,
        ciphertextB64: frame.ciphertextB64,
      );
      var text = plaintext;
      if (mine) {
        try {
          final decoded = jsonDecode(plaintext);
          if (decoded is Map && decoded['text'] is String) {
            text = decoded['text'] as String;
          }
        } on FormatException {
          // Raw assistant text also decrypts here — keep it as-is.
        }
      }
      return DeviceDmMessage(
        id: envelope.id,
        text: text,
        mine: mine,
        createdAt: envelope.createdAt,
      );
    } on Object {
      // Undecryptable rows (wrong key epoch, legacy shapes) drop out of
      // the conversation instead of crashing the pane.
      return null;
    }
  }

  Future<SimplePublicKey?> _peerPubkey() async {
    final pub = widget.service.agentDmPub(
      deviceId: widget.deviceId,
      agentName: _agentName,
    );
    if (pub == null) return null;
    return SimplePublicKey(base64Decode(pub), type: KeyPairType.x25519);
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final id = await widget.service.sendDmToAgent(
        deviceId: widget.deviceId,
        agentName: _agentName,
        sessionId: widget.sessionId,
        text: text,
      );
      if (!mounted) return;
      _composer.clear();
      setState(() {
        _messages.add(
          DeviceDmMessage(id: id, text: text, mine: true, createdAt: null),
        );
        _error = null;
      });
      // The echo above is immediate; the server row replaces it on the
      // next history refresh (auto-replies arrive the same way).
      unawaited(_loadHistory());
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = FahColors.of(context);
    return Column(
      key: ValueKey('deviceConversation:${widget.deviceId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 16, 6),
          child: Row(
            children: [
              GestureDetector(
                key: const ValueKey('conversationBack'),
                onTap: widget.onBack,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: FaIcon(
                    FaSemanticIcon.back,
                    size: 18,
                    color: colors.dim,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  widget.sessionId == null
                      ? '${widget.deviceLabel} · $_agentName'
                      : '${widget.deviceLabel} · '
                            '${widget.sessionId!.substring(0, widget.sessionId!.length < 8 ? widget.sessionId!.length : 8)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _history(context, colors)),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              error,
              key: const ValueKey('conversationError'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.pending, fontSize: 11),
            ),
          ),
        _composerRow(context, colors),
      ],
    );
  }

  Widget _history(BuildContext context, FahColors colors) {
    if (_loading && _messages.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          key: const ValueKey('conversationEmpty'),
          padding: const EdgeInsets.all(16),
          child: Text(
            context.l10n.networkDeviceConversationEmpty,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.dim, fontSize: 12),
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('conversationHistory'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      children: [
        if (_nextCursor != null)
          GestureDetector(
            key: const ValueKey('conversationLoadOlder'),
            onTap: _loading
                ? null
                : () => unawaited(_loadHistory(cursor: _nextCursor)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Center(
                child: Text(
                  context.l10n.networkDeviceConversationOlder,
                  style: TextStyle(color: colors.teal, fontSize: 11),
                ),
              ),
            ),
          ),
        for (final message in _messages)
          Align(
            key: ValueKey('dm:${message.id}'),
            alignment: message.mine
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              constraints: const BoxConstraints(maxWidth: 320),
              decoration: BoxDecoration(
                color: message.mine
                    ? colors.teal.withValues(alpha: 0.16)
                    : colors.dim.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                message.text,
                style: TextStyle(color: colors.text, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }

  Widget _composerRow(BuildContext context, FahColors colors) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
    child: Row(
      children: [
        Expanded(
          child: FaTextField(
            key: const ValueKey('conversationComposer'),
            controller: _composer,
            dense: true,
            hintText: context.l10n.networkDeviceConversationHint,
            onSubmitted: (_) => unawaited(_send()),
          ),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          key: const ValueKey('conversationSend'),
          onTap: _sending ? null : () => unawaited(_send()),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: FaIcon(FaSemanticIcon.send, size: 18, color: colors.teal),
          ),
        ),
      ],
    ),
  );
}
