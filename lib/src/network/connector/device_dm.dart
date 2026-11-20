// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Shared agent-side fa_network DM codec and reply routing (contract §7).
///
/// The app and CLI both use this pure-Dart implementation: fanet1 decryption
/// uses only an ALREADY provisioned per-agent key, the complete decrypted
/// wrapper is returned for connector-side ACL inspection, and replies seal
/// with the exact msgId minted by [MachineConnector.sendMail].
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../messaging/hub_crypto.dart';
import 'device_dm_keys.dart';
import 'envelope.dart';
import 'machine_connector.dart';

/// Prefix of the durable, self-contained DM reply address carried as the
/// sender id in the local agent messaging fabric.
const String deviceDmReplyAddressPrefix = 'network-dm:v1:';

/// Receipt sent only AFTER the current session's mailbox write completed.
const String deviceDmAcceptedReceipt = 'accepted, awaiting steering';

/// Honest receipt for mail whose addressed session is not currently listening.
/// The original stays unacked; wake/resume policy belongs to issue #2213.
const String deviceDmQueuedReceipt = 'queued / not listening';

/// Parsed `dm:user:<uid>:<agent>@<device>` virtual channel id.
typedef DeviceDmChannelParts = ({
  String userId,
  String agentName,
  String deviceId,
});

/// Parsed encrypted DM text wrapper. Raw legacy assistant text has no session
/// and does not opt into structured replies. [replyTo] correlates a delivery
/// receipt with the original user envelope even when a retry mints a fresh
/// receipt envelope id.
typedef DeviceDmText = ({
  String text,
  String? sessionId,
  bool threaded,
  String? replyTo,
});

/// Parses a DM channel id; null on any shape violation.
DeviceDmChannelParts? parseDeviceDmChannelId(String channelId) {
  if (!channelId.startsWith(dmChannelUserPrefix)) return null;
  final rest = channelId.substring(dmChannelUserPrefix.length);
  final colon = rest.indexOf(':');
  if (colon <= 0) return null;
  final at = rest.indexOf('@', colon);
  if (at < 0 || at + 1 >= rest.length) return null;
  return (
    userId: rest.substring(0, colon),
    agentName: rest.substring(colon + 1, at),
    deviceId: rest.substring(at + 1),
  );
}

/// Unwraps `{"text": …, "sessionId"?, "threading"?, "replyTo"?}` while
/// preserving raw legacy text and malformed wrappers byte-for-byte.
DeviceDmText unwrapDeviceDmText(String plaintext) {
  if (!plaintext.startsWith('{')) {
    return (text: plaintext, sessionId: null, threaded: false, replyTo: null);
  }
  try {
    final decoded = jsonDecode(plaintext);
    if (decoded is Map && decoded['text'] is String) {
      final sessionId = decoded['sessionId'];
      final replyTo = decoded['replyTo'];
      return (
        text: decoded['text'] as String,
        sessionId: sessionId is String && sessionId.isNotEmpty
            ? sessionId
            : null,
        threaded: decoded['threading'] == 1,
        replyTo: replyTo is String && replyTo.isNotEmpty ? replyTo : null,
      );
    }
  } on FormatException {
    // Raw text also decrypts here — keep it as-is.
  }
  return (text: plaintext, sessionId: null, threaded: false, replyTo: null);
}

/// Wraps a reply only when the incoming request opted into threading. This
/// keeps legacy raw assistant replies compatible with older app viewers.
String wrapDeviceDmText(
  String reply, {
  required String? sessionId,
  required bool threaded,
  String? replyTo,
}) => threaded
    ? jsonEncode({'text': reply, 'sessionId': ?sessionId, 'replyTo': ?replyTo})
    : reply;

/// Agent-side fanet1 decoder for one enrolled device.
final class DeviceDmCodec {
  const DeviceDmCodec({
    required DeviceDmKeyProvider keys,
    required this.deviceId,
    // Public named `keys` parameter is required by cross-library callers
    // (network_presence, app connector); this._keys would be library-private.
    // ignore: prefer_initializing_formals
  }) : _keys = keys;

  final DeviceDmKeyProvider _keys;

  /// Enrolled local device id. Mail for other devices and own reply echoes is
  /// non-actionable and carries an empty payload for the normal ack/drop path.
  final String deviceId;

