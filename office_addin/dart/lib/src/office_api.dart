// Typed facade over the Office.js APIs the fa agent drives (issue #89):
// the exact analog of the extension's chrome_api.dart — one injectable
// interface plus JSON-able result records, so the outlook.* tools and the
// taskpane host run unchanged against real Office (office_api_js.dart,
// dart2js) or the in-memory fake (fake_office.dart). Pure Dart — dart2js
// compiles this file into the taskpane agent, so no dart:io and no
// js_interop here.
//
// Office failures NEVER surface raw: every error crosses this facade as
// OfficeApiException whose `code` is the stable machine vocabulary of the
// surface ('not_ready', 'no_item', 'read_mode', 'no_attachment',
// 'attachment_too_large', 'office_unavailable').
//
// Boot ordering (pinned platform fact): the agent host MUST NOT start
// before [OfficeApi.onReady] completes (an add-in that boots early hangs
// silently). Host detection rides [OfficeApi.host] — `Outlook` today;
// Word/Excel/PowerPoint are the reserved dispatch points of the second
// tier (the facade answers them with a clean note, never a crash).
library;

/// The Office hosts the bridge knows about. Outlook is the v1 adapter;
/// the rest exist so the dispatch seam is pinned from day one (AC7) —
/// every host loads a web taskpane + Office.js, only the document API
/// differs.
enum OfficeHostId { outlook, word, excel, powerPoint, other }

/// `Office.context.host` string → [OfficeHostId]. Unknown values fold into
/// [OfficeHostId.other] (a future host answers the not-implemented note
/// instead of crashing the seam).
OfficeHostId officeHostFromName(String? name) => switch (name) {
  'Outlook' => OfficeHostId.outlook,
  'Word' => OfficeHostId.word,
  'Excel' => OfficeHostId.excel,
  'PowerPoint' => OfficeHostId.powerPoint,
  _ => OfficeHostId.other,
};

/// The only error type this facade (and its fake) ever throws.
final class OfficeApiException implements Exception {
  OfficeApiException(this.code, this.message);

  /// Stable machine key: `not_ready`, `no_item`, `read_mode`,
  /// `no_attachment`, `attachment_too_large`, `office_unavailable`.
  final String code;
  final String message;

  @override
  String toString() => 'OfficeApiException($code): $message';
}

/// Whether the open item is a compose surface (draft being written) or a
/// read surface (reading pane / opened message). `insert_draft_body` only
/// exists in compose; read mode hard-errors (AC5).
enum ItemMode { read, compose }

/// One attachment of the current item — the LIST entry only carries
/// name/size/type (never content), minimizing attacker-controlled text
/// that enters context by default.
final class AttachmentInfo {
  const AttachmentInfo({
    required this.name,
    required this.size,
    required this.contentType,
  });

  final String name;
  final int size;
  final String contentType;

  Map<String, dynamic> toJson() => {
    'name': name,
    'size': size,
    'contentType': contentType,
  };
}

/// Base64 content of ONE attachment, fetched only after the per-file
/// approval (AC4).
final class AttachmentContent {
  const AttachmentContent({
    required this.name,
    required this.base64,
    required this.size,
  });

  final String name;
  final String base64;
  final int size;
}

/// JSON-able snapshot of the current mailbox item (subject, from/to/cc,
/// received time, meeting fields when the item is a meeting). The BODY is
/// deliberately not a field: it is attacker-controlled and enters context
/// only through the quarantine-wrapping tool call (Security, issue #89).
final class MailItemSnapshot {
  const MailItemSnapshot({
    required this.itemId,
    required this.mode,
    required this.itemType,
    required this.itemClass,
    required this.subject,
    required this.from,
    required this.to,
    required this.cc,
    required this.receivedTimeIso,
    required this.attachments,
    this.meetingStartIso,
    this.meetingEndIso,
    this.meetingLocation,
  });

  final String itemId;
  final ItemMode mode;

  /// Office.js itemType: `message`, `meetingRequest`, `appointment`, …
  final String itemType;

  /// Office.js itemClass distinguishes reply / new mail / meeting invite
  /// (E4): `IPM.Note`, `IPM.Note.Reply`, `IPM.Schedule.Meeting.Request`, …
  final String itemClass;
  final String subject;
  final String from;
  final List<String> to;
  final List<String> cc;
  final String receivedTimeIso;
  final List<AttachmentInfo> attachments;

  /// Meeting fields — set when the item is a meeting (read-only surface).
  final String? meetingStartIso;
  final String? meetingEndIso;
  final String? meetingLocation;

  bool get isMeeting =>
      itemType.toLowerCase().contains('meeting') || itemType == 'appointment';

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'mode': mode.name,
    'itemType': itemType,
    'itemClass': itemClass,
    'subject': subject,
    'from': from,
    'to': to,
    'cc': cc,
    'receivedTime': receivedTimeIso,
    'attachments': [for (final a in attachments) a.toJson()],
    if (meetingStartIso != null) 'meetingStart': meetingStartIso,
    if (meetingEndIso != null) 'meetingEnd': meetingEndIso,
    if (meetingLocation != null) 'meetingLocation': meetingLocation,
  };
}

/// The one injection point for every Office.js call the agent may make.
///
/// Tools take an [OfficeApi]; production wires the js_interop adapter,
/// tests wire `FakeOfficeContext` — nothing else ever touches the Office
/// global.
abstract interface class OfficeApi {
  /// Which Office host this taskpane runs in (Office.context.host).
  OfficeHostId get host;

  /// Whether `Office.onReady` has fired. Tools answer `not_ready` before
  /// it — never a crash (AC2 negative path).
  bool get isReady;

  /// Resolves when the host runtime is ready. The agent host awaits this
  /// BEFORE any boot step that could touch Office.context.
  Future<void> onReady();

  /// Snapshot of the open item, or null when no item is open (e.g. the
  /// taskpane runs on a non-mail view).
  MailItemSnapshot? get currentItem;

  /// Body of the current item coerced to plain text (HTML is excluded —
  /// injection surface; malformed HTML must never break the coercion, E2).
  Future<String> readItemBodyText();

  /// Base64 of one attachment by name. Errors: `no_attachment` (unknown
  /// name), `attachment_too_large` (over the 50 MB cap, E3).
  Future<AttachmentContent> readAttachment(String name);

  /// Insert/replace text in the CURRENT compose draft. Errors: `read_mode`
  /// (hard error outside compose, AC5).
  Future<void> insertDraftBody(String text);

  /// Fires when the user switches to another item while the taskpane is
  /// open (E1) — the context injector re-announces, a stale item never
  /// leaks into a draft.
  Stream<MailItemSnapshot?> get onItemChanged;
}

/// v1 attachment size ceiling (E3): a 50 MB attachment is refused with a
/// size note, never streamed into context.
const maxAttachmentBytes = 50 * 1024 * 1024;
