// In-memory FakeChrome: the whole ChromeApi surface with no Chrome, no
// dart:io and no real timers. Everything is deterministic — time comes
// from the injected clock, moved only by advanceTo; events ride SYNCHRONOUS
// broadcast controllers (listeners run inside the triggering call, so
// tests never do an await-flush dance); script evaluation and CDP become
// recorded calls answered by the injected resultsFor/cdpResponder
// callbacks, so tool tests control what the "browser" says back.
library;

import 'dart:async';
import 'dart:convert';

import 'chrome_api.dart';

/// Auto-increment base for group ids: chrome group ids share the tab id
/// space, so the fake offsets groups to keep the two visibly distinct in
/// test failures.
const _groupIdBase = 1000;

/// Recency cap for closed sessions (chrome's own restore budget).
const _maxClosedSessions = 25;

Never _err(String code, String message) =>
    throw ChromeApiException(code, message);

/// Chrome match-pattern lite for tabs.query url/title filters: `*` is a
/// wildcard, no `*` means exact match (chrome patterns are not substrings).
bool _glob(String pattern, String value) {
  if (!pattern.contains('*')) return pattern == value;
  final rx = RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$');
  return rx.hasMatch(value);
}

/// One recorded executeScript call (the fake never evaluates funcSource).
final class ScriptCall {
  const ScriptCall({
    required this.tabId,
    required this.world,
    required this.allFrames,
    required this.frameIds,
    required this.funcSource,
    required this.args,
  });

  final int tabId;
  final String world;
  final bool allFrames;
  final List<int>? frameIds;
  final String funcSource;
  final List<Object?> args;
}

/// One recorded insertCSS call.
final class CssCall {
  const CssCall({
    required this.tabId,
    required this.css,
    required this.allFrames,
  });

  final int tabId;
  final String css;
  final bool allFrames;
}

/// One recorded CDP command.
final class CdpCall {
  const CdpCall({
    required this.tabId,
    required this.method,
    required this.params,
  });

  final int tabId;
  final String method;
  final Map<String, Object?> params;
}

