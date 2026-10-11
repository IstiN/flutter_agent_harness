// One-off E2E probe (issue #955 / invite verification): joins the
// production fa_network as a fresh member (the "invited agent" path),
// encrypts a fanet1 envelope for the channel key from the wallet, and
// relays it. Never committed with secrets — reads the Keychain wallet
// at runtime like the app does.
//
// Run: dart run tool/network_send_probe.dart <channelId> <text>
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

const base = 'https://network.fa1.dev';
final _x25519 = X25519();
final _aead = Chacha20.poly1305Aead();
final _mac = Hmac.sha256();
final _rng = Random.secure();

String _uuid4() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

Future<Uint8List> _hkdf({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  required int length,
}) async {
  final prk = await _mac.calculateMac(ikm, secretKey: SecretKey(salt));
  var okm = <int>[];
  var prev = const <int>[];
  var counter = 1;
  while (okm.length < length) {
    final block = await _mac.calculateMac([...prev, ...info, counter],
        secretKey: SecretKey(prk.bytes));
    prev = block.bytes;
    okm = [...okm, ...block.bytes];
    counter++;
  }
  return Uint8List.fromList(okm.sublist(0, length));
}

Future<void> main(List<String> args) async {
  final channelId = args[0];
  final text = args.sublist(1).join(' ');
  final walletRaw = Process.runSync('security', [
    'find-generic-password', '-s', 'fa.app', '-a', 'fa_network_wallet', '-w',
  ]).stdout as String;
  final wallet = jsonDecode(walletRaw.trim()) as Map<String, dynamic>;
  final networkId = (wallet['networks'] as Map<String, dynamic>)
      .keys.singleWhere((k) => k.contains(channelId) || true);
  final net = (wallet['networks'] as Map<String, dynamic>)[networkId]!;
  final password = net['password'] as String;
  final channelKeys = (wallet['channels'] as Map<String, dynamic>)
      ['$networkId/$channelId'] as Map<String, dynamic>;

  // 1. Join as a fresh member (the invited-agent path).
  final join = await http.post(
    Uri.parse('$base/api/networks/$networkId/join'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode({
      'password': password,
      'displayName': 'fa-probe (invite test)',
    }),
  );
  if (join.statusCode != 200) {
    stderr.writeln('join failed: ${join.statusCode} ${join.body}');
    exitCode = 1;
    return;
  }
  final token = jsonDecode(join.body)['sessionToken'] as String;
  final auth = {'authorization': 'Bearer $token', 'content-type': 'application/json'};
  stdout.writeln('[joined] network ${net['name']} — member session ok');

  // 2. Channel name rides the AEAD AAD — fetch it.
  final ch = await http.get(Uri.parse('$base/api/channels/$channelId'),
      headers: {'authorization': 'Bearer $token'});
  final channelName = jsonDecode(ch.body)['name'] as String? ?? channelId;
  stdout.writeln('[channel] $channelName');

  // 3. fanet1 envelope: fresh sender identity, channel pubkey from the
  //    invite fragment / wallet.
  final sender = await _x25519.newKeyPair();
  final senderPub = await sender.extractPublicKey();
  final frameId = _uuid4();
  final shared = await _x25519.sharedSecretKey(
      keyPair: sender, remotePublicKey: SimplePublicKey(
          base64Decode(channelKeys['pub'] as String),
          type: KeyPairType.x25519));
  final ikm = await shared.extractBytes();
  final key = await _hkdf(
      ikm: ikm,
      salt: utf8.encode(frameId),
      info: utf8.encode('dap1/v1'),
      length: 32);
  final nonce =
      Uint8List.fromList(List.generate(12, (_) => _rng.nextInt(256)));
  final box = await _aead.encrypt(utf8.encode(text),
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode('dap1|$frameId|$channelName'));
  final payload = base64Encode([
    1, ...senderPub.bytes, ...nonce, ...box.cipherText, ...box.mac.bytes,
  ]);

  // 4. Relay-accept.
  final sent = await http.post(
    Uri.parse('$base/api/channels/$channelId/messages'),
    headers: auth,
    body: jsonEncode({
      'id': frameId,
      'payload': payload,
      'senderKey': base64Encode(senderPub.bytes),
    }),
  );
  stdout.writeln('[send] ${sent.statusCode} ${sent.body.substring(0, sent.body.length.clamp(0, 160))}');
  if (sent.statusCode != 202) exitCode = 1;
}
