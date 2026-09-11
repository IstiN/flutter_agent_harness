// The REAL Office.js adapter for the typed [OfficeApi] facade (issue #89):
// the Outlook twin of chrome_api_js.dart. Property walks and calls resolve
// through guaranteed JS built-ins (Reflect.get / Reflect.apply — the base
// SDK ships no unsafe JSObject extension), async Office calls ride the
// callback convention (`X.getAsync(args, cb)` → AsyncResult {status,
// value, error}) bridged to Completers, and every crossing dartifies to
// plain Dart LEAF BY LEAF before the typed record constructors see it
// (dartify-ing the whole `item` would trip over its method properties).
//
// THIS FILE + office_main.dart are the only places dart:js_interop may
// appear (hard rule); it is never imported by tests — the fake
// (fake_office.dart) pins the semantics on the VM.
//
// Error discipline (office_api.dart contract): Office failures NEVER
// surface raw. Every failure crosses this facade as OfficeApiException
// with the stable code vocabulary; a missing Office global or a hung
// `Office.onReady` (60s race) is 'office_unavailable'.
library;

import 'dart:async';
import 'dart:js_interop';

import 'office_api.dart';

@JS('Reflect.get')
external JSAny? _getProperty(JSObject target, JSAny? key);

@JS('Reflect.apply')
external JSAny? _applyFn(JSFunction fn, JSAny? thisArg, JSArray args);

@JS('Office.onReady')
external JSPromise<JSAny?> _officeOnReady(JSAny? info);

@JS('Office')
external JSObject? get _officeRoot;

/// `Office.onReady` race ceiling: a CDN-less page must not boot-loop
/// forever — after this the facade reports 'office_unavailable'.
const _readyTimeout = Duration(seconds: 60);

JSAny? _prop(JSObject obj, String name) => _getProperty(obj, name.toJS);

JSObject? _obj(JSAny? value) =>
    value.isA<JSObject>() ? value as JSObject : null;

JSFunction? _fn(JSAny? value) =>
    value.isA<JSFunction>() ? value as JSFunction : null;