/// The whole [ChromeApi] in memory: tabs/windows/groups in auto-increment
/// maps, storage under a real quota, alarms fired by [advanceTo] on the
/// injected clock — never by wall-clock timers.
final class FakeChrome implements ChromeApi {
  FakeChrome({
    int Function()? clock,
    this.resultsFor,
    this.cdpResponder,
    this.notificationPermission = 'granted',
    this.authRedirectUrl =
        'https://app.example.com/callback#access_token=fake-token',
    int? quotaBytes,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _quotaBytes = quotaBytes ?? defaultStorageQuotaBytes {
    // Bookmark roots are created once so the roots list and the id map
    // share the same node objects (updates via either path stay in sync).
    final bar = _BmRec(id: '1', title: 'Bookmarks bar');
    final other = _BmRec(id: '2', title: 'Other bookmarks');
    _bmById[bar.id] = bar;
    _bmById[other.id] = other;
    _bmRoots.addAll([bar, other]);

    _tabsApi = _FakeTabs(this);
    _windowsApi = _FakeWindows(this);
    _groupsApi = _FakeGroups(this);
    _sessionsApi = _FakeSessions(this);
    _scriptingApi = _FakeScripting(this);
    _debuggerApi = _FakeDebugger(this);
    _historyApi = _FakeHistory(this);
    _bookmarksApi = _FakeBookmarks(this);
    _downloadsApi = _FakeDownloads(this);
    _cookiesApi = _FakeCookies(this);
    _storageApi = _FakeStorage(this);
    _alarmsApi = _FakeAlarms(this);
    _notificationsApi = _FakeNotifications(this);
    _actionApi = _FakeAction(this);
    _offscreenApi = _FakeOffscreen(this);
    _powerApi = _FakePower(this);
    _idleApi = _FakeIdle(this);
    _contextMenusApi = _FakeContextMenus(this);
    _omniboxApi = _FakeOmnibox(this);
    _commandsApi = _FakeCommands(this);
    _webNavigationApi = _FakeWebNavigation(this);
    _systemApi = const _FakeSystem();
    _identityApi = _FakeIdentity(this);
  }

  /// Canned executeScript output per call; null (default) answers
  /// `{'recorded': true}`. Results still pass the JSON guard (E2).
  final Object? Function(String funcSource, List<Object?> args)? resultsFor;

  /// Canned CDP answers; null (default) echoes `{method, params}` back.
  final Object? Function(String method, Map<String, Object?> params)?
  cdpResponder;

  final String notificationPermission;
  final String authRedirectUrl;

  final int Function() _clock;
  int _clockOffsetMs = 0;
  final int _quotaBytes;

  late final _FakeTabs _tabsApi;
  late final _FakeWindows _windowsApi;
  late final _FakeGroups _groupsApi;
  late final _FakeSessions _sessionsApi;
  late final _FakeScripting _scriptingApi;
  late final _FakeDebugger _debuggerApi;
  late final _FakeHistory _historyApi;
  late final _FakeBookmarks _bookmarksApi;
  late final _FakeDownloads _downloadsApi;
  late final _FakeCookies _cookiesApi;
  late final _FakeStorage _storageApi;
  late final _FakeAlarms _alarmsApi;
  late final _FakeNotifications _notificationsApi;
  late final _FakeAction _actionApi;
  late final _FakeOffscreen _offscreenApi;
  late final _FakePower _powerApi;
  late final _FakeIdle _idleApi;
  late final _FakeContextMenus _contextMenusApi;
  late final _FakeOmnibox _omniboxApi;
  late final _FakeCommands _commandsApi;
  late final _FakeWebNavigation _webNavigationApi;
  late final _FakeSystem _systemApi;
  late final _FakeIdentity _identityApi;

  // -- State ----------------------------------------------------------------
  final Map<int, _TabRec> _tabs = {};
  final Map<int, _WinRec> _windows = {};
  final Map<int, _GroupRec> _groups = {};
  final List<_ClosedRec> _closed = [];
  final Map<String, Object?> _store = {};
  final Map<String, _AlarmRec> _alarms = {};
  final Map<String, _NotifRec> _notifications = {};
  final Map<String, _MenuRec> _menus = {};
  final Map<int, _DlRec> _downloads = {};
  final Map<String, Cookie> _cookies = {};
  final List<HistoryItem> _history = [];
  final Map<String, _BmRec> _bmById = {};
  final List<_BmRec> _bmRoots = [];
  final Set<int> _attached = {};

  int _nextTabId = 1;
  int _nextWindowId = 1;
  int _nextGroupId = _groupIdBase;
  int _nextSessionId = 1;
  int _nextDownloadId = 1;
  int _nextHistoryId = 1;
  int _nextBmId = 3;

  String? _offscreenUrl;
  String _idleState = 'active';
  String? _keepAwakeLevel;
  String? _badgeText;
  String? _badgeColor;
  String? _actionTitle;

  /// Recorded executeScript calls, oldest first.
  final List<ScriptCall> scriptCalls = [];

  /// Recorded insertCSS calls, oldest first.
  final List<CssCall> cssCalls = [];

  /// Recorded CDP commands, oldest first.
  final List<CdpCall> cdpCalls = [];

  // -- Event buses (sync broadcast: listeners run inside the trigger) -------
  final _tabCreated = StreamController<Tab>.broadcast(sync: true);
  final _tabRemoved = StreamController<TabRemoved>.broadcast(sync: true);
  final _tabUpdated = StreamController<TabUpdated>.broadcast(sync: true);
  final _storageChanged = StreamController<StorageChanged>.broadcast(
    sync: true,
  );
  final _alarmFired = StreamController<Alarm>.broadcast(sync: true);
  final _stateChanged = StreamController<String>.broadcast(sync: true);
  final _menuClicked = StreamController<MenuClick>.broadcast(sync: true);
  final _omniEntered = StreamController<OmniboxInput>.broadcast(sync: true);
  final _commandPressed = StreamController<String>.broadcast(sync: true);
  final _navCompleted = StreamController<NavCompleted>.broadcast(sync: true);

  // -- ChromeApi ------------------------------------------------------------
  @override
  TabsApi get tabs => _tabsApi;
  @override
  WindowsApi get windows => _windowsApi;
  @override
  TabGroupsApi get groups => _groupsApi;
  @override
  SessionsApi get sessions => _sessionsApi;
  @override
  ScriptingApi get scripting => _scriptingApi;
  @override
  DebuggerApi get debugger => _debuggerApi;
  @override
  HistoryApi get history => _historyApi;
  @override
  BookmarksApi get bookmarks => _bookmarksApi;
  @override
  DownloadsApi get downloads => _downloadsApi;
  @override
  CookiesApi get cookies => _cookiesApi;
  @override
  StorageApi get storage => _storageApi;
  @override
  AlarmsApi get alarms => _alarmsApi;
  @override
  NotificationsApi get notifications => _notificationsApi;
  @override
  ActionApi get action => _actionApi;
  @override
  OffscreenApi get offscreen => _offscreenApi;
  @override
  PowerApi get power => _powerApi;
  @override
  IdleApi get idle => _idleApi;
  @override
  ContextMenusApi get contextMenus => _contextMenusApi;
  @override
  OmniboxApi get omnibox => _omniboxApi;
  @override
  CommandsApi get commands => _commandsApi;
  @override
  WebNavigationApi get webNavigation => _webNavigationApi;
  @override
  SystemApi get system => _systemApi;
  @override
  IdentityApi get identity => _identityApi;

  // -- Deterministic time ---------------------------------------------------
  /// Fake wall clock (ms epoch): the injected clock plus the offset that
  /// [advanceTo] accumulated.
  int get nowMs => _clock() + _clockOffsetMs;

  /// Time travel for tests: pulls the fake clock to [ts] (never backwards)
  /// and fires every alarm scheduled at or before it — each scheduled tick
  /// exactly once, so re-advancing to the same ts never double-fires.
  Future<void> advanceTo(int ts) async {
    final now = nowMs;
    if (ts > now) _clockOffsetMs += ts - now;
    _fireDueAlarms();
  }

  void _fireDueAlarms() {
    final now = nowMs;
    for (final alarm
        in _alarms.values.where((a) => a.nextFireTs <= now).toList()) {
      while (alarm.nextFireTs <= now) {
        _alarmFired.add(Alarm(name: alarm.name, scheduledTs: alarm.nextFireTs));
        final period = alarm.periodMs;
        if (period == null) {
          _alarms.remove(alarm.name); // one-shot when-alarms auto-clear
          break;
        }
        alarm.nextFireTs += period;
      }
    }
  }

  // -- Test drive-ins for event-only surfaces -------------------------------
  /// Emits contextMenus.onClicked for [menuItemId].
  Future<void> clickMenu({
    required String menuItemId,
    String? selectionText,
    String? linkUrl,
    String? srcUrl,
    String? pageUrl,
    int? tabId,
  }) async {
    if (!_menus.containsKey(menuItemId)) {
      throw _err('no_menu', 'no menu item "$menuItemId"');
    }
    Tab? tab;
    if (tabId != null) {
      tab = _snapTab(_tabOrThrow(tabId));
    } else {
      final focused = _windows.values.where((w) => w.focused);
      for (final win in focused) {
        for (final id in win.tabIds) {
          final t = _tabs[id]!;
          if (t.active) tab = _snapTab(t);
        }
      }
    }
    _menuClicked.add(
      MenuClick(
        menuItemId: menuItemId,
        selectionText: selectionText,
        linkUrl: linkUrl,
        srcUrl: srcUrl,
        pageUrl: pageUrl,
        tab: tab,
      ),
    );
  }

  /// Emits omnibox.onInputEntered.
  Future<void> enterOmnibox(
    String text, {
    String disposition = 'current_tab',
  }) async {
    _omniEntered.add(OmniboxInput(text: text, disposition: disposition));
  }

  /// Emits commands.onCommand.
  Future<void> pressCommand(String name) async {
    _commandPressed.add(name);
  }

  /// Emits webNavigation.onCompleted.
  Future<void> navCompleted({
    required int tabId,
    required String url,
    int frameId = 0,
  }) async {
    _navCompleted.add(NavCompleted(tabId: tabId, url: url, frameId: frameId));
  }

  /// Sets the idle state and emits idle.onStateChanged.
  Future<void> setIdleState(String state) async {
    if (state != 'active' && state != 'idle' && state != 'locked') {
      throw _err('bad_args', 'idle state must be active, idle or locked');
    }
    _idleState = state;
    _stateChanged.add(state);
  }

  /// Fake-only history seeding (chrome.history.addUrl is not on the
  /// facade; tests need entries to search).
  void seedHistory({required String url, String? title}) {
    _history.insert(
      0,
      HistoryItem(
        id: '${_nextHistoryId++}',
        url: url,
        title: title ?? url,
        lastVisitTs: nowMs,
      ),
    );
  }

  // -- Test observability ---------------------------------------------------
  String? get badgeText => _badgeText;
  String? get badgeBackgroundColor => _badgeColor;
  String? get actionTitle => _actionTitle;
  String? get keepAwakeLevel => _keepAwakeLevel;

  // -- Shared tab/window machinery -------------------------------------------
  _TabRec _tabOrThrow(int id) =>
      _tabs[id] ?? (throw _err('no_tab', 'no tab with id $id'));

  _WinRec _winOrThrow(int id) =>
      _windows[id] ?? (throw _err('no_window', 'no window with id $id'));

  /// The focused window, creating the default one when none exists yet —
  /// chrome never has zero windows either.
  _WinRec _ensureWindow() {
    for (final w in _windows.values) {
      if (w.focused) return w;
    }
    if (_windows.isNotEmpty) {
      return _windows[_windows.keys.reduce((a, b) => a < b ? a : b)]!;
    }
    final win = _WinRec(
      id: _nextWindowId++,
      type: 'normal',
      state: 'normal',
      focused: true,
      left: 0,
      top: 0,
      width: 1280,
      height: 720,
      incognito: false,
      tabIds: [],
    );
    _windows[win.id] = win;
    return win;
  }

  void _focus(_WinRec win) {
    for (final w in _windows.values) {
      w.focused = w.id == win.id;
    }
  }

  List<_WinRec> get _windowsSorted {
    final list = _windows.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  _TabRec _newTab({
    required String url,
    required String title,
    bool pinned = false,
    bool muted = false,
    bool audible = false,
    int? groupId,
    int? windowId,
    int? index,
    bool active = true,
    String? favIconUrl,
  }) {
    final win = windowId == null ? _ensureWindow() : _winOrThrow(windowId);
    final id = _nextTabId++;
    final t = _TabRec(
      id: id,
      url: url,
      title: title,
      pinned: pinned,
      muted: muted,
      audible: audible,
      groupId: groupId,
      windowId: win.id,
      active: active,
      favIconUrl: favIconUrl,
    );
    _tabs[id] = t;
    final at = (index == null || index >= win.tabIds.length)
        ? win.tabIds.length
        : (index < 0 ? 0 : index);
    win.tabIds.insert(at, id);
    if (active) _activate(t);
    _tabCreated.add(_snapTab(t));
    return t;
  }

  /// Makes [t] its window's active tab, deactivating (and announcing) the
  /// previous holder. Does not announce [t] itself — creation is born
  /// active, updates emit their own changeInfo.
  void _activate(_TabRec t) {
    for (final id in _windows[t.windowId]!.tabIds) {
      final other = _tabs[id]!;
      if (other.id != t.id && other.active) {
        other.active = false;
        _emitTab(other, {'active': false});
      }
    }
    t.active = true;
  }

  void _emitTab(_TabRec t, Map<String, Object?> changeInfo) {
    _tabUpdated.add(TabUpdated(tabId: t.id, changeInfo: changeInfo));
  }

  void _closeTab(
    _TabRec t, {
    bool isWindowClosing = false,
    bool recordSession = true,
  }) {
    final win = _windows[t.windowId]!;
    final wasActive = t.active;
    win.tabIds.remove(t.id);
    _tabs.remove(t.id);
    if (recordSession) {
      _rememberClosed(
        _ClosedRec(
          sessionId: 's${_nextSessionId++}',
          lastModified: nowMs ~/ 1000, // chrome lastModified is seconds
          tab: _snapTab(t),
        ),
      );
    }
    _tabRemoved.add(
      TabRemoved(
        tabId: t.id,
        windowId: t.windowId,
        isWindowClosing: isWindowClosing,
      ),
    );
    if (!isWindowClosing && wasActive && win.tabIds.isNotEmpty) {
      final heir = _tabs[win.tabIds.last]!;
      _activate(heir);
      _emitTab(heir, {'active': true});
    }
  }

  void _rememberClosed(_ClosedRec rec) {
    _closed.insert(0, rec);
    if (_closed.length > _maxClosedSessions) _closed.removeLast();
  }

  Tab _snapTab(_TabRec t) => Tab(
    id: t.id,
    url: t.url,
    title: t.title,
    pinned: t.pinned,
    muted: t.muted,
    audible: t.audible,
    groupId: t.groupId,
    windowId: t.windowId,
    active: t.active,
    favIconUrl: t.favIconUrl,
    discarded: t.discarded,
  );

  BrowserWindow _snapWin(_WinRec w) => BrowserWindow(
    id: w.id,
    type: w.type,
    state: w.state,
    focused: w.focused,
    left: w.left,
    top: w.top,
    width: w.width,
    height: w.height,
    incognito: w.incognito,
    tabIds: List.of(w.tabIds),
  );
}

// ---------------------------------------------------------------------------
// Sub-facade implementations
// ---------------------------------------------------------------------------

final class _FakeTabs implements TabsApi {
  _FakeTabs(this._c);
  final FakeChrome _c;

  @override
  Future<Tab> create({
    String? url,
    bool? active,
    int? index,
    bool? pinned,
  }) async {
    final u = url ?? 'chrome://newtab/';
    final t = _c._newTab(
      url: u,
      // Fake pages have no DOM: the title mirrors the url once navigated.
      title: url == null ? 'New Tab' : u,
      index: index,
      active: active ?? true,
      pinned: pinned ?? false,
    );
    return _c._snapTab(t);
  }

  @override
  Future<Tab> get(int id) async => _c._snapTab(_c._tabOrThrow(id));

  @override
  Future<Tab> update(
    int id, {
    String? url,
    bool? active,
    bool? pinned,
    bool? muted,
  }) async {
    final t = _c._tabOrThrow(id);
    if (url != null && url != t.url) {
      t.url = url;
      t.title = url;
      t.discarded = false; // navigating wakes a discarded tab
      _c._emitTab(t, {'url': url, 'title': t.title, 'status': 'complete'});
    }
    if (active != null && active != t.active) {
      if (active) {
        _c._activate(t);
      } else {
        t.active = false;
      }
      _c._emitTab(t, {'active': t.active});
    }
    if (pinned != null && pinned != t.pinned) {
      t.pinned = pinned;
      _c._emitTab(t, {'pinned': pinned});
    }
    if (muted != null && muted != t.muted) {
      t.muted = muted;
      t.audible = !muted;
      _c._emitTab(t, {'muted': muted, 'audible': t.audible});
    }
    return _c._snapTab(t);
  }

  @override
  Future<List<Tab>> query({
    String? url,
    String? title,
    int? groupId,
    bool? pinned,
    bool? muted,
    bool? active,
    bool? currentWindow,
  }) async {
    final focusWin = _c._ensureWindow().id;
    final out = <Tab>[];
    for (final win in _c._windowsSorted) {
      for (final tid in win.tabIds) {
        final t = _c._tabs[tid]!;
        if (url != null && !_glob(url, t.url)) continue;
        if (title != null && !_glob(title, t.title)) continue;
        if (groupId != null && t.groupId != groupId) continue;
        if (pinned != null && t.pinned != pinned) continue;
        if (muted != null && t.muted != muted) continue;
        if (active != null && t.active != active) continue;
        if (currentWindow == true && t.windowId != focusWin) continue;
        out.add(_c._snapTab(t));
      }
    }
    return out;
  }

  @override
  Future<void> close(int id) async => _c._closeTab(_c._tabOrThrow(id));

  @override
  Future<Tab> duplicate(int id) async {
    final src = _c._tabOrThrow(id);
    final win = _c._windows[src.windowId]!;
    final dup = _c._newTab(
      url: src.url,
      title: src.title,
      pinned: src.pinned,
      muted: src.muted,
      audible: src.audible,
      groupId: src.groupId,
      windowId: win.id,
      index: win.tabIds.indexOf(src.id) + 1,
      active: true, // chrome selects the duplicate
    );
    return _c._snapTab(dup);
  }

  @override
  Future<Tab> reload(int id, {bool bypassCache = false}) async {
    final t = _c._tabOrThrow(id);
    _c._emitTab(t, {'status': 'loading'});
    // ponytail: one tick, no fetch to wait for in memory.
    _c._emitTab(t, {'status': 'complete'});
    return _c._snapTab(t);
  }

  @override
  Future<Tab> move(int id, {required int index, int? windowId}) async {
    final t = _c._tabOrThrow(id);
    final target = windowId == null
        ? _c._windows[t.windowId]!
        : _c._winOrThrow(windowId);
    _c._windows[t.windowId]!.tabIds.remove(t.id);
    t.windowId = target.id;
    final at = index < 0
        ? 0
        : (index > target.tabIds.length ? target.tabIds.length : index);
    target.tabIds.insert(at, t.id);
    return _c._snapTab(t);
  }

  @override
  Future<int> group({
    required List<int> tabIds,
    int? groupId,
    String? title,
    String? color,
  }) async {
    if (tabIds.isEmpty) throw _err('bad_args', 'tabIds must not be empty');
    final recs = [for (final id in tabIds) _c._tabOrThrow(id)];
    final win = recs.first.windowId;
    if (recs.any((t) => t.windowId != win)) {
      // chrome groups are per-window too.
      throw _err('bad_args', 'group tabs must share one window');
    }
    int gid;
    if (groupId != null) {
      if (!_c._groups.containsKey(groupId)) {
        throw _err('no_group', 'no tab group with id $groupId');
      }
      gid = groupId;
    } else {
      gid = _c._nextGroupId++;
      _c._groups[gid] = _GroupRec(
        id: gid,
        title: '',
        color: 'grey',
        windowId: win,
      );
    }
    final g = _c._groups[gid]!;
    for (final t in recs) {
      t.groupId = gid;
      _c._emitTab(t, {'groupId': gid});
    }
    if (title != null) g.title = title;
    if (color != null) g.color = color;
    return gid;
  }

  @override
  Future<void> ungroup(List<int> tabIds) async {
    for (final id in tabIds) {
      final t = _c._tabOrThrow(id);
      if (t.groupId == null) continue;
      t.groupId = null;
      _c._emitTab(t, {'groupId': null});
    }
  }

  @override
  Future<Tab> discard(int id) async {
    final t = _c._tabOrThrow(id);
    t.discarded = true;
    t.audible = false;
    _c._emitTab(t, {'discarded': true, 'audible': false});
    return _c._snapTab(t);
  }

  @override
  Stream<Tab> get onCreated => _c._tabCreated.stream;
  @override
  Stream<TabRemoved> get onRemoved => _c._tabRemoved.stream;
  @override
  Stream<TabUpdated> get onUpdated => _c._tabUpdated.stream;
}

final class _FakeWindows implements WindowsApi {
  _FakeWindows(this._c);
  final FakeChrome _c;

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
  }) async {
    final win = _WinRec(
      id: _c._nextWindowId++,
      type: type ?? 'normal',
      state: state ?? 'normal',
      focused: false,
      left: left ?? 0,
      top: top ?? 0,
      width: width ?? 1280,
      height: height ?? 720,
      incognito: incognito ?? false,
      tabIds: [],
    );
    _c._windows[win.id] = win;
    _c._focus(win);
    // chrome windows always carry at least one tab.
    _c._newTab(
      url: url ?? 'chrome://newtab/',
      title: url ?? 'New Tab',
      windowId: win.id,
    );
    return _c._snapWin(win);
  }

  @override
  Future<BrowserWindow> get(int id) async => _c._snapWin(_c._winOrThrow(id));

  @override
  Future<List<BrowserWindow>> getAll() async => [
    for (final w in _c._windowsSorted) _c._snapWin(w),
  ];

  @override
  Future<BrowserWindow> update(
    int id, {
    String? state,
    bool? focused,
    int? left,
    int? top,
    int? width,
    int? height,
  }) async {
    final w = _c._winOrThrow(id);
    if (state != null) w.state = state;
    if (left != null) w.left = left;
    if (top != null) w.top = top;
    if (width != null) w.width = width;
    if (height != null) w.height = height;
    if (focused == true) _c._focus(w);
    return _c._snapWin(w);
  }

  @override
  Future<void> close(int id) async {
    final w = _c._winOrThrow(id);
    final tabSnaps = [for (final tid in w.tabIds) _c._snapTab(_c._tabs[tid]!)];
    for (final tid in List.of(w.tabIds)) {
      _c._closeTab(_c._tabs[tid]!, isWindowClosing: true, recordSession: false);
    }
    _c._windows.remove(w.id);
    if (w.focused && _c._windows.isNotEmpty) {
      _c._focus(_c._windowsSorted.first);
    }
    // One closed session per window (chrome restores the whole window).
    _c._rememberClosed(
      _ClosedRec(
        sessionId: 's${_c._nextSessionId++}',
        lastModified: _c.nowMs ~/ 1000,
        window: _c._snapWin(w),
        windowTabs: tabSnaps,
      ),
    );
  }
}

final class _FakeGroups implements TabGroupsApi {
  _FakeGroups(this._c);
  final FakeChrome _c;

