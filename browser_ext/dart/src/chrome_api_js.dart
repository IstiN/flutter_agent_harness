// The REAL chrome.* adapter for the typed [ChromeApi] facade (issue #30):
// one generic js_interop bridge, not per-API glue. Method paths resolve by
// walking globalThis.chrome ('tabs.create' → chrome.tabs.create), calls go
// through Reflect.apply with jsified args, promise results await
// JSPromise.toDart (chrome SW APIs return promises at the manifest's
// minimum_chrome_version 116), and every crossing dartifies to plain Dart
// before the typed record constructors see it. Event streams attach the
// real chrome.<api>.<event>.addListener once per facade instance and
// buffer payloads until the first Dart listener shows up (the
// no-lost-clicks contract EntryPointHub relies on).
//
// THIS FILE + agent_main.dart are the only places dart:js_interop may
// appear (hard rule); it is never imported by tests — the gate is
// `dart compile js agent_main.dart`.
//
// Error discipline (chrome_api.dart contract): chrome failures NEVER
// surface raw. A rejected promise is inspected for the ops.js vocabulary
// ('no_tab', 'restricted_page', 'quota_exceeded', ...) and rethrown as
// ChromeApiException; a missing chrome.* surface is 'api_missing'.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'chrome_api.dart';

/// Same idiom as agent_main's Reflect.set bind: the base SDK ships no
/// unsafe JSObject extension, so property access and spread calls go
/// through guaranteed JS built-ins.
@JS('Reflect.get')
external JSAny? _getProperty(JSObject target, JSAny? key);

@JS('Reflect.apply')
external JSAny? _applyFn(JSFunction fn, JSAny? thisArg, JSArray args);

@JS('chrome')
external JSObject get _chromeRoot;

// ---------------------------------------------------------------------------
// Generic core — the ONE mechanism every facade rides on
// ---------------------------------------------------------------------------

JSAny? _prop(JSObject obj, String name) => _getProperty(obj, name.toJS);

Never _missing(String path) =>
    throw ChromeApiException('api_missing', 'chrome.$path is not available');

/// Resolves [path] to (namespaceObject, function). Any absent hop is
/// 'api_missing' — deterministic, never a silent no-op.
(JSObject, JSFunction) _resolve(String path) {
  var node = _chromeRoot;
  final parts = path.split('.');
  for (var i = 0; i < parts.length - 1; i++) {
    final next = _prop(node, parts[i]);
    if (next == null || !next.isA<JSObject>()) _missing(path);
    node = next as JSObject;
  }
  final leaf = _prop(node, parts.last);
  if (leaf == null || !leaf.isA<JSFunction>()) _missing(path);
  return (node, leaf as JSFunction);
}

/// Invokes `chrome.<path>`(…args) and awaits the promise (non-promise
/// returns — chrome.power, contextMenus — pass straight through).
Future<Object?> _invoke(String path, [List<Object?> args = const []]) async {
  final (self, fn) = _resolve(path);
  final raw = _applyFn(fn, self, args.jsify() as JSArray);
  if (raw == null || !raw.isA<JSPromise>()) return raw?.dartify();
  try {
    return (await (raw as JSPromise<JSAny?>).toDart)?.dartify();
  } on Object catch (error) {
    throw _chromeError(path, error);
  }
}

/// Fire-and-forget variant for callback-only chrome APIs (contextMenus
/// create/removeAll have no promise form at min_chrome_version 116); the
/// facade's Future completes immediately after the real call is made.
void _call(String path, [List<Object?> args = const []]) {
  final (self, fn) = _resolve(path);
  _applyFn(fn, self, args.jsify() as JSArray);
}

/// Maps a raw chrome failure onto the ops.js error vocabulary. Message
/// shapes mirror sw/ops.js injectError; anything unknown stays
/// 'chrome_error' with chrome's own text (never swallowed).
ChromeApiException _chromeError(String path, Object error) {
  // Rejected-promise payloads arrive as raw JS values; only the JS-typed
  // ones can be dartified into {name, message} maps.
  Object? dartified = error;
  // ignore: invalid_runtime_check_with_js_interop_types
  if (error is JSAny) {
    dartified = error.dartify();
  }
  var message = '$error';
  if (dartified is Map) {
    final candidate = dartified['message'];
    if (candidate != null) message = '$candidate';
  }
  final lower = message.toLowerCase();
  final code = switch (lower) {
    _
        when lower.contains('cannot access') ||
            lower.contains('cannot be scripted') ||
            lower.contains('cannot be edited') =>
      'restricted_page',
    _
        when lower.contains('no tab with id') ||
            lower.contains('tab was closed') ||
            lower.contains('cannot find') =>
      'no_tab',
    _ when lower.contains('quota') => 'quota_exceeded',
    _
        when lower.contains('navigated or closed') ||
            lower.contains('context destroyed') ||
            lower.contains('inspected target navigated') =>
      'execution_context_destroyed',
    _ when lower.contains('already attached') => 'already_attached',
    _ => 'chrome_error',
  };
  return ChromeApiException(code, 'chrome.$path: $message');
}