  /// Decodes one envelope into its complete decrypted payload plus reply
  /// metadata. Missing keys and all fanet1/AEAD failures are permanent typed
  /// rejections; key-store I/O failures propagate unchanged as transient.
  Future<DecodedMail> decode(NetworkEnvelope envelope) async {
    final channel = envelope.channel ?? '';
    final ciphertext = envelope.ciphertext ?? '';
    if (!isDmChannel(channel)) return DecodedMail(payload: ciphertext);
    final address = envelope.to ?? '';
    final at = address.lastIndexOf('@');
    if (envelope.from == address) {
      // Own-reply-echo SHAPE (sender == addressed agent): our fanned-back
      // replies are sealed to the user, so there is nothing to decrypt.
      // Flag it for the connector belt, which classifies by frame id —
      // a minted id drops quietly, a foreign id raises the incident
      // 8ff48b96 'non-echo frame with rewritten sender' warning.
      return const DecodedMail(payload: '', ownEcho: true);
    }
    if (at <= 0 || address.substring(at + 1) != deviceId) {
      return const DecodedMail(payload: '');
    }

    // Do not move this inside the permanent-decode catch: secure-store reads
    // can fail transiently and must leave the original mail unacked.
    final key = await _keys.loadExisting(address);
    if (key == null) {
      throw const MailDecodeException(
        'DM key is not provisioned for the addressed local agent',
      );
    }
    try {
      final frame = hubTryOpenFanet1(ciphertext);
      if (frame == null) {
        throw const MailDecodeException('DM payload is not valid fanet1');
      }
      final plaintext = await hubDecryptPayloadWithKeyPair(
        recipientDhKeyPair: key.keyPair,
        senderDhPubkey: frame.senderPubkey,
        frameId: envelope.msgId,
        aadTarget: channel,
        ciphertextB64: frame.ciphertextB64,
      );
      final unwrapped = unwrapDeviceDmText(plaintext);
      return DecodedMail(
        payload: plaintext,
        sessionId: unwrapped.sessionId,
        senderPubkey: base64Encode(frame.senderPubkey.bytes),
        threaded: unwrapped.threaded,
      );
    } on MailDecodeException {
      rethrow;
    } on Object {
      // Do not include the ciphertext, decrypted text, private/public keys or
      // crypto implementation error: callers surface this string in notices.
      throw const MailDecodeException(
        'DM fanet1 authentication/decryption failed',
      );
    }
  }
}

/// Self-contained route needed to answer one decrypted network DM.
final class DeviceDmReplyRoute {
  const DeviceDmReplyRoute({
    required this.network,
    required this.channel,
    required this.replyRecipient,
    required this.agentAddress,
    required this.sessionId,
    required this.senderPubkey,
    required this.threaded,
    this.replyTo,
  });

  /// Captures the authenticated route and metadata from one accepted mail.
  factory DeviceDmReplyRoute.fromMail(
    InboundMail mail, {
    required String currentAgentAddress,
  }) {
    final envelope = mail.envelope;
    final network = envelope.network;
    final channel = envelope.channel;
    final sender = envelope.from;
    final senderPubkey = mail.senderPubkey;
    if (network == null ||
        network.isEmpty ||
        channel == null ||
        !isDmChannel(channel) ||
        sender == null ||
        sender.isEmpty ||
        senderPubkey == null ||
        senderPubkey.isEmpty) {
      throw StateError('incomplete authenticated DM reply route');
    }
    return DeviceDmReplyRoute(
      network: network,
      channel: channel,
      replyRecipient: normalizeDeviceDmReplyRecipient(sender),
      agentAddress: currentAgentAddress,
      sessionId: mail.sessionId,
      senderPubkey: senderPubkey,
      threaded: mail.threaded,
      replyTo: envelope.msgId,
    );
  }

