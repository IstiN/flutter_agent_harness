// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'fa_network_client.dart';
import 'models.dart';

/// Public-channel payload codec (fa_network showcase contract): a public
/// channel has NO chankey — the payload is `base64(raw message)`. The app
/// convention wraps the text as JSON `{"text": …}`; foreign producers may
/// send raw utf8, so decoding tolerates both.
String encodePublicChannelText(String text) =>
    base64Encode(utf8.encode(jsonEncode({'text': text})));

/// Decodes a public-channel payload; null when undecodable (the UI
/// renders a placeholder, never crashes).
String? decodePublicChannelPayload(String payloadB64) {
  final String raw;
  try {
    raw = utf8.decode(base64Decode(payloadB64));
  } on Object {
    return null;
  }
  // The app convention wraps text as JSON {"text": …}; foreign producers
  // may send raw utf8 — both render.
  try {
    final asJson = jsonDecode(raw);
    if (asJson is Map && asJson['text'] is String) {
      return asJson['text'] as String;
    }
  } on Object {
    // Not JSON — plain text below.
  }
  return raw;
}

/// One showcase message (already decoded plaintext).
final class ShowcaseMessage {
  const ShowcaseMessage({
    required this.id,
    required this.senderId,
    required this.text,
    this.createdAt,
  });

  final String id;
  final String senderId;
  final String? text;
  final DateTime? createdAt;
}

/// Anonymous read-only viewer of a public network's showcase channels
/// (issue #955): no join, no wallet, no socket — REST pages only.
final class ShowcaseViewer extends ChangeNotifier {
  ShowcaseViewer({required this.networkId, required FaNetworkClient client})
    // ignore: prefer_initializing_formals — named param reads better
    : _client = client;

  final String networkId;
  final FaNetworkClient _client;

  Showcase? showcase;
  String? error;

  /// Messages per channel id (oldest-first), deduped by envelope id.
  final Map<String, List<ShowcaseMessage>> messages = {};
  final Map<String, String?> _cursors = {};
  final Set<String> _seen = {};
  bool loading = false;

  /// Loads the showcase listing; [showcase] stays null on the generic
  /// 404 (unknown or non-public network — no oracle by contract).
  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      showcase = await _client.getShowcase(networkId);
      if (showcase == null) error = 'unavailable';
    } on FaNetworkException catch (e) {
      error = e.message;
    }
    loading = false;
    notifyListeners();
  }

  /// Loads (the first or next) page of a showcase channel's history.
  Future<void> loadMessages(String channelId) async {
    try {
      final page = await _client.listMessages(
        channelId,
        cursor: _cursors[channelId],
        anonymous: true,
      );
      // Chat-order pagination: ascending pages; the first page is the
      // newest tail, older pages prepend as a block.
      final list = messages.putIfAbsent(channelId, () => []);
      final decoded = <ShowcaseMessage>[];
      for (final envelope in page.items) {
        if (!_seen.add(envelope.id)) continue;
        decoded.add(
          ShowcaseMessage(
            id: envelope.id,
            senderId: envelope.senderId,
            text: decodePublicChannelPayload(envelope.payload),
            createdAt: envelope.createdAt,
          ),
        );
      }
      list.insertAll(0, decoded);
      _cursors[channelId] = (page.nextCursor?.isEmpty ?? true)
          ? null
          : page.nextCursor;
    } on FaNetworkException catch (e) {
      error = e.message;
    }
    notifyListeners();
  }

  bool hasMore(String channelId) => _cursors[channelId] != null;
}
