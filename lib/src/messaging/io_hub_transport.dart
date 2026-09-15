/// `dart:io`-backed bindings for the hub messaging fabric (issue #402,
/// phase 27.1): the WebSocket [HubTransport] and a file-backed identity
/// store, so the app agent keeps the same hub address across restarts.
///
/// **This library is not web-safe.** It is exported only from
/// `lib/io.dart`; the pure core (`hub_messaging_repository.dart`) never
/// imports it — hosts inject a transport through the [HubTransport] seam.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'hub_identity.dart';
import 'hub_transport.dart';

/// A [HubTransport] over a `dart:io` WebSocket.
final class IoHubTransport implements HubTransport {
  const IoHubTransport();

  @override
  Future<HubSocket> connect(Uri url) async {
    final ws = await WebSocket.connect(url.toString());
    return IoHubSocket(ws);
  }
}

/// One live hub connection over a `dart:io` WebSocket. Binary frames are
/// dropped at the boundary (the hub speaks text frames only and answers
/// them with a `bad_frame` error).
final class IoHubSocket implements HubSocket {
  IoHubSocket(this._ws);

  final WebSocket _ws;

  @override
  Stream<String> get messages =>
      _ws.where((frame) => frame is String).cast<String>().asBroadcastStream();

  @override
  bool get isOpen => _ws.readyState == WebSocket.open;

  @override
  Future<void> send(String text) async {
    _ws.add(text);
  }

  @override
  Future<void> close() => _ws.close();
}

/// Loads the hub identity persisted at [path], creating it (mode 0600,
/// atomic temp+rename) on first use. File format — the SAME lines the
/// CLI's `fa_hub_client` key files use — so a host may share one identity
/// across surfaces when it wants to:
/// `ed25519:<seed b64>`, `x25519:<priv b64>`, `x25519pub:<pub b64>`.
/// The pub line is informational; keys are always re-derived from the
/// private scalars, so a torn legacy write can never pair a mismatched pub.
Future<HubIdentity> loadHubIdentity(String path) async {
  final file = File(path);
  if (await file.exists()) {
    final fields = <String, String>{};
    for (final line in await file.readAsString().then((c) => c.split('\n'))) {
      final idx = line.indexOf(':');
      if (idx > 0) fields[line.substring(0, idx)] = line.substring(idx + 1);
    }
    final edSeed = fields['ed25519'];
    final xPriv = fields['x25519'];
    if (edSeed != null && xPriv != null) {
      try {
        return await HubIdentity.fromSeeds(
          ed25519Seed: base64Decode(edSeed),
          x25519Private: base64Decode(xPriv),
        );
      } on Object {
        // A torn or corrupt file falls through to regeneration: a fresh
        // address beats an unusable fabric; save overwrites the file.
      }
    }
  }
  final identity = await HubIdentity.fromSeeds(
    ed25519Seed: _randomBytes(32),
    x25519Private: _randomBytes(32),
  );
  final signingSeed = await identity.signingKeyPair.extractPrivateKeyBytes();
  final dhPriv = await identity.dhKeyPair.extractPrivateKeyBytes();
  await File(path).parent.create(recursive: true);
  // Atomic create via temp + rename: a crashed direct write could tear the
  // file mid-line and break every later load.
  final tmp = File('$path.tmp');
  await tmp.writeAsString(
    'ed25519:${base64Encode(signingSeed)}\n'
    'x25519:${base64Encode(dhPriv)}\n'
    'x25519pub:${identity.dhPubkeyB64}\n',
    flush: true,
  );
  await tmp.rename(path);
  if (!await _chmod600(path)) {
    stderr.writeln(
      '[hub] warning: identity file $path was NOT locked to mode 0600 — '
      'the private keys may be readable by other local users',
    );
  }
  return identity;
}

Future<bool> _chmod600(String path) async {
  if (Platform.isWindows) return false;
  try {
    final result = await Process.run('chmod', ['600', path]);
    return result.exitCode == 0;
  } on Object {
    return false;
  }
}

final _random = Random.secure();

List<int> _randomBytes(int count) =>
    List<int>.generate(count, (_) => _random.nextInt(256));

/// Saves [identity]'s seeds to [path] (the host's rotation/rebind path).
Future<void> saveHubIdentity(String path, HubIdentity identity) async {
  final signingSeed = await identity.signingKeyPair.extractPrivateKeyBytes();
  final dhPriv = await identity.dhKeyPair.extractPrivateKeyBytes();
  await File(path).parent.create(recursive: true);
  await File(path).writeAsString(
    'ed25519:${base64Encode(signingSeed)}\n'
    'x25519:${base64Encode(dhPriv)}\n',
    flush: true,
  );
  await _chmod600(path);
}