/// The one event-stream builder: attaches the real chrome listener at
/// stream construction, buffers payloads until the first Dart listener,
/// and replays them exactly once on listen (E24 no-lost-clicks).
/// [arity] MUST match the chrome event's real listener signature —
/// dart2js-converted closures dispatch on exact arity and throw when the
/// browser calls them with fewer arguments.
Stream<T> _eventStream<T extends Object?>(
  String path,
  int arity,
  T? Function(JSAny? a, JSAny? b, JSAny? c) unwrap,
) {
  final buffer = <T>[];
  final controller = StreamController<T>.broadcast();
  void deliver(JSAny? a, JSAny? b, JSAny? c) {
    final value = unwrap(a, b, c);
    if (value == null) return;
    if (controller.hasListener) {
      controller.add(value);
    } else {
      buffer.add(value);
    }
  }

  final listener = switch (arity) {
    1 => ((JSAny? a) => deliver(a, null, null)).toJS,
    2 => ((JSAny? a, JSAny? b) => deliver(a, b, null)).toJS,
    _ => ((JSAny? a, JSAny? b, JSAny? c) => deliver(a, b, c)).toJS,
  };
  final (self, fn) = _resolve('$path.addListener');
  _applyFn(fn, self, [listener].jsify() as JSArray);
  controller.onListen = () {
    if (buffer.isEmpty) return;
    final replay = List.of(buffer);
    buffer.clear();
    for (final value in replay) {
      controller.add(value);
    }
  };
  return controller.stream;
}

// ---------------------------------------------------------------------------
// dartify coercions + typed record mappers
// ---------------------------------------------------------------------------

Map<String, Object?> _m(Object? raw) =>
    raw is Map ? Map<String, Object?>.from(raw) : const {};

List<Map<String, Object?>> _maps(Object? raw) => [
  if (raw is List)
    for (final entry in raw)
      if (entry is Map) Map<String, Object?>.from(entry),
];

int? _i(Object? v) => v is num ? v.toInt() : null;
String _s(Object? v, [String fallback = '']) => v is String ? v : fallback;
bool _b(Object? v, [bool fallback = false]) => v is bool ? v : fallback;

Tab _tabOf(Object? raw) {
  final m = _m(raw);
  final groupId = _i(m['groupId']);
  return Tab(
    id: _i(m['id']) ?? -1,
    url: _s(m['url']),
    title: _s(m['title']),
    pinned: _b(m['pinned']),
    muted: _b(_m(m['mutedInfo'])['muted']),
    audible: _b(m['audible']),
    groupId: groupId == null || groupId == -1 ? null : groupId,
    windowId: _i(m['windowId']) ?? -1,
    active: _b(m['active']),
    favIconUrl: m['favIconUrl'] is String ? m['favIconUrl'] as String : null,
    discarded: _b(m['discarded']),
  );
}

BrowserWindow _windowOf(Object? raw) {
  final m = _m(raw);
  return BrowserWindow(
    id: _i(m['id']) ?? -1,
    type: _s(m['type'], 'normal'),
    state: _s(m['state'], 'normal'),
    focused: _b(m['focused']),
    left: _i(m['left']) ?? 0,
    top: _i(m['top']) ?? 0,
    width: _i(m['width']) ?? 0,
    height: _i(m['height']) ?? 0,
    incognito: _b(m['incognito']),
    tabIds: [
      for (final tab in _maps(m['tabs']))
        if (_i(tab['id']) != null) _i(tab['id'])!,
    ],
  );
}

TabGroup _tabGroupOf(Object? raw) {
  final m = _m(raw);
  return TabGroup(
    id: _i(m['id']) ?? -1,
    title: _s(m['title']),
    color: _s(m['color']),
    windowId: _i(m['windowId']) ?? -1,
  );
}

ClosedSession _closedSessionOf(Object? raw) {
  final m = _m(raw);
  final tab = m['tab'] == null ? null : _tabOf(m['tab']);
  final window = m['window'] == null ? null : _windowOf(m['window']);
  return ClosedSession(
    sessionId: _s(_m(m['tab'])['sessionId'], _s(_m(m['window'])['sessionId'])),
    tab: tab,
    window: window,
    lastModified: _i(m['lastModified']) ?? 0,
  );
}