String _s(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

int _i(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

/// Dartifies a property leaf (string, num, bool, plain object/array,
/// Date) — safe on values Office hands over as data.
Object? _leaf(JSObject obj, String name) => _prop(obj, name)?.dartify();

/// Calls `target.<method>(…args, callback)` and completes with the
/// AsyncResult VALUE on `status == 'succeeded'`; any other status (or a
/// missing surface) is an [OfficeApiException].
Future<Object?> _invokeAsyncResult(
  JSObject target,
  String method,
  List<JSAny?> args,
) {
  final fn = _fn(_prop(target, method));
  if (fn == null) {
    return Future.error(
      OfficeApiException(
        'office_unavailable',
        'Office.js surface $method is not available',
      ),
    );
  }
  final completer = Completer<Object?>();
  void callback(JSAny? result) {
    if (completer.isCompleted) return;
    final asyncResult = result?.dartify();
    final map = asyncResult is Map ? asyncResult : const <Object?, Object?>{};
    if (_s(map['status']) == 'succeeded') {
      completer.complete(map['value']);
      return;
    }
    final error = map['error'];
    final message = error is Map ? _s(error['message']) : '';
    completer.completeError(
      OfficeApiException(
        'office_unavailable',
        message.isEmpty ? '$method failed' : message,
      ),
    );
  }

  _applyFn(fn, target, [...args, callback.toJS].toJS);
  return completer.future;
}

/// The production [OfficeApi]: binds the real Office global through the
/// generic resolver above. The constructor never throws — a missing Office
/// global surfaces through [onReady] as 'office_unavailable'.
final class JsOfficeApi implements OfficeApi {
  Future<void>? _readyFuture;
  bool _readyFired = false;
  String? _hostName;
  late final _changes = StreamController<MailItemSnapshot?>.broadcast(
    onListen: _attachItemChangeHandler,
  );
  bool _handlerAttached = false;

  @override
  bool get isReady => _readyFired;

  @override
  OfficeHostId get host => officeHostFromName(_hostName);

  @override
  Future<void> onReady() => _readyFuture ??= _doOnReady();

  Future<void> _doOnReady() async {
    if (_officeRoot == null) {
      throw OfficeApiException(
        'office_unavailable',
        'Office.js failed to load',
      );
    }
    Object? info;
    try {
      info = (await _officeOnReady(
        null,
      ).toDart.timeout(_readyTimeout)).dartify();
    } on TimeoutException {
      throw OfficeApiException(
        'office_unavailable',
        'Office.js failed to load',
      );
    }
    _hostName = info is Map ? _s(info['host']) : null;
    _readyFired = true;
  }

  void _requireReady() {
    if (!_readyFired) {
      throw OfficeApiException(
        'not_ready',
        'host not ready — Office.onReady has not fired yet',
      );
    }
  }

  JSObject? get _item {
    final root = _officeRoot;
    if (root == null) return null;
    final mailbox = _obj(
      _prop(_obj(_prop(root, 'context')) ?? root, 'mailbox'),
    );
    return mailbox == null ? null : _obj(_prop(mailbox, 'item'));
  }

  /// Compose vs read: in compose `item.subject` is an object (with
  /// getAsync), in read it is a plain string.
  bool _isCompose(JSObject item) => _obj(_prop(item, 'subject')) != null;

  @override
  MailItemSnapshot? get currentItem {
    _requireReady();
    final item = _item;
    return item == null ? null : _snapshotOf(item);
  }

  MailItemSnapshot _snapshotOf(JSObject item) {
    final compose = _isCompose(item);
    final fromObj = compose ? null : _obj(_prop(item, 'from'));
    final from = fromObj == null
        ? ''
        : _s(_leaf(fromObj, 'emailAddress'), _s(_leaf(fromObj, 'displayName')));
    return MailItemSnapshot(
      itemId: _s(_leaf(item, 'itemId')),
      mode: compose ? ItemMode.compose : ItemMode.read,
      itemType: _s(_leaf(item, 'itemType')),
      itemClass: _s(_leaf(item, 'itemClass')),
      subject: compose ? '' : _s(_leaf(item, 'subject')),
      from: from,
      to: _recipients(_leaf(item, 'toRecipients')),
      cc: _recipients(_leaf(item, 'ccRecipients')),
      receivedTimeIso: _dateIso(_leaf(item, 'dateTimeCreated')),
      attachments: [
        for (final a in ((_leaf(item, 'attachments') as List?) ?? const []))
          if (a is Map)
            AttachmentInfo(
              name: _s(a['name']),
              size: _i(a['size']),
              contentType: _s(a['contentType']),
            ),
      ],
    );
  }

  static List<String> _recipients(Object? raw) => [
    if (raw is List)
      for (final r in raw)
        if (r is Map) _s(r['emailAddress'], _s(r['displayName'])),
  ];

  /// Office hands `dateTimeCreated` over as a JS Date (dartify → DateTime)
  /// or an ISO string, depending on the bridge — accept both.
  static String _dateIso(Object? raw) => switch (raw) {
    final DateTime dt => dt.toIso8601String(),
    final String s => s,
    _ => '',
  };

  @override
  Future<String> readItemBodyText() async {
    _requireReady();
    final item = _item;
    if (item == null) {
      throw OfficeApiException('no_item', 'no mail item is open');
    }
    final body = _obj(_prop(item, 'body'));
    if (body == null) {
      throw OfficeApiException('no_item', 'the open item has no body surface');
    }
    return _s(await _invokeAsyncResult(body, 'getAsync', ['text'.toJS]));
  }

  @override
  Future<AttachmentContent> readAttachment(String name) async {
    _requireReady();
    final item = _item;
    if (item == null) {
      throw OfficeApiException('no_item', 'no mail item is open');
    }
    final entries =
        (await _invokeAsyncResult(item, 'getAttachmentsAsync', const []))
            as List? ??
        const [];
    Map<Object?, Object?>? match;
    for (final entry in entries) {
      if (entry is Map && entry['name'] == name) {
        match = entry;
        break;
      }
    }
    if (match == null) {
      throw OfficeApiException('no_attachment', 'no attachment named "$name"');
    }
    final size = _i(match['size']);
    if (size > maxAttachmentBytes) {
      throw OfficeApiException(
        'attachment_too_large',
        'attachment "$name" is $size bytes — over the '
            '$maxAttachmentBytes-byte cap; refused',
      );
    }
    final content = await _invokeAsyncResult(
      item,
      'getAttachmentContentAsync',
      [_s(match['id']).toJS],
    );
    final contentMap = content is Map ? content : const <Object?, Object?>{};
    final base64 = _s(contentMap['content']);
    final format = _s(contentMap['format']);
    if (format != 'base64' || base64.isEmpty) {
      throw OfficeApiException(
        'office_unavailable',
        'attachment "$name" content unavailable (format: '
            '${format.isEmpty ? 'unknown' : format})',
      );
    }
    return AttachmentContent(name: name, base64: base64, size: size);
  }

  @override
  Future<void> insertDraftBody(String text) async {
    _requireReady();
    final item = _item;
    if (item == null || !_isCompose(item)) {
      throw OfficeApiException(
        'read_mode',
        'insert_draft_body requires an open compose draft (current surface '
            'is ${item == null ? 'no item' : 'read mode'})',
      );
    }
    final body = _obj(_prop(item, 'body'));
    if (body == null) {
      throw OfficeApiException('read_mode', 'the open draft has no body');
    }
    await _invokeAsyncResult(body, 'setAsync', [
      text.toJS,
      {'coercionType': 'text'}.jsify(),
    ]);
  }

  @override
  Stream<MailItemSnapshot?> get onItemChanged => _changes.stream;

  /// Attaches the real `itemNameChanged` listener once; every fire
  /// re-reads the snapshot (or null when the surface went away) and
  /// broadcasts it.
  void _attachItemChangeHandler() {
    if (_handlerAttached) return;
    final root = _officeRoot;
    final mailbox = root == null
        ? null
        : _obj(_prop(_obj(_prop(root, 'context')) ?? root, 'mailbox'));
    final addHandler = mailbox == null
        ? null
        : _fn(_prop(mailbox, 'addHandlerAsync'));
    if (addHandler == null) return;
    _handlerAttached = true;
    void handler() {
      MailItemSnapshot? snapshot;
      try {
        snapshot = currentItem;
      } on Object {
        snapshot = null; // mid-change reads fail: announce the loss
      }
      if (!_changes.isClosed) _changes.add(snapshot);
    }

    _applyFn(addHandler, mailbox, ['itemNameChanged'.toJS, handler.toJS].toJS);
  }
}