  _GroupRec _orThrow(int id) =>
      _c._groups[id] ?? (throw _err('no_group', 'no tab group with id $id'));
  TabGroup _record(_GroupRec g) =>
      TabGroup(id: g.id, title: g.title, color: g.color, windowId: g.windowId);

  @override
  Future<TabGroup> update(int groupId, {String? title, String? color}) async {
    final g = _orThrow(groupId);
    if (title != null) g.title = title;
    if (color != null) g.color = color;
    return _record(g);
  }

  @override
  Future<List<TabGroup>> query({String? title, String? color}) async {
    final out = <TabGroup>[];
    for (final g in _c._groups.values) {
      if (title != null && g.title != title) continue;
      if (color != null && g.color != color) continue;
      out.add(_record(g));
    }
    return out;
  }

  @override
  Future<void> close(int groupId) async {
    final g = _orThrow(groupId);
    final members = _c._tabs.values.where((t) => t.groupId == groupId).toList();
    for (final t in members) {
      _c._closeTab(t);
    }
    _c._groups.remove(g.id);
  }
}

final class _FakeSessions implements SessionsApi {
  _FakeSessions(this._c);
  final FakeChrome _c;

  @override
  Future<List<ClosedSession>> getRecentlyClosed() async => [
    for (final r in _c._closed)
      ClosedSession(
        sessionId: r.sessionId,
        tab: r.tab,
        window: r.window,
        lastModified: r.lastModified,
      ),
  ];