RestoredSession _restoredSessionOf(Object? raw) {
  final m = _m(raw);
  return RestoredSession(
    tab: m['tab'] == null ? null : _tabOf(m['tab']),
    window: m['window'] == null ? null : _windowOf(m['window']),
  );
}

HistoryItem _historyItemOf(Object? raw) {
  final m = _m(raw);
  return HistoryItem(
    id: _s(m['id']),
    url: _s(m['url']),
    title: _s(m['title']),
    lastVisitTs: _i(m['lastVisitTime']) ?? 0,
  );
}

BookmarkNode _bookmarkNodeOf(Object? raw) {
  final m = _m(raw);
  return BookmarkNode(
    id: _s(m['id']),
    title: _s(m['title']),
    url: m['url'] is String ? m['url'] as String : null,
    children: [
      for (final child in _maps(m['children'])) _bookmarkNodeOf(child),
    ],
  );
}

DownloadItem _downloadItemOf(Object? raw) {
  final m = _m(raw);
  return DownloadItem(
    id: _i(m['id']) ?? -1,
    url: _s(m['url']),
    filename: _s(m['filename']),
    state: _s(m['state']),
    paused: _b(m['paused']),
  );
}

Cookie? _cookieOf(Object? raw) {
  final m = _m(raw);
  if (m.isEmpty) return null;
  return Cookie(
    name: _s(m['name']),
    value: _s(m['value']),
    domain: _s(m['domain']),
    path: _s(m['path'], '/'),
    secure: _b(m['secure']),
    httpOnly: _b(m['httpOnly']),
    expirationDate: _i(m['expirationDate']),
  );
}

Alarm _alarmOf(Object? raw) {
  final m = _m(raw);
  return Alarm(name: _s(m['name']), scheduledTs: _i(m['scheduledTime']) ?? 0);
}

MenuClick _menuClickOf(JSAny? info, JSAny? tab) {
  final m = _m(info?.dartify());
  return MenuClick(
    menuItemId: _s(m['menuItemId']),
    selectionText: m['selectionText'] is String
        ? m['selectionText'] as String
        : null,
    linkUrl: m['linkUrl'] is String ? m['linkUrl'] as String : null,
    srcUrl: m['srcUrl'] is String ? m['srcUrl'] as String : null,
    pageUrl: m['pageUrl'] is String ? m['pageUrl'] as String : null,
    tab: tab == null ? null : _tabOf(tab.dartify()),
  );
}

NavCompleted _navCompletedOf(Object? raw) {
  final m = _m(raw);
  return NavCompleted(
    tabId: _i(m['tabId']) ?? -1,
    url: _s(m['url']),
    frameId: _i(m['frameId']) ?? 0,
  );
}

CpuInfo _cpuInfoOf(Object? raw) {
  final m = _m(raw);
  return CpuInfo(
    arch: _s(m['arch']),
    numProcessors: _i(m['numProcessors']) ?? 0,
    modelName: _s(m['modelName']),
  );
}

MemoryInfo _memoryInfoOf(Object? raw) {
  final m = _m(raw);
  return MemoryInfo(
    capacity: _i(m['capacity']) ?? 0,
    availableCapacity: _i(m['availableCapacity']) ?? 0,
  );
}

StorageInfo _storageInfoOf(Object? raw) => StorageInfo(
  units: [
    for (final unit in _maps(raw))
      StorageUnit(
        id: _s(unit['id']),
        name: _s(unit['name']),
        type: _s(unit['type']),
        capacity: _i(unit['capacity']) ?? 0,
      ),
  ],
);

DisplayInfo _displayInfoOf(Object? raw) {
  final units = _maps(raw);
  final primary =
      units.where((u) => _b(u['primary'])).firstOrNull ??
      (units.isNotEmpty ? units.first : const <String, Object?>{});
  return DisplayInfo(
    id: _s(primary['id']),
    name: _s(primary['name']),
    width: _i(primary['width']) ?? 0,
    height: _i(primary['height']) ?? 0,
    primary: _b(primary['primary']),
  );
}

// ---------------------------------------------------------------------------
// Sub-facade implementations — method → chrome path table inline
// ---------------------------------------------------------------------------

final class _Tabs implements TabsApi {
  @override
  Future<Tab> create({String? url, bool? active, int? index, bool? pinned}) =>
      _invoke('tabs.create', [
        {'url': ?url, 'active': ?active, 'index': ?index, 'pinned': ?pinned},
      ]).then(_tabOf);

  @override
  Future<Tab> get(int id) => _invoke('tabs.get', [id]).then(_tabOf);

