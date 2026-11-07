// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Loads a persisted store file: JSON at `<cwd>/[fileName]` shaped
/// `{"version": [version], "[payloadKey]": {...}}`. Runs [decode] with the
/// payload map only when the env is present, the file readable, the JSON a
/// version-matched map, and the payload a map — every other outcome
/// (missing env, absent file, corrupt or incompatible payload, a throwing
/// [decode]) is swallowed so a bad file never crashes boot; the store
/// simply keeps whatever state it already had. The shared reader behind
/// the session/media/key stores.
Future<void> faLoadVersionedStore(
  ExecutionEnv? env, {
  required String fileName,
  required int version,
  required String payloadKey,
  required void Function(ExecutionEnv env, Map payload) decode,
}) async {
  final loadEnv = env;
  if (loadEnv == null) return;
  try {
    final text = (await loadEnv.readTextFile(
      '${loadEnv.cwd}/$fileName',
    )).valueOrNull;
    if (text == null) return;
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return;
    if (decoded['version'] != version) return;
    final payload = decoded[payloadKey];
    if (payload is! Map) return;
    decode(loadEnv, payload);
  } on Object {
    // Corrupt or incompatible file → keep the current state, never crash.
  }
}