  @override
  Future<RestoredSession> restore(String sessionId) async {
    final idx = _c._closed.indexWhere((r) => r.sessionId == sessionId);
    if (idx < 0) {
      throw _err('no_session', 'no recently closed session "$sessionId"');
    }
    final rec = _c._closed.removeAt(idx);
    final snap = rec.tab;
    if (snap != null) {
      final win = _c._windows.containsKey(snap.windowId)
          ? _c._windows[snap.windowId]!
          : _c._ensureWindow();
      final t = _c._newTab(
        url: snap.url,
        title: snap.title,
        pinned: snap.pinned,
        muted: snap.muted,
        audible: snap.audible,
        windowId: win.id,
      );
      return RestoredSession(tab: _c._snapTab(t));
    }
    final w = rec.window!;
    final win = _WinRec(
      id: _c._nextWindowId++,
      type: w.type,
      state: w.state,
      focused: false,
      left: w.left,
      top: w.top,
      width: w.width,
      height: w.height,
      incognito: w.incognito,
      tabIds: [],
    );
    _c._windows[win.id] = win;
    _c._focus(win);
    var first = true;
    for (final ts in rec.windowTabs) {
      _c._newTab(
        url: ts.url,
        title: ts.title,
        pinned: ts.pinned,
        muted: ts.muted,
        audible: ts.audible,
        windowId: win.id,
        active: first,
      );
      first = false;
    }
    return RestoredSession(window: _c._snapWin(win));
  }
}

final class _FakeScripting implements ScriptingApi {
  _FakeScripting(this._c);
  final FakeChrome _c;