  @override
  Future<Tab> update(
    int id, {
    String? url,
    bool? active,
    bool? pinned,
    bool? muted,
  }) => _invoke('tabs.update', [
    id,
    {'url': ?url, 'active': ?active, 'pinned': ?pinned, 'muted': ?muted},
  ]).then(_tabOf);

  @override
  Future<List<Tab>> query({
    String? url,
    String? title,
    int? groupId,
    bool? pinned,
    bool? muted,
    bool? active,
    bool? currentWindow,
  }) => _invoke('tabs.query', [
    {
      'url': ?url,
      'title': ?title,
      'groupId': ?groupId,
      'pinned': ?pinned,
      'muted': ?muted,
      'active': ?active,
      'currentWindow': ?currentWindow,
    },
  ]).then((raw) => [for (final m in _maps(raw)) _tabOf(m)]);

  @override
  Future<void> close(int id) => _invoke('tabs.remove', [id]);

  @override
  Future<Tab> duplicate(int id) => _invoke('tabs.duplicate', [id]).then(_tabOf);

  @override
  Future<Tab> reload(int id, {bool bypassCache = false}) async {
    await _invoke('tabs.reload', [
      id,
      {'bypassCache': bypassCache},
    ]);
    // The reload promise resolves undefined on some chrome versions; the
    // follow-up get is the honest tab snapshot either way.
    return _tabOf(await _invoke('tabs.get', [id]));
  }

  @override
  Future<Tab> move(int id, {required int index, int? windowId}) =>
      _invoke('tabs.move', [
        id,
        {'index': index, 'windowId': ?windowId},
      ]).then(_tabOf);

  @override
  Future<int> group({
    required List<int> tabIds,
    int? groupId,
    String? title,
    String? color,
  }) async {
    final id = _i(
      await _invoke('tabs.group', [
        {'tabIds': tabIds, 'groupId': ?groupId},
      ]),
    );
    if (id == null) {
      throw ChromeApiException(
        'chrome_error',
        'chrome.tabs.group returned no group id',
      );
    }
    if (title != null || color != null) {
      await _invoke('tabGroups.update', [
        id,
        {'title': ?title, 'color': ?color},
      ]);
    }
    return id;
  }

  @override
  Future<void> ungroup(List<int> tabIds) => _invoke('tabs.ungroup', [tabIds]);

  @override
  Future<Tab> discard(int id) => _invoke('tabs.discard', [id]).then(_tabOf);

  @override
  Stream<Tab> get onCreated =>
      _eventStream('tabs.onCreated', 1, (tab, _, _) => _tabOf(tab?.dartify()));

  @override
  Stream<TabRemoved> get onRemoved =>
      _eventStream('tabs.onRemoved', 2, (tabId, info, _) {
        final m = _m(info?.dartify());
        return TabRemoved(
          tabId: _i(tabId?.dartify()) ?? -1,
          windowId: _i(m['windowId']) ?? -1,
          isWindowClosing: _b(m['isWindowClosing']),
        );
      });

  @override
  Stream<TabUpdated> get onUpdated => _eventStream(
    'tabs.onUpdated',
    3,
    (tabId, changeInfo, _) => TabUpdated(
      tabId: _i(tabId?.dartify()) ?? -1,
      changeInfo: _m(changeInfo?.dartify()),
    ),
  );
}

final class _Windows implements WindowsApi {
  @override
  Future<BrowserWindow> create({
    String? url,
    String? type,
    String? state,
    int? width,
    int? height,
    int? left,
    int? top,
    bool? incognito,
  }) => _invoke('windows.create', [
    {
      'url': ?url,
      'type': ?type,
      'state': ?state,
      'width': ?width,
      'height': ?height,
      'left': ?left,
      'top': ?top,
      'incognito': ?incognito,
    },
  ]).then(_windowOf);

  @override
  Future<BrowserWindow> get(int id) => _invoke('windows.get', [
    id,
    const {'populate': true},
  ]).then(_windowOf);

  @override
  Future<List<BrowserWindow>> getAll() => _invoke('windows.getAll', [
    const {'populate': true},
  ]).then((raw) => [for (final m in _maps(raw)) _windowOf(m)]);

  @override
  Future<BrowserWindow> update(
    int id, {
    String? state,
    bool? focused,
    int? left,
    int? top,
    int? width,
    int? height,
  }) => _invoke('windows.update', [
    id,
    {
      'state': ?state,
      'focused': ?focused,
      'left': ?left,
      'top': ?top,
      'width': ?width,
      'height': ?height,
    },
  ]).then(_windowOf);