  /// Restores a route from its opaque `network-dm:v1:` address.
  factory DeviceDmReplyRoute.parse(String address) {
    try {
      if (!address.startsWith(deviceDmReplyAddressPrefix)) {
        throw const FormatException('not a network DM reply address');
      }
      final encoded = address.substring(deviceDmReplyAddressPrefix.length);
      final normalized = base64Url.normalize(encoded);
      final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (decoded is! Map) {
        throw const FormatException('route is not an object');
      }
      String requiredString(String key) {
        final value = decoded[key];
        if (value is! String || value.isEmpty) {
          throw FormatException('route field $key is missing');
        }
        return value;
      }

      final sessionId = decoded['sessionId'];
      if (sessionId != null && (sessionId is! String || sessionId.isEmpty)) {
        throw const FormatException('route sessionId is invalid');
      }
      final replyTo = decoded['replyTo'];
      if (replyTo != null && (replyTo is! String || replyTo.isEmpty)) {
        throw const FormatException('route replyTo is invalid');
      }
      final senderPubkey = requiredString('senderPubkey');
      if (base64Decode(senderPubkey).length != 32) {
        throw const FormatException('route sender public key is invalid');
      }
      final channel = requiredString('channel');
      if (parseDeviceDmChannelId(channel) == null) {
        throw const FormatException('route DM channel is invalid');
      }
      return DeviceDmReplyRoute(
        network: requiredString('network'),
        channel: channel,
        replyRecipient: normalizeDeviceDmReplyRecipient(
          requiredString('replyRecipient'),
        ),
        agentAddress: requiredString('agentAddress'),
        sessionId: sessionId as String?,
        senderPubkey: senderPubkey,
        threaded: decoded['threaded'] == true,
        replyTo: replyTo as String?,
      );
    } on Object {
      // Never echo an attacker-controlled opaque address in a tool error.
      throw const FormatException('invalid network DM reply address');
    }
  }

  final String network;
  final String channel;
  final String replyRecipient;
  final String agentAddress;
  final String? sessionId;
  final String senderPubkey;
  final bool threaded;

  /// Original user envelope id. Kept in the opaque route so delayed agent
  /// answers and queued receipts retain the same correlation after restart.
  final String? replyTo;

  /// Encodes every field needed after a CLI restart; no in-memory pub cache.
  String toAddress() {
    final route = jsonEncode({
      'network': network,
      'channel': channel,
      'replyRecipient': replyRecipient,
      'agentAddress': agentAddress,
      if (sessionId != null) 'sessionId': sessionId,
      'senderPubkey': senderPubkey,
      'threaded': threaded,
      'replyTo': ?replyTo,
    });
    return '$deviceDmReplyAddressPrefix'
        '${base64UrlEncode(utf8.encode(route)).replaceAll('=', '')}';
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceDmReplyRoute &&
      other.network == network &&
      other.channel == channel &&
      other.replyRecipient == replyRecipient &&
      other.agentAddress == agentAddress &&
      other.sessionId == sessionId &&
      other.senderPubkey == senderPubkey &&
      other.threaded == threaded &&
      other.replyTo == replyTo;

  @override
  int get hashCode => Object.hash(
    network,
    channel,
    replyRecipient,
    agentAddress,
    sessionId,
    senderPubkey,
    threaded,
    replyTo,
  );
}

/// The live backend rewrites `user:<uid>` to a bare uid. Device-WS reply
/// routing needs the explicit prefix restored; agent addresses pass through.
String normalizeDeviceDmReplyRecipient(String sender) =>
    sender.startsWith('user:') || sender.contains('@')
    ? sender
    : 'user:$sender';

/// Encrypts and queues one DM reply with the connector-minted frame id.
Future<String> sendDeviceDmReply({
  required MachineConnector connector,
  required DeviceDmKeyProvider keys,
  required DeviceDmReplyRoute route,
  required String reply,
}) async {
  final agent = await keys.loadExisting(route.agentAddress);
  if (agent == null) {
    throw StateError('DM reply key is unavailable for the current agent');
  }
  final recipient = SimplePublicKey(
    base64Decode(route.senderPubkey),
    type: KeyPairType.x25519,
  );
  return connector.sendMail(
    network: route.network,
    channel: route.channel,
    from: route.agentAddress,
    to: route.replyRecipient,
    ciphertextFor: (frameId) => hubSealFanet1(
      senderDhKeyPair: agent.keyPair,
      recipientDhPubkey: recipient,
      frameId: frameId,
      aadTarget: route.channel,
      plaintext: wrapDeviceDmText(
        reply,
        sessionId: route.sessionId,
        threaded: route.threaded,
        replyTo: route.replyTo,
      ),
    ),
  );
}