  @override
  Future<List<ScriptResult>> executeScript({
    required int tabId,
    String? world,
    bool? allFrames,
    List<int>? frameIds,
    required String funcSource,
    List<Object?>? args,
  }) async {
    _c._tabOrThrow(tabId); // chrome fails the target before injecting
    final call = ScriptCall(
      tabId: tabId,
      world: world ?? 'ISOLATED',
      allFrames: allFrames ?? false,
      frameIds: frameIds == null ? null : List.of(frameIds),
      funcSource: funcSource,
      args: List.of(args ?? const []),
    );
    _c.scriptCalls.add(call);
    final canned =
        _c.resultsFor?.call(funcSource, call.args) ?? const {'recorded': true};
    requireJsonable(canned); // E2: non-serializable results hard-fail
    // ponytail: the fake has no frame tree — allFrames/frameIds collapse to
    // the frames requested, defaulting to the top frame 0.
    final frames = frameIds ?? const [0];
    return [for (final f in frames) ScriptResult(frameId: f, result: canned)];
  }

  @override
  Future<void> insertCSS({
    required int tabId,
    required String css,
    bool? allFrames,
  }) async {
    _c._tabOrThrow(tabId);
    _c.cssCalls.add(
      CssCall(tabId: tabId, css: css, allFrames: allFrames ?? false),
    );
  }
}

final class _FakeDebugger implements DebuggerApi {
  _FakeDebugger(this._c);
  final FakeChrome _c;