  @override
  Future<void> close(int id) => _invoke('windows.remove', [id]);
}

final class _Groups implements TabGroupsApi {
  @override
  Future<TabGroup> update(int groupId, {String? title, String? color}) =>
      _invoke('tabGroups.update', [
        groupId,
        {'title': ?title, 'color': ?color},
      ]).then(_tabGroupOf);

  @override
  Future<List<TabGroup>> query({String? title, String? color}) =>
      _invoke('tabGroups.query', [
        {'title': ?title, 'color': ?color},
      ]).then((raw) => [for (final m in _maps(raw)) _tabGroupOf(m)]);

  @override
  Future<void> close(int groupId) async {
    // tabGroups has no close: remove every member tab and the empty group
    // dissolves with it.
    final tabs = _maps(
      await _invoke('tabs.query', [
        {'groupId': groupId},
      ]),
    );
    final ids = [
      for (final tab in tabs)
        if (_i(tab['id']) != null) _i(tab['id'])!,
    ];
    if (ids.isNotEmpty) await _invoke('tabs.remove', [ids]);
  }
}

final class _Sessions implements SessionsApi {
  @override
  Future<List<ClosedSession>> getRecentlyClosed() => _invoke(
    'sessions.getRecentlyClosed',
  ).then((raw) => [for (final m in _maps(raw)) _closedSessionOf(m)]);

  @override
  Future<RestoredSession> restore(String sessionId) =>
      _invoke('sessions.restore', [sessionId]).then(_restoredSessionOf);
}

final class _Scripting implements ScriptingApi {
  @override
  Future<List<ScriptResult>> executeScript({
    required int tabId,
    String? world,
    bool? allFrames,
    List<int>? frameIds,
    required String funcSource,
    List<Object?>? args,
  }) async {
    // ponytail: code strings reach the page over the debugger channel —
    // MV3 CSP forbids building func objects with eval/new Function in the
    // SW, and chrome.scripting only accepts real function references. If
    // whole-frame fan-out ever matters, upgrade to per-frame targets.
    if (allFrames == true || (frameIds?.length ?? 0) > 1) {
      throw ChromeApiException(
        'bad_args',
        'executeScript evaluates one frame over the debugger channel',
      );
    }
    final frameId = frameIds?.firstOrNull ?? 0;
    final expression = (args == null || args.isEmpty)
        ? funcSource
        // funcSource is code, so it rides a function wrapper when args are
        // supplied (chrome.scripting func+args semantics).
        : '(function(){ $funcSource }).apply(null, ${jsonEncode(args)})';
    final borrowed = await _attach(tabId);
    try {
      Object? contextId;
      if ((world ?? 'ISOLATED') == 'ISOLATED') {
        final worldResponse = await _invoke('debugger.sendCommand', [
          {'tabId': tabId},
          'Page.createIsolatedWorld',
          {'frameId': frameId, 'worldName': 'fa-isolated'},
        ]);
        contextId = _m(worldResponse)['contextId'];
      }
      final response = await _invoke('debugger.sendCommand', [
        {'tabId': tabId},
        'Runtime.evaluate',
        {
          'expression': expression,
          'returnByValue': true,
          'awaitPromise': true,
          'userGesture': true,
          'contextId': ?contextId,
        },
      ]);
      final details = _m(response)['exceptionDetails'];
      if (details != null) {
        throw ChromeApiException(
          'page_error',
          'page threw during evaluate: ${jsonEncode(details)}',
        );
      }
      final value = _m(_m(response)['result'])['value'];
      return [ScriptResult(frameId: frameId, result: value)];
    } finally {
      if (borrowed) {
        try {
          await _invoke('debugger.detach', [
            {'tabId': tabId},
          ]);
        } on ChromeApiException {
          // Detach is hygiene; the evaluation result outranks it.
        }
      }
    }
  }

  @override
  Future<void> insertCSS({
    required int tabId,
    required String css,
    bool? allFrames,
  }) => _invoke('scripting.insertCSS', [
    {
      'target': {'tabId': tabId, 'allFrames': ?allFrames},
      'css': css,
    },
  ]);

  /// Attaches the debugger; true when WE attached (false = a session was
  /// already up — borrow it, and the caller must not detach).
  Future<bool> _attach(int tabId) async {
    try {
      await _invoke('debugger.attach', [
        {'tabId': tabId},
        '1.3',
      ]);
      return true;
    } on ChromeApiException catch (error) {
      if (error.code != 'already_attached') rethrow;
      return false;
    }
  }
}

final class _Debugger implements DebuggerApi {
  @override
  Future<void> attach(int tabId, {String requiredVersion = '1.3'}) =>
      _invoke('debugger.attach', [
        {'tabId': tabId},
        requiredVersion,
      ]);

