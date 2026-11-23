import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

@JS('__fahCloudSessionLoad')
external JSPromise<JSObject?> _loadJs(String scopeKey);

@JS('__fahCloudSessionSave')
external JSPromise<JSObject> _saveJs(
  String scopeKey,
  int expectedRevision,
  String payloadJson,
);

/// Browser-persistent cloud-session outbox with cross-tab CAS protection.
final class IdbCloudSessionSyncStore implements CloudSessionSyncStore {
  @override
  Future<CloudSessionSnapshot> load(String scopeKey) async {
    final raw = (await _loadJs(scopeKey).toDart).dartify();
    if (raw == null) return CloudSessionSnapshot.empty(scopeKey);
    return _decode(raw);
  }

  @override
  Future<CloudSessionSnapshot> save(
    CloudSessionSnapshot snapshot, {
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
      if ('$error'.contains('CloudSessionStoreConcurrency')) {
        throw CloudSessionStoreConcurrencyException(snapshot.scopeKey);
      }
      rethrow;
    }
  }

  CloudSessionSnapshot _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('invalid IndexedDB cloud-session record');
    }
    final revision = raw['storageRevision'];
    if (revision is! num || revision < 1) {
      throw const FormatException('invalid cloud-session storage revision');
    }
    final payload = jsonDecode(raw['payloadJson']! as String);
    return CloudSessionSnapshot.fromPayload(
      (payload as Map).cast<String, Object?>(),
      storageRevision: revision.toInt(),
    );
  }
}