  @override
  Future<void> attach(int tabId, {String requiredVersion = '1.3'}) async {
    _c._tabOrThrow(tabId);
    if (_c._attached.contains(tabId)) {
      throw _err(
        'already_attached',
        'a debugger is already attached to $tabId',
      );
    }
    _c._attached.add(tabId);
  }

  @override
  Future<void> detach(int tabId) async {
    if (!_c._attached.remove(tabId)) {
      throw _err('not_attached', 'no debugger attached to $tabId');
    }
  }

  @override
  Future<Object?> sendCommand(
    int tabId,
    String method, [
    Map<String, Object?>? params,
  ]) async {
    if (!_c._attached.contains(tabId)) {
      throw _err('not_attached', 'no debugger attached to $tabId');
    }
    final p = params ?? const {};
    _c.cdpCalls.add(CdpCall(tabId: tabId, method: method, params: p));
    final answer =
        _c.cdpResponder?.call(method, p) ?? {'method': method, 'params': p};
    return requireJsonable(answer);
  }
}

final class _FakeHistory implements HistoryApi {
  _FakeHistory(this._c);
  final FakeChrome _c;

  @override
  Future<List<HistoryItem>> search({
    required String text,
    int? startTime,
    int? endTime,
    int? maxResults,
  }) async {
    final q = text.toLowerCase();
    final hits = _c._history.where((h) {
      if (q.isNotEmpty &&
          !h.url.toLowerCase().contains(q) &&
          !h.title.toLowerCase().contains(q)) {
        return false;
      }
      if (startTime != null && h.lastVisitTs < startTime) return false;
      if (endTime != null && h.lastVisitTs > endTime) return false;
      return true;
    }).toList();
    if (maxResults != null && hits.length > maxResults) {
      return hits.sublist(0, maxResults);
    }
    return hits;
  }
}

final class _FakeBookmarks implements BookmarksApi {
  _FakeBookmarks(this._c);
  final FakeChrome _c;

  _BmRec _orThrow(String id) =>
      _c._bmById[id] ?? (throw _err('no_node', 'no bookmark with id $id'));

  _BmRec _folderOrThrow(String id) {
    final node = _orThrow(id);
    if (node.url != null) {
      throw _err('bad_args', 'bookmark $id is not a folder');
    }
    return node;
  }

  BookmarkNode _snap(_BmRec n) => BookmarkNode(
    id: n.id,
    title: n.title,
    url: n.url,
    children: [for (final c in n.children) _snap(c)],
  );

  void _drop(String id) {
    final node = _orThrow(id);
    void walk(_BmRec n) {
      for (final c in n.children) {
        walk(c);
      }
      _c._bmById.remove(n.id);
    }

    walk(node);
    (node.parentId == null ? _c._bmRoots : _c._bmById[node.parentId]!.children)
        .remove(node);
  }

  @override
  Future<List<BookmarkNode>> tree() async => [
    for (final r in _c._bmRoots) _snap(r),
  ];

  @override
  Future<BookmarkNode> create({
    String? parentId,
    required String title,
    String? url,
  }) async {
    final parent = parentId == null ? _c._bmRoots[0] : _folderOrThrow(parentId);
    final node = _BmRec(
      id: '${_c._nextBmId++}',
      title: title,
      url: url,
      parentId: parent.id,
    );
    _c._bmById[node.id] = node;
    parent.children.add(node);
    return _snap(node);
  }

  @override
  Future<BookmarkNode> update(String id, {String? title, String? url}) async {
    final node = _orThrow(id);
    if (url != null && node.children.isNotEmpty) {
      throw _err('bad_args', 'cannot put a url on folder $id');
    }
    if (title != null) node.title = title;
    if (url != null) node.url = url;
    return _snap(node);
  }

  @override
  Future<void> remove(String id) async {
    if (_c._bmRoots.any((r) => r.id == id)) {
      throw _err('bad_args', 'cannot remove bookmark root $id');
    }
    _drop(id);
  }

  @override
  Future<BookmarkNode> move(String id, {String? parentId, int? index}) async {
    final node = _orThrow(id);
    if (_c._bmRoots.contains(node)) {
      throw _err('bad_args', 'cannot move bookmark root $id');
    }
    final oldParent = _c._bmById[node.parentId]!;
    _BmRec newParent;
    if (parentId != null) {
      newParent = _folderOrThrow(parentId);
      node.parentId = parentId;
    } else {
      newParent = oldParent;
    }
    oldParent.children.remove(node);
    final at = (index == null || index >= newParent.children.length)
        ? newParent.children.length
        : (index < 0 ? 0 : index);
    newParent.children.insert(at, node);
    return _snap(node);
  }
}

final class _FakeDownloads implements DownloadsApi {
  _FakeDownloads(this._c);
  final FakeChrome _c;

  _DlRec _orThrow(int id) =>
      _c._downloads[id] ??
      (throw _err('no_download', 'no download with id $id'));

  @override
  Future<int> download({
    required String url,
    String? filename,
    bool? saveAs,
  }) async {
    final id = _c._nextDownloadId++;
    _c._downloads[id] = _DlRec(
      id: id,
      url: url,
      filename: filename ?? _fileNameOf(url),
      state: 'in_progress',
    );
    return id;
  }

  @override
  Future<List<DownloadItem>> search({String? query, String? state}) async {
    final q = query?.toLowerCase();
    final out = <DownloadItem>[];
    for (final d in _c._downloads.values) {
      if (state != null && d.state != state) continue;
      if (q != null &&
          !d.url.toLowerCase().contains(q) &&
          !d.filename.toLowerCase().contains(q)) {
        continue;
      }
      out.add(
        DownloadItem(
          id: d.id,
          url: d.url,
          filename: d.filename,
          state: d.state,
          paused: d.paused,
        ),
      );
    }
    return out;
  }

  @override
  Future<void> pause(int id) async {
    final d = _orThrow(id);
    if (d.state != 'in_progress') {
      throw _err('not_in_progress', 'download $id is not in progress');
    }
    d.paused = true;
  }