  @override
  Future<void> detach(int tabId) => _invoke('debugger.detach', [
    {'tabId': tabId},
  ]);

  @override
  Future<Object?> sendCommand(
    int tabId,
    String method, [
    Map<String, Object?>? params,
  ]) => _invoke('debugger.sendCommand', [
    {'tabId': tabId},
    method,
    ?params,
  ]);
}

final class _History implements HistoryApi {
  @override
  Future<List<HistoryItem>> search({
    required String text,
    int? startTime,
    int? endTime,
    int? maxResults,
  }) => _invoke('history.search', [
    {
      'text': text,
      'startTime': ?startTime,
      'endTime': ?endTime,
      'maxResults': ?maxResults,
    },
  ]).then((raw) => [for (final m in _maps(raw)) _historyItemOf(m)]);
}

final class _Bookmarks implements BookmarksApi {
  @override
  Future<List<BookmarkNode>> tree() async {
    final roots = _maps(await _invoke('bookmarks.getTree'));
    // getTree returns the single '0' root; the facade's tree is its
    // children ('1' Bookmarks bar, '2' Other bookmarks).
    final children = roots.isNotEmpty ? _m(roots.first)['children'] : null;
    return [for (final node in _maps(children)) _bookmarkNodeOf(node)];
  }

  @override
  Future<BookmarkNode> create({
    String? parentId,
    required String title,
    String? url,
  }) => _invoke('bookmarks.create', [
    {'parentId': ?parentId, 'title': title, 'url': ?url},
  ]).then(_bookmarkNodeOf);

  @override
  Future<BookmarkNode> update(String id, {String? title, String? url}) =>
      _invoke('bookmarks.update', [
        id,
        {'title': ?title, 'url': ?url},
      ]).then(_bookmarkNodeOf);

  @override
  Future<void> remove(String id) => _invoke('bookmarks.remove', [id]);

  @override
  Future<BookmarkNode> move(String id, {String? parentId, int? index}) =>
      _invoke('bookmarks.move', [
        id,
        {'parentId': ?parentId, 'index': ?index},
      ]).then(_bookmarkNodeOf);
}

final class _Downloads implements DownloadsApi {
  @override
  Future<int> download({required String url, String? filename, bool? saveAs}) =>
      _invoke('downloads.download', [
        {'url': url, 'filename': ?filename, 'saveAs': ?saveAs},
      ]).then((raw) => _i(raw) ?? -1);

  @override
  Future<List<DownloadItem>> search({String? query, String? state}) =>
      _invoke('downloads.search', [
        {'query': ?query, 'state': ?state},
      ]).then((raw) => [for (final m in _maps(raw)) _downloadItemOf(m)]);

  @override
  Future<void> pause(int id) => _invoke('downloads.pause', [id]);

  @override
  Future<void> resume(int id) => _invoke('downloads.resume', [id]);

  @override
  Future<void> cancel(int id) => _invoke('downloads.cancel', [id]);
}

final class _Cookies implements CookiesApi {
  @override
  Future<Cookie?> get({required String url, required String name}) async =>
      _cookieOf(
        await _invoke('cookies.get', [
          {'url': url, 'name': name},
        ]),
      );

  @override
  Future<List<Cookie>> getAll({String? url, String? domain, String? name}) =>
      _invoke('cookies.getAll', [
        {'url': ?url, 'domain': ?domain, 'name': ?name},
      ]).then(
        (raw) => [
          for (final m in _maps(raw))
            // getAll never yields null entries; _cookieOf only reports empty
            // maps as null, so filter defensively.
            ?_cookieOf(m),
        ],
      );

  @override
  Future<Cookie> set({
    required String url,
    required String name,
    required String value,
    bool? secure,
    bool? httpOnly,
    int? expirationDate,
  }) async {
    final raw = await _invoke('cookies.set', [
      {
        'url': url,
        'name': name,
        'value': value,
        'secure': ?secure,
        'httpOnly': ?httpOnly,
        'expirationDate': ?expirationDate,
      },
    ]);
    return _cookieOf(raw) ??
        Cookie(
          name: name,
          value: value,
          domain: '',
          path: '/',
          secure: secure ?? false,
          httpOnly: httpOnly ?? false,
          expirationDate: expirationDate,
        );
  }

  @override
  Future<void> remove({required String url, required String name}) =>
      _invoke('cookies.remove', [
        {'url': url, 'name': name},
      ]);
}

