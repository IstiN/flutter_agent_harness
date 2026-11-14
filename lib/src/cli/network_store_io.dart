// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// `~/.fah/network/` credential storage (Unix mode 0700 directory, 0600
/// files):
/// - `account.json`: access JWT, optional refresh token and absolute expiries;
/// - `device.json`: deviceId/deviceToken/personalNetworkId, host metadata,
///   and per-agent-address X25519 DM private seeds.
/// Writes use a sibling temporary file + rename, and no content is logged.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../network/network_account.dart';
import 'network_store.dart';

/// File-backed [NetworkCredentialStore] rooted at `<home>/.fah/network`.
final class FileNetworkCredentialStore implements NetworkCredentialStore {
  /// Builds a store below [homeDirectory].
  FileNetworkCredentialStore(String homeDirectory)
    : directory = Directory('$homeDirectory/.fah/network');

  /// The credential directory. Tests inject a temporary home.
  final Directory directory;

  File get _account => File('${directory.path}/account.json');
  File get _device => File('${directory.path}/device.json');

  @override
  Future<NetworkAccount?> readAccount() async {
    final json = await _read(_account);
    return json == null ? null : NetworkAccount.fromJson(json);
  }

  @override
  Future<NetworkDeviceCredentials?> readDevice() async {
    final json = await _read(_device);
    return json == null ? null : NetworkDeviceCredentials.fromJson(json);
  }

  @override
  Future<void> writeAccount(NetworkAccount account) =>
      _write(_account, account.toJson());

  @override
  Future<void> writeDevice(NetworkDeviceCredentials device) =>
      _write(_device, device.toJson());

  @override
  Future<Map<String, String>> readDmPrivateKeys() async =>
      Map.of((await readDevice())?.dmPrivateKeys ?? const {});

  @override
  Future<void> writeDmPrivateKeys(Map<String, String> keys) async {
    final current = await readDevice();
    if (current == null) throw StateError('device not enrolled');
    await writeDevice(current.withDmPrivateKeys(keys));
  }

  @override
  Future<void> clearDevice() => _delete(_device);

  @override
  Future<void> clear() async {
    await Future.wait([_delete(_account), _delete(_device)]);
  }

  Future<Object?> _read(File file) async {
    try {
      return jsonDecode(await file.readAsString());
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  Future<void> _write(File file, Map<String, Object?> json) async {
    await directory.create(recursive: true);
    await _bestEffortMode(directory, 0x1C0); // 0700
    final temporary = File('${file.path}.$pid.tmp');
    try {
      await temporary.writeAsString(jsonEncode(json), flush: true);
      await _bestEffortMode(temporary, 0x180); // 0600
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        // Windows does not replace an existing rename target. POSIX keeps
        // the atomic path above; this fallback still never writes secrets
        // through a non-0600 destination file.
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
      }
      await _bestEffortMode(file, 0x180);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 2) rethrow;
    }
  }

  Future<void> _bestEffortMode(FileSystemEntity entity, int mode) async {
    if (Platform.isWindows) return;
    try {
      if (entity is File) {
        await Process.run('chmod', [mode.toRadixString(8), entity.path]);
      } else if (entity is Directory) {
        await Process.run('chmod', [mode.toRadixString(8), entity.path]);
      }
    } on Object {
      // Filesystems without POSIX modes still get atomic writes; do not make
      // login unavailable there. No command output (which could name paths
      // in scripts) is surfaced as a credential diagnostic.
    }
  }
}