  @override
  Future<void> resume(int id) async {
    final d = _orThrow(id);
    if (d.state != 'in_progress') {
      throw _err('not_in_progress', 'download $id is not in progress');
    }
    d.paused = false;
  }

  @override
  Future<void> cancel(int id) async {
    final d = _orThrow(id);
    d.state = 'interrupted';
    d.paused = false;
  }
}

String _fileNameOf(String url) {
  final segments = Uri.tryParse(url)?.pathSegments ?? const [];
  for (final s in segments.reversed) {
    if (s.isNotEmpty) return s;
  }
  return 'download';
}

final class _FakeCookies implements CookiesApi {
  _FakeCookies(this._c);
  final FakeChrome _c;

  String _key(String domain, String name) => '$domain|/$name';

  String _hostOf(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) throw _err('bad_args', 'cookie url "$url" has no host');
    return host;
  }

  @override
  Future<Cookie?> get({required String url, required String name}) async =>
      _c._cookies[_key(_hostOf(url), name)];

  @override
  Future<List<Cookie>> getAll({
    String? url,
    String? domain,
    String? name,
  }) async {
    final host = url == null ? null : _hostOf(url);
    final out = <Cookie>[];
    for (final c in _c._cookies.values) {
      if (host != null && c.domain != host) continue;
      if (domain != null &&
          c.domain != domain &&
          !c.domain.endsWith('.$domain')) {
        continue;
      }
      if (name != null && c.name != name) continue;
      out.add(c);
    }
    return out;
  }

  @override
  Future<Cookie> set({
    required String url,
    required String name,
    required String value,
    bool? secure,
    bool? httpOnly,
    int? expirationDate,
  }) async {
    final host = _hostOf(url);
    final cookie = Cookie(
      name: name,
      value: value,
      domain: host,
      path: '/',
      secure: secure ?? false,
      httpOnly: httpOnly ?? false,
      expirationDate: expirationDate,
    );
    _c._cookies[_key(host, name)] = cookie;
    return cookie;
  }

  @override
  Future<void> remove({required String url, required String name}) async {
    _c._cookies.remove(_key(_hostOf(url), name));
  }
}

final class _FakeStorage implements StorageApi {
  _FakeStorage(this._c);
  final FakeChrome _c;

  @override
  int get quotaBytes => _c._quotaBytes;

  @override
  Future<Map<String, Object?>> get([List<String>? keys]) async {
    if (keys == null) return Map.of(_c._store);
    return {
      for (final k in keys)
        if (_c._store.containsKey(k)) k: _c._store[k],
    };
  }

  @override
  Future<void> set(Map<String, Object?> items) async {
    final merged = {..._c._store, ...items};
    final size = utf8.encode(jsonEncode(merged)).length;
    if (size > _c._quotaBytes) {
      throw _err(
        'quota_exceeded',
        'storage.local would hold $size bytes, quota is ${_c._quotaBytes}',
      );
    }
    for (final e in items.entries) {
      final old = _c._store[e.key];
      if (old == e.value) continue;
      _c._store[e.key] = e.value;
      _c._storageChanged.add(
        StorageChanged(key: e.key, oldValue: old, newValue: e.value),
      );
    }
  }

  @override
  Future<void> remove(List<String> keys) async {
    for (final k in keys) {
      if (!_c._store.containsKey(k)) continue;
      final old = _c._store.remove(k);
      _c._storageChanged.add(
        StorageChanged(key: k, oldValue: old, newValue: null),
      );
    }
  }

  @override
  Future<void> clear() async {
    for (final e in _c._store.entries) {
      _c._storageChanged.add(
        StorageChanged(key: e.key, oldValue: e.value, newValue: null),
      );
    }
    _c._store.clear();
  }

  @override
  Stream<StorageChanged> get onChanged => _c._storageChanged.stream;
}

final class _FakeAlarms implements AlarmsApi {
  _FakeAlarms(this._c);
  final FakeChrome _c;

  @override
  Future<void> create({
    required String name,
    int? periodMinutes,
    int? whenMs,
  }) async {
    if (periodMinutes == null && whenMs == null) {
      throw _err('bad_args', 'alarm "$name" needs periodMinutes or whenMs');
    }
    _c._alarms[name] = _AlarmRec(
      name: name,
      periodMs: periodMinutes == null ? null : periodMinutes * 60000,
      nextFireTs: whenMs ?? _c.nowMs + periodMinutes! * 60000,
    );
  }

  @override
  Future<bool> clear(String name) async => _c._alarms.remove(name) != null;

  @override
  Future<List<Alarm>> getAll() async => [
    for (final a in _c._alarms.values)
      Alarm(name: a.name, scheduledTs: a.nextFireTs),
  ];

  @override
  Stream<Alarm> get onAlarm => _c._alarmFired.stream;
}

final class _FakeNotifications implements NotificationsApi {
  _FakeNotifications(this._c);
  final FakeChrome _c;

  @override
  String get permission => _c.notificationPermission;

  @override
  Future<bool> create({
    required String id,
    required String title,
    required String message,
    String? iconUrl,
  }) async {
    if (_c.notificationPermission != 'granted') return false;
    _c._notifications[id] = _NotifRec(title: title, message: message);
    return true;
  }

  @override
  Future<bool> clear(String id) async => _c._notifications.remove(id) != null;
}

final class _FakeAction implements ActionApi {
  _FakeAction(this._c);
  final FakeChrome _c;

  @override
  Future<void> setBadgeText(String text) async => _c._badgeText = text;

  @override
  Future<void> setBadgeBackgroundColor(String colorCss) async =>
      _c._badgeColor = colorCss;

  @override
  Future<void> setTitle(String title) async => _c._actionTitle = title;
}

final class _FakeOffscreen implements OffscreenApi {
  _FakeOffscreen(this._c);
  final FakeChrome _c;

  @override
  Future<void> createDocument({
    required String url,
    required Set<String> reasons,
    required String justification,
  }) async {
    final bad = reasons.difference(mv3OffscreenReasons);
    if (reasons.isEmpty || bad.isNotEmpty) {
      throw _err(
        'invalid_reason',
        'offscreen reasons must come from the MV3 set; got '
            '${bad.isEmpty ? 'none' : bad.join(', ')}',
      );
    }
    if (_c._offscreenUrl != null) {
      throw _err(
        'document_exists',
        'an offscreen document already exists: ${_c._offscreenUrl}',
      );
    }
    _c._offscreenUrl = url;
  }