final class _Storage implements StorageApi {
  @override
  int get quotaBytes {
    final local = _prop(_chromeRoot, 'storage.local');
    if (local == null || !local.isA<JSObject>()) {
      throw ChromeApiException(
        'api_missing',
        'chrome.storage.local is not available',
      );
    }
    return _i(_prop(local as JSObject, 'QUOTA_BYTES')?.dartify()) ??
        defaultStorageQuotaBytes;
  }

  @override
  Future<Map<String, Object?>> get([List<String>? keys]) async {
    final (self, fn) = _resolve('storage.local.get');
    // get(null) → every entry; get([keys]) → the present subset. The null
    // form must pass null itself, not a wrapped array.
    final raw = keys == null
        ? _applyFn(fn, self, [null].jsify() as JSArray)
        : _applyFn(fn, self, [keys].jsify() as JSArray);
    final resolved = raw == null || !raw.isA<JSPromise>()
        ? raw?.dartify()
        : (await (raw as JSPromise<JSAny?>).toDart)?.dartify();
    return _m(resolved);
  }

  @override
  Future<void> set(Map<String, Object?> items) =>
      _invoke('storage.local.set', [items]);

  @override
  Future<void> remove(List<String> keys) =>
      _invoke('storage.local.remove', [keys]);

  @override
  Future<void> clear() => _invoke('storage.local.clear');

  @override
  Stream<StorageChanged> get onChanged => _eventStream<List<StorageChanged>>(
    'storage.onChanged',
    2,
    (changes, area, _) {
      if (area != null && area.dartify() != 'local') return const [];
      final m = _m(changes?.dartify());
      return [
        for (final entry in m.entries)
          StorageChanged(
            key: entry.key,
            oldValue: _m(entry.value)['oldValue'],
            newValue: _m(entry.value)['newValue'],
          ),
      ];
    },
  ).expand((batch) => batch);
}

final class _Alarms implements AlarmsApi {
  @override
  Future<void> create({
    required String name,
    int? periodMinutes,
    int? whenMs,
  }) => _invoke('alarms.create', [
    name,
    {'periodInMinutes': ?periodMinutes, 'when': ?whenMs},
  ]);

  @override
  Future<bool> clear(String name) async =>
      _b(await _invoke('alarms.clear', [name]));

  @override
  Future<List<Alarm>> getAll() => _invoke(
    'alarms.getAll',
  ).then((raw) => [for (final m in _maps(raw)) _alarmOf(m)]);

  @override
  Stream<Alarm> get onAlarm => _eventStream(
    'alarms.onAlarm',
    1,
    (alarm, _, _) => _alarmOf(alarm?.dartify()),
  );
}

final class _Notifications implements NotificationsApi {
  @override
  String get permission {
    // chrome.notifications exposes its level only via an async call, but
    // the web Notification global carries the same permission
    // synchronously — the facade getter needs the sync value.
    final notification = _prop(globalContext, 'Notification');
    if (notification == null || !notification.isA<JSObject>()) {
      return 'granted';
    }
    return _s(
      _prop(notification as JSObject, 'permission')?.dartify(),
      'granted',
    );
  }

  @override
  Future<bool> create({
    required String id,
    required String title,
    required String message,
    String? iconUrl,
  }) async {
    if (permission == 'denied') return false; // E20: soft skip, not a throw
    try {
      final notifId = await _invoke('notifications.create', [
        id,
        {
          'type': 'basic',
          'title': title,
          'message': message,
          'iconUrl': ?iconUrl,
        },
      ]);
      return notifId is String ? notifId.isNotEmpty : notifId != null;
    } on ChromeApiException {
      return false;
    }
  }

  @override
  Future<bool> clear(String id) async =>
      _b(await _invoke('notifications.clear', [id]));
}

final class _Action implements ActionApi {
  @override
  Future<void> setBadgeText(String text) => _invoke('action.setBadgeText', [
    {'text': text},
  ]);

  @override
  Future<void> setBadgeBackgroundColor(String colorCss) =>
      _invoke('action.setBadgeBackgroundColor', [
        {'color': colorCss},
      ]);

  @override
  Future<void> setTitle(String title) => _invoke('action.setTitle', [
    {'title': title},
  ]);
}

final class _Offscreen implements OffscreenApi {
  @override
  Future<void> createDocument({
    required String url,
    required Set<String> reasons,
    required String justification,
  }) {
    for (final reason in reasons) {
      if (!mv3OffscreenReasons.contains(reason)) {
        throw ChromeApiException(
          'bad_args',
          'unknown offscreen reason "$reason" — '
              'use the mv3OffscreenReasons set',
        );
      }
    }
    return _invoke('offscreen.createDocument', [
      {'url': url, 'reasons': reasons.toList(), 'justification': justification},
    ]);
  }

