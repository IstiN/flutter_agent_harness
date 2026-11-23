import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

@JS('__fahDriveLoad')
external JSPromise<JSObject?> _loadJs(String scopeKey);

@JS('__fahDriveSave')
external JSPromise<JSObject> _saveJs(
  String scopeKey,
  int expectedRevision,
  String payloadJson,
);

/// IndexedDB compare-and-swap store shared by browser tabs. Remote providers
/// remain injected; this class only persists account-scoped sync metadata and
/// self-contained pending operations.
final class IdbDriveSyncStore implements DriveSyncStore {
  @override
  Future<DriveWorkspaceSnapshot> load(String scopeKey) async {
    final raw = (await _loadJs(scopeKey).toDart).dartify();
    if (raw == null) return DriveWorkspaceSnapshot.empty(scopeKey);
    return _decode(raw);
  }

  @override
  Future<DriveWorkspaceSnapshot> save(
    DriveWorkspaceSnapshot snapshot, {
    required int expectedStorageRevision,
  }) async {
    try {
      final raw = (await _saveJs(
        snapshot.scopeKey,
        expectedStorageRevision,
        jsonEncode(snapshot.payloadJson()),
      ).toDart).dartify();
      return _decode(raw);
    } catch (error) {
      if ('$error'.contains('DriveStoreConcurrency')) {
        throw DriveStoreConcurrencyException(snapshot.scopeKey);
      }
      rethrow;
    }
  }

  DriveWorkspaceSnapshot _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('invalid IndexedDB drive record');
    }
    final revision = raw['storageRevision'];
    if (revision is! num || revision < 1) {
      throw const FormatException('invalid drive storage revision');
    }
    final payload = jsonDecode(raw['payloadJson']! as String);
    return DriveWorkspaceSnapshot.fromPayload(
      (payload as Map).cast<String, Object?>(),
      storageRevision: revision.toInt(),
    );
  }
}
