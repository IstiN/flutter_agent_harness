// In-memory Office.js fake (FakeOfficeContext) — the mock-first test seam
// of issue #89 (AC10): everything exercisable against a mocked Office
// global MUST be automated, so the fake carries the full item lifecycle —
// ready-gate, read/compose modes, attachment bytes, compose body surface,
// item switching — and nothing here is web-only. The js_interop adapter
// (office_api_js.dart) mirrors these semantics against the real global.
library;

import 'dart:async';
import 'dart:convert';

import 'office_api.dart';

/// One attachment staged in the fake.
final class FakeAttachment {
  FakeAttachment(this.name, List<int> bytes, {this.contentType = 'text/plain'})
    : bytes = List<int>.unmodifiable(bytes);

  final String name;
  final List<int> bytes;
  final String contentType;

  int get size => bytes.length;
}

/// Controls [FakeOfficeContext] readiness: tests hold the completer and
/// fire it to simulate `Office.onReady` — before it completes the facade
/// is NOT ready and every tool answers the clean `not_ready` note (AC2
/// negative path).
final class FakeOfficeReady {
  final _completer = Completer<void>();

  /// Completes the facade's `onReady` future (the host boots only after).
  void fire() {
    if (!_completer.isCompleted) _completer.complete();
  }

  Future<void> get future => _completer.future;
}

final class FakeOfficeContext implements OfficeApi {
  FakeOfficeContext({this.host = OfficeHostId.outlook})
    : ready = FakeOfficeReady();

  @override
  final OfficeHostId host;
  final FakeOfficeReady ready;

  /// Set when the CDN-less environment can never reach Office.js (E5):
  /// `onReady` resolves with [officeUnavailable] instead of ever firing.
  bool officeUnavailable = false;

  bool _fired = false;

  /// The open item. Null = the taskpane runs on a non-mail view.
  MailItemSnapshot? item;

  /// Body text of the open item (attacker-controlled in tests).
  String bodyText = '';

  /// Attachments of the open item, name → staged bytes.
  final Map<String, FakeAttachment> attachments = {};

  /// The compose surface. Null in read mode; in compose the fake tracks
  /// the draft body so tests assert what the agent inserted.
  StringBuffer? composeBody;

  final _itemChanges = StreamController<MailItemSnapshot?>.broadcast();

  @override
  bool get isReady => _fired;

  @override
  Future<void> onReady() async {
    if (officeUnavailable) {
      throw OfficeApiException(
        'office_unavailable',
        'Office.js failed to load (the CDN is unreachable)',
      );
    }
    await ready.future;
    _fired = true;
  }

  void _requireReady() {
    if (!_fired) {
      throw OfficeApiException(
        'not_ready',
        'host not ready — Office.onReady has not fired',
      );
    }
  }

  @override
  MailItemSnapshot? get currentItem {
    _requireReady();
    return item;
  }

  @override
  Future<String> readItemBodyText() async {
    _requireReady();
    if (item == null) {
      throw OfficeApiException('no_item', 'no mail item is open');
    }
    return bodyText;
  }

  @override
  Future<AttachmentContent> readAttachment(String name) async {
    _requireReady();
    if (item == null) {
      throw OfficeApiException('no_item', 'no mail item is open');
    }
    final attachment = attachments[name];
    if (attachment == null) {
      throw OfficeApiException('no_attachment', 'no attachment named "$name"');
    }
    if (attachment.size > maxAttachmentBytes) {
      throw OfficeApiException(
        'attachment_too_large',
        'attachment "$name" is ${attachment.size} bytes — over the '
            '$maxAttachmentBytes-byte cap; refused',
      );
    }
    return AttachmentContent(
      name: attachment.name,
      base64: base64Encode(attachment.bytes),
      size: attachment.size,
    );
  }

  @override
  Future<void> insertDraftBody(String text) async {
    _requireReady();
    final draft = composeBody;
    if (item == null || draft == null || item!.mode != ItemMode.compose) {
      throw OfficeApiException(
        'read_mode',
        'insert_draft_body requires an open compose draft (current surface '
            'is ${item == null ? 'no item' : 'read mode'})',
      );
    }
    draft
      ..clear()
      ..write(text);
  }

  @override
  Stream<MailItemSnapshot?> get onItemChanged => _itemChanges.stream;

  /// Test hook: switch the open item (E1) — updates the snapshot, mode and
  /// attachments together and notifies [onItemChanged].
  void switchItem({
    required MailItemSnapshot snapshot,
    String body = '',
    Map<String, FakeAttachment> attachments = const {},
    StringBuffer? composeBody,
  }) {
    _requireReady();
    item = snapshot;
    bodyText = body;
    this.attachments
      ..clear()
      ..addAll(attachments);
    this.composeBody = composeBody;
    _itemChanges.add(snapshot);
  }

  /// Test hook: fires ready AND opens the initial item in one call.
  void openItem({
    required MailItemSnapshot snapshot,
    String body = '',
    Map<String, FakeAttachment> attachments = const {},
    StringBuffer? composeBody,
  }) {
    ready.fire();
    switchItem(
      snapshot: snapshot,
      body: body,
      attachments: attachments,
      composeBody: composeBody,
    );
  }
}

/// Convenience builder for a read-mode message snapshot.
MailItemSnapshot fakeMessage({
  String itemId = 'AAMkITEM',
  String subject = 'Hello',
  String from = 'sender@example.com',
  List<String> to = const ['me@example.com'],
  List<String> cc = const [],
  String receivedTimeIso = '2026-09-09T10:00:00Z',
  List<AttachmentInfo> attachments = const [],
  String itemClass = 'IPM.Note',
}) => MailItemSnapshot(
  itemId: itemId,
  mode: ItemMode.read,
  itemType: 'message',
  itemClass: itemClass,
  subject: subject,
  from: from,
  to: to,
  cc: cc,
  receivedTimeIso: receivedTimeIso,
  attachments: attachments,
);

/// Convenience builder for a compose-mode draft snapshot.
MailItemSnapshot fakeDraft({
  String itemId = 'AAMkDRAFT',
  String subject = 'Draft',
  String itemClass = 'IPM.Note',
  List<AttachmentInfo> attachments = const [],
}) => MailItemSnapshot(
  itemId: itemId,
  mode: ItemMode.compose,
  itemType: 'message',
  itemClass: itemClass,
  subject: subject,
  from: 'me@example.com',
  to: const [],
  cc: const [],
  receivedTimeIso: '2026-09-09T10:00:00Z',
  attachments: attachments,
);