  @override
  Future<void> closeDocument() => _invoke('offscreen.closeDocument');

  @override
  Future<bool> hasDocument() async =>
      _b(await _invoke('offscreen.hasDocument'));
}

final class _Power implements PowerApi {
  @override
  Future<void> requestKeepAwake(String level) =>
      _invoke('power.requestKeepAwake', [level]);

  @override
  Future<void> releaseKeepAwake() => _invoke('power.releaseKeepAwake');
}

final class _Idle implements IdleApi {
  @override
  Future<String> queryState(int thresholdSeconds) async =>
      _s(await _invoke('idle.queryState', [thresholdSeconds]));

  @override
  Stream<String> get onStateChanged => _eventStream(
    'idle.onStateChanged',
    1,
    (state, _, _) => state == null ? null : _s(state.dartify()),
  );
}

final class _ContextMenus implements ContextMenusApi {
  @override
  Future<void> create({
    required String id,
    required String title,
    List<String>? contexts,
  }) async {
    _call('contextMenus.create', [
      {'id': id, 'title': title, 'contexts': ?contexts},
    ]);
  }

  @override
  Future<void> removeAll() => _invoke('contextMenus.removeAll');

  @override
  Stream<MenuClick> get onClicked => _eventStream(
    'contextMenus.onClicked',
    2,
    (info, tab, _) => _menuClickOf(info, tab),
  );
}

final class _Omnibox implements OmniboxApi {
  @override
  Stream<OmniboxInput> get onInputEntered => _eventStream(
    'omnibox.onInputEntered',
    2,
    (text, disposition, _) => OmniboxInput(
      text: _s(text?.dartify()),
      disposition: _s(disposition?.dartify()),
    ),
  );
}

final class _Commands implements CommandsApi {
  @override
  Stream<String> get onCommand => _eventStream(
    'commands.onCommand',
    1,
    (command, _, _) => command == null ? null : _s(command.dartify()),
  );
}

final class _WebNavigation implements WebNavigationApi {
  @override
  Stream<NavCompleted> get onCompleted =>
      _eventStream('webNavigation.onCompleted', 1, (details, _, _) {
        final dart = details?.dartify();
        return dart == null ? null : _navCompletedOf(dart);
      });
}

final class _System implements SystemApi {
  @override
  Future<CpuInfo> cpu() => _invoke('system.cpu.getInfo').then(_cpuInfoOf);

  @override
  Future<MemoryInfo> memory() =>
      _invoke('system.memory.getInfo').then(_memoryInfoOf);

  @override
  Future<StorageInfo> storage() =>
      _invoke('system.storage.getInfo').then(_storageInfoOf);

  @override
  Future<DisplayInfo> display() =>
      _invoke('system.display.getInfo').then(_displayInfoOf);
}

final class _Identity implements IdentityApi {
  @override
  Future<String> launchWebAuthFlow({required String url}) async => _s(
    await _invoke('identity.launchWebAuthFlow', [
      {'url': url, 'interactive': true},
    ]),
  );
}

// ---------------------------------------------------------------------------
// The facade — 23 sub-facades, one instance each, built lazily
// ---------------------------------------------------------------------------

/// The production [ChromeApi]: binds the real chrome global through the
/// generic resolver above. The constructor probes the root so wiring can
/// fall back cleanly instead of failing on the first tool call.
final class JsChromeApi implements ChromeApi {
  JsChromeApi() {
    final root = _prop(globalContext, 'chrome');
    if (root == null || !root.isA<JSObject>()) {
      throw ChromeApiException(
        'api_missing',
        'chrome global is not available in this context',
      );
    }
  }

  @override
  late final tabs = _Tabs();
  @override
  late final windows = _Windows();
  @override
  late final groups = _Groups();
  @override
  late final sessions = _Sessions();
  @override
  late final scripting = _Scripting();
  @override
  late final debugger = _Debugger();
  @override
  late final history = _History();
  @override
  late final bookmarks = _Bookmarks();
  @override
  late final downloads = _Downloads();
  @override
  late final cookies = _Cookies();
  @override
  late final storage = _Storage();
  @override
  late final alarms = _Alarms();
  @override
  late final notifications = _Notifications();
  @override
  late final action = _Action();
  @override
  late final offscreen = _Offscreen();
  @override
  late final power = _Power();
  @override
  late final idle = _Idle();
  @override
  late final contextMenus = _ContextMenus();
  @override
  late final omnibox = _Omnibox();
  @override
  late final commands = _Commands();
  @override
  late final webNavigation = _WebNavigation();
  @override
  late final system = _System();
  @override
  late final identity = _Identity();
}