  @override
  Future<void> closeDocument() async {
    if (_c._offscreenUrl == null) {
      throw _err('no_document', 'no offscreen document exists');
    }
    _c._offscreenUrl = null;
  }

  @override
  Future<bool> hasDocument() async => _c._offscreenUrl != null;
}

final class _FakePower implements PowerApi {
  _FakePower(this._c);
  final FakeChrome _c;

  @override
  Future<void> requestKeepAwake(String level) async {
    if (level != 'system' && level != 'display') {
      throw _err('bad_args', 'power level must be "system" or "display"');
    }
    _c._keepAwakeLevel = level;
  }

  @override
  Future<void> releaseKeepAwake() async => _c._keepAwakeLevel = null;
}

final class _FakeIdle implements IdleApi {
  _FakeIdle(this._c);
  final FakeChrome _c;

  @override
  Future<String> queryState(int thresholdSeconds) async => _c._idleState;

  @override
  Stream<String> get onStateChanged => _c._stateChanged.stream;
}

final class _FakeContextMenus implements ContextMenusApi {
  _FakeContextMenus(this._c);
  final FakeChrome _c;

  @override
  Future<void> create({
    required String id,
    required String title,
    List<String>? contexts,
  }) async {
    if (_c._menus.containsKey(id)) {
      throw _err('duplicate_menu', 'menu item "$id" already exists');
    }
    _c._menus[id] = _MenuRec(
      title: title,
      contexts: List.of(contexts ?? const []),
    );
  }

  @override
  Future<void> removeAll() async => _c._menus.clear();

  @override
  Stream<MenuClick> get onClicked => _c._menuClicked.stream;
}

final class _FakeOmnibox implements OmniboxApi {
  _FakeOmnibox(this._c);
  final FakeChrome _c;

  @override
  Stream<OmniboxInput> get onInputEntered => _c._omniEntered.stream;
}

final class _FakeCommands implements CommandsApi {
  _FakeCommands(this._c);
  final FakeChrome _c;

  @override
  Stream<String> get onCommand => _c._commandPressed.stream;
}

final class _FakeWebNavigation implements WebNavigationApi {
  _FakeWebNavigation(this._c);
  final FakeChrome _c;

  @override
  Stream<NavCompleted> get onCompleted => _c._navCompleted.stream;
}

final class _FakeSystem implements SystemApi {
  const _FakeSystem();

  // ponytail: fixed plausible values — the fake has no hardware to probe.

  @override
  Future<CpuInfo> cpu() async => const CpuInfo(
    arch: 'arm',
    numProcessors: 8,
    modelName: 'Fake Chrome CPU',
  );

  @override
  Future<MemoryInfo> memory() async => const MemoryInfo(
    capacity: 16 * 1024 * 1024 * 1024,
    availableCapacity: 8 * 1024 * 1024 * 1024,
  );

  @override
  Future<StorageInfo> storage() async => const StorageInfo(
    units: [
      StorageUnit(
        id: '1',
        name: 'Fake Disk',
        type: 'fixed',
        capacity: 512 * 1024 * 1024 * 1024,
      ),
    ],
  );

  @override
  Future<DisplayInfo> display() async => const DisplayInfo(
    id: '0',
    name: 'Fake Display',
    width: 1920,
    height: 1080,
    primary: true,
  );
}

final class _FakeIdentity implements IdentityApi {
  _FakeIdentity(this._c);
  final FakeChrome _c;

  @override
  Future<String> launchWebAuthFlow({required String url}) async =>
      _c.authRedirectUrl;
}

// ---------------------------------------------------------------------------
// Internal mutable state records
// ---------------------------------------------------------------------------

final class _TabRec {
  _TabRec({
    required this.id,
    required this.url,
    required this.title,
    required this.pinned,
    required this.muted,
    required this.audible,
    required this.groupId,
    required this.windowId,
    required this.active,
    required this.favIconUrl,
  });

  final int id;
  String url;
  String title;
  bool pinned;
  bool muted;
  bool audible;
  int? groupId;
  int windowId;
  bool active;
  String? favIconUrl;
  bool discarded = false;
}

final class _WinRec {
  _WinRec({
    required this.id,
    required this.type,
    required this.state,
    required this.focused,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.incognito,
    required this.tabIds,
  });

  final int id;
  final String type;
  String state;
  bool focused;
  int left;
  int top;
  int width;
  int height;
  final bool incognito;
  final List<int> tabIds;
}

final class _GroupRec {
  _GroupRec({
    required this.id,
    required this.title,
    required this.color,
    required this.windowId,
  });

  final int id;
  String title;
  String color;
  final int windowId;
}

final class _ClosedRec {
  _ClosedRec({
    required this.sessionId,
    required this.lastModified,
    this.tab,
    this.window,
    this.windowTabs = const [],
  });

  final String sessionId;
  final int lastModified;
  final Tab? tab;
  final BrowserWindow? window;

  /// Tab snapshots carried by a closed window session so restore can
  /// rebuild the tabs (fresh ids) inside the fresh window.
  final List<Tab> windowTabs;
}

final class _AlarmRec {
  _AlarmRec({
    required this.name,
    required this.periodMs,
    required this.nextFireTs,
  });

  final String name;
  final int? periodMs;
  int nextFireTs;
}

final class _NotifRec {
  _NotifRec({required this.title, required this.message});

  final String title;
  final String message;
}

final class _MenuRec {
  _MenuRec({required this.title, required this.contexts});

  final String title;
  final List<String> contexts;
}

final class _DlRec {
  _DlRec({
    required this.id,
    required this.url,
    required this.filename,
    required this.state,
  });

  final int id;
  final String url;
  final String filename;
  String state;
  bool paused = false;
}

final class _BmRec {
  _BmRec({required this.id, required this.title, this.url, this.parentId});

  final String id;
  String title;
  String? url;
  String? parentId;
  final List<_BmRec> children = [];
}
