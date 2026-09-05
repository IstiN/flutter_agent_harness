// Typed facade over the chrome.* APIs the fa agent drives (issue #30):
// one injectable interface tree plus JSON-able result records, so agent
// tools and SW machinery run unchanged against real Chrome (js_interop
// adapter, later phase) or the in-memory fake (fake_chrome.dart). Pure
// Dart — dart2js compiles this file into the MV3 service worker, so no
// dart:io and no js_interop may appear here.
//
// Chrome failures NEVER surface raw: every error crosses this facade as
// ChromeApiException whose `code` mirrors the sw/ops.js vocabulary
// ('no_tab', 'restricted_page', 'quota_exceeded', ...) — one stable
// machine contract for tools, panel and tests. Restricted-page rules are
// deliberately NOT part of this facade: that is tool-surface policy
// (ops.js E4), layered above the API, not API behavior.
library;

import 'dart:convert';

/// The one injection point for every chrome.* call the agent may make.
///
/// Getter names mirror chrome namespaces 1:1 (`tabs` → chrome.tabs,
/// `groups` → chrome.tabGroups, ...). Tools take a [ChromeApi]; production
/// wires the real adapter, tests wire `FakeChrome` — nothing else ever
/// touches a chrome global.
abstract interface class ChromeApi {
  TabsApi get tabs;
  WindowsApi get windows;
  TabGroupsApi get groups;
  SessionsApi get sessions;
  ScriptingApi get scripting;
  DebuggerApi get debugger;
  HistoryApi get history;
  BookmarksApi get bookmarks;
  DownloadsApi get downloads;
  CookiesApi get cookies;
  StorageApi get storage;
  AlarmsApi get alarms;
  NotificationsApi get notifications;
  ActionApi get action;
  OffscreenApi get offscreen;
  PowerApi get power;
  IdleApi get idle;
  ContextMenusApi get contextMenus;
  OmniboxApi get omnibox;
  CommandsApi get commands;
  WebNavigationApi get webNavigation;
  SystemApi get system;
  IdentityApi get identity;
}

/// The only error type this facade (and its fake) ever throws.
///
/// [code] is the stable machine key shared with sw/ops.js; [message] is
/// human text; [isRetryable] marks failures worth re-running — E3's
/// 'execution_context_destroyed' (a frame can vanish mid-script) and the
/// 30s op-cap 'timeout' both come back clean on retry, while 'no_tab' &
/// friends never do. An explicit [isRetryable] always wins over the
/// built-in table.
final class ChromeApiException implements Exception {
  ChromeApiException(this.code, this.message, {bool? isRetryable})
    : isRetryable = isRetryable ?? _retryableCodes.contains(code);

  static const _retryableCodes = {'execution_context_destroyed', 'timeout'};

  final String code;
  final String message;
  final bool isRetryable;

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    'retryable': isRetryable,
  };

  @override
  String toString() => 'ChromeApiException($code): $message';
}

/// Guards an executeScript / CDP result against the JSON wire (E2): chrome
/// hard-fails non-serializable injection results, so the fake and the real
/// adapter raise the same coded error instead of leaking a raw TypeError.
Object? requireJsonable(Object? value) {
  try {
    jsonEncode(value);
  } on JsonUnsupportedObjectError catch (e) {
    throw ChromeApiException(
      'result_not_serializable',
      'result is not JSON-able: ${e.unsupportedObject.runtimeType}',
    );
  }
  return value;
}

/// The fixed MV3 offscreen reason set (chrome docs) — validated by the
/// real adapter and the fake alike so tool code can never invent a reason.
const mv3OffscreenReasons = {
  'AUDIO_PLAYBACK',
  'AUDIO_CAPTURE',
  'BATTERY_STATUS',
  'BLOBS',
  'CLIPBOARD',
  'DISPLAY_MEDIA',
  'DOM_PARSER',
  'DOM_SCRAPING',
  'GEOLOCATION',
  'IFRAME_SCRIPTING',
  'LOCAL_FONT',
  'MATCH_MEDIA',
  'TESTING',
  'USER_MEDIA',
  'WEB_RTC',
};

/// Default chrome.storage.local quota (10 MB, chrome's real budget).
const defaultStorageQuotaBytes = 10 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Result records — JSON-able snapshots, no behavior beyond toJson
// ---------------------------------------------------------------------------

/// A browser tab snapshot (chrome.tabs.Tab, the JSON-able subset the agent
/// needs). [groupId] is null for ungrouped tabs — chrome uses -1 and null
/// round-trips JSON without magic numbers.
final class Tab {
  const Tab({
    required this.id,
    required this.url,
    required this.title,
    this.pinned = false,
    this.muted = false,
    this.audible = false,
    this.groupId,
    required this.windowId,
    this.active = false,
    this.favIconUrl,
    this.discarded = false,
  });

  final int id;
  final String url;
  final String title;
  final bool pinned;
  final bool muted;
  final bool audible;
  final int? groupId;
  final int windowId;
  final bool active;
  final String? favIconUrl;
  final bool discarded;

  Map<String, Object?> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'pinned': pinned,
    'muted': muted,
    'audible': audible,
    'groupId': groupId,
    'windowId': windowId,
    'active': active,
    'favIconUrl': favIconUrl,
    'discarded': discarded,
  };
}

/// chrome.tabs.onRemoved payload: which tab went, from where, and whether
/// the whole window took it down.
final class TabRemoved {
  const TabRemoved({
    required this.tabId,
    required this.windowId,
    required this.isWindowClosing,
  });

  final int tabId;
  final int windowId;
  final bool isWindowClosing;

  Map<String, Object?> toJson() => {
    'tabId': tabId,
    'windowId': windowId,
    'isWindowClosing': isWindowClosing,
  };
}

/// chrome.tabs.onUpdated payload: only the properties that changed, keyed
/// like chrome's changeInfo ('url', 'title', 'status', 'pinned', ...).
final class TabUpdated {
  const TabUpdated({required this.tabId, required this.changeInfo});

  final int tabId;
  final Map<String, Object?> changeInfo;

  Map<String, Object?> toJson() => {'tabId': tabId, 'changeInfo': changeInfo};
}

/// A browser window snapshot (chrome.windows.Window, JSON-able subset).
final class BrowserWindow {
  const BrowserWindow({
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
  final String type; // 'normal' | 'popup'
  final String state; // 'normal' | 'minimized' | 'maximized' | 'fullscreen'
  final bool focused;
  final int left;
  final int top;
  final int width;
  final int height;
  final bool incognito;
  final List<int> tabIds;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'state': state,
    'focused': focused,
    'left': left,
    'top': top,
    'width': width,
    'height': height,
    'incognito': incognito,
    'tabIds': tabIds,
  };
}

/// A chrome.tabGroups entry.
final class TabGroup {
  const TabGroup({
    required this.id,
    required this.title,
    required this.color,
    required this.windowId,
  });

  final int id;
  final String title;
  final String color; // chrome color names: 'grey', 'blue', ...
  final int windowId;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'color': color,
    'windowId': windowId,
  };
}

/// One chrome.sessions entry: a tab or a window closed recently, still
/// restorable by [sessionId].
final class ClosedSession {
  const ClosedSession({
    required this.sessionId,
    this.tab,
    this.window,
    required this.lastModified,
  });

  final String sessionId;
  final Tab? tab;
  final BrowserWindow? window;

  /// Seconds since epoch, like chrome's lastModified.
  final int lastModified;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'tab': tab?.toJson(),
    'window': window?.toJson(),
    'lastModified': lastModified,
  };
}

/// What sessions.restore brought back — exactly one of the two is set.
final class RestoredSession {
  const RestoredSession({this.tab, this.window});

  final Tab? tab;
  final BrowserWindow? window;

  Map<String, Object?> toJson() => {
    'tab': tab?.toJson(),
    'window': window?.toJson(),
  };
}

/// One frame's outcome of scripting.executeScript ([result] passed the
/// JSON guard — E2 failures raise instead).
final class ScriptResult {
  const ScriptResult({required this.frameId, required this.result});

  final int frameId;
  final Object? result;

  Map<String, Object?> toJson() => {'frameId': frameId, 'result': result};
}

/// One chrome.history entry.
final class HistoryItem {
  const HistoryItem({
    required this.id,
    required this.url,
    required this.title,
    required this.lastVisitTs,
  });

  final String id;
  final String url;
  final String title;

  /// ms since epoch of the last visit.
  final int lastVisitTs;

  Map<String, Object?> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'lastVisitTs': lastVisitTs,
  };
}

/// A chrome.bookmarks node; [url] null means folder ([children] then
/// carries the subtree).
final class BookmarkNode {
  const BookmarkNode({
    required this.id,
    required this.title,
    this.url,
    this.children = const [],
  });

  final String id;
  final String title;
  final String? url;
  final List<BookmarkNode> children;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'children': [for (final c in children) c.toJson()],
  };
}

/// A chrome.downloads entry.
final class DownloadItem {
  const DownloadItem({
    required this.id,
    required this.url,
    required this.filename,
    required this.state,
    required this.paused,
  });

  final int id;
  final String url;
  final String filename;
  final String state; // 'in_progress' | 'complete' | 'interrupted'
  final bool paused;

  Map<String, Object?> toJson() => {
    'id': id,
    'url': url,
    'filename': filename,
    'state': state,
    'paused': paused,
  };
}

/// A chrome.cookies entry. [expirationDate] is seconds since epoch.
final class Cookie {
  const Cookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.secure,
    required this.httpOnly,
    this.expirationDate,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final bool secure;
  final bool httpOnly;
  final int? expirationDate;

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'path': path,
    'secure': secure,
    'httpOnly': httpOnly,
    'expirationDate': expirationDate,
  };
}

/// A chrome.alarms entry: name plus the next scheduled fire (ms epoch).
final class Alarm {
  const Alarm({required this.name, required this.scheduledTs});

  final String name;
  final int scheduledTs;

  Map<String, Object?> toJson() => {'name': name, 'scheduledTs': scheduledTs};
}

/// chrome.storage.onChanged payload for one key; [newValue] null means
/// the key was removed.
final class StorageChanged {
  const StorageChanged({
    required this.key,
    required this.oldValue,
    required this.newValue,
  });

  final String key;
  final Object? oldValue;
  final Object? newValue;

  Map<String, Object?> toJson() => {
    'key': key,
    'oldValue': oldValue,
    'newValue': newValue,
  };
}

/// chrome.contextMenus.onClicked payload.
final class MenuClick {
  const MenuClick({
    required this.menuItemId,
    this.selectionText,
    this.linkUrl,
    this.srcUrl,
    this.pageUrl,
    this.tab,
  });

  final String menuItemId;
  final String? selectionText;
  final String? linkUrl;
  final String? srcUrl;
  final String? pageUrl;
  final Tab? tab;

  Map<String, Object?> toJson() => {
    'menuItemId': menuItemId,
    'selectionText': selectionText,
    'linkUrl': linkUrl,
    'srcUrl': srcUrl,
    'pageUrl': pageUrl,
    'tab': tab?.toJson(),
  };
}

/// chrome.omnibox.onInputEntered payload.
final class OmniboxInput {
  const OmniboxInput({required this.text, required this.disposition});

  final String text;
  final String disposition;

  Map<String, Object?> toJson() => {'text': text, 'disposition': disposition};
}

/// chrome.webNavigation.onCompleted payload.
final class NavCompleted {
  const NavCompleted({
    required this.tabId,
    required this.url,
    required this.frameId,
  });

  final int tabId;
  final String url;
  final int frameId;

  Map<String, Object?> toJson() => {
    'tabId': tabId,
    'url': url,
    'frameId': frameId,
  };
}

/// chrome.system.cpu info.
final class CpuInfo {
  const CpuInfo({
    required this.arch,
    required this.numProcessors,
    required this.modelName,
  });

  final String arch;
  final int numProcessors;
  final String modelName;

  Map<String, Object?> toJson() => {
    'arch': arch,
    'numProcessors': numProcessors,
    'modelName': modelName,
  };
}

/// chrome.system.memory info (bytes).
final class MemoryInfo {
  const MemoryInfo({required this.capacity, required this.availableCapacity});

  final int capacity;
  final int availableCapacity;

  Map<String, Object?> toJson() => {
    'capacity': capacity,
    'availableCapacity': availableCapacity,
  };
}

/// One chrome.system.storage unit.
final class StorageUnit {
  const StorageUnit({
    required this.id,
    required this.name,
    required this.type,
    required this.capacity,
  });

  final String id;
  final String name;
  final String type; // 'fixed' | 'removable' | 'unknown'
  final int capacity;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'capacity': capacity,
  };
}

/// chrome.system.storage info.
final class StorageInfo {
  const StorageInfo({required this.units});

  final List<StorageUnit> units;

  Map<String, Object?> toJson() => {
    'units': [for (final u in units) u.toJson()],
  };
}

/// chrome.system.display info for one display.
final class DisplayInfo {
  const DisplayInfo({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.primary,
  });

  final String id;
  final String name;
  final int width;
  final int height;
  final bool primary;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'width': width,
    'height': height,
    'primary': primary,
  };
}

// ---------------------------------------------------------------------------
// Sub-facades — one per chrome namespace, signatures mirror the chrome API
// ---------------------------------------------------------------------------

/// chrome.tabs. `url`/`title` query filters are chrome match patterns
/// (`*` wildcard; no `*` means exact match).
abstract interface class TabsApi {
  Future<Tab> create({String? url, bool? active, int? index, bool? pinned});
  Future<Tab> get(int id);
  Future<Tab> update(
    int id, {
    String? url,
    bool? active,
    bool? pinned,
    bool? muted,
  });
  Future<List<Tab>> query({
    String? url,
    String? title,
    int? groupId,
    bool? pinned,
    bool? muted,
    bool? active,
    bool? currentWindow,
  });
  Future<void> close(int id);
  Future<Tab> duplicate(int id);
  Future<Tab> reload(int id, {bool bypassCache = false});
  Future<Tab> move(int id, {required int index, int? windowId});

  /// Creates the group when [groupId] is null, else joins it; [title] /
  /// [color] are the tabGroups.update pass-through folded in so tools make
  /// one call instead of two. Returns the group id.
  Future<int> group({
    required List<int> tabIds,
    int? groupId,
    String? title,
    String? color,
  });
  Future<void> ungroup(List<int> tabIds);
  Future<Tab> discard(int id);

  Stream<Tab> get onCreated;
  Stream<TabRemoved> get onRemoved;
  Stream<TabUpdated> get onUpdated;
}

/// chrome.windows.
abstract interface class WindowsApi {
  Future<BrowserWindow> create({
    String? url,
    String? type, // 'normal' | 'popup'
    String? state, // 'normal' | 'minimized' | 'maximized' | 'fullscreen'
    int? width,
    int? height,
    int? left,
    int? top,
    bool? incognito,
  });
  Future<BrowserWindow> get(int id);
  Future<List<BrowserWindow>> getAll();
  Future<BrowserWindow> update(
    int id, {
    String? state,
    bool? focused,
    int? left,
    int? top,
    int? width,
    int? height,
  });
  Future<void> close(int id);
}

/// chrome.tabGroups (facade getter is `groups`).
abstract interface class TabGroupsApi {
  Future<TabGroup> update(int groupId, {String? title, String? color});
  Future<List<TabGroup>> query({String? title, String? color});

  /// Closes the group and every tab in it.
  Future<void> close(int groupId);
}

/// chrome.sessions — the recently-closed ring.
abstract interface class SessionsApi {
  Future<List<ClosedSession>> getRecentlyClosed();
  Future<RestoredSession> restore(String sessionId);
}

/// chrome.scripting. [ScriptingApi.executeScript] takes the function source
/// as a string (the SW has no closure channel to the page) and every result
/// must be JSON-able (E2).
abstract interface class ScriptingApi {
  Future<List<ScriptResult>> executeScript({
    required int tabId,
    String? world, // 'ISOLATED' (default) | 'MAIN'
    bool? allFrames,
    List<int>? frameIds,
    required String funcSource,
    List<Object?>? args,
  });
  Future<void> insertCSS({
    required int tabId,
    required String css,
    bool? allFrames,
  });
}

/// chrome.debugger — a thin CDP passthrough ('Runtime.evaluate',
/// 'Page.captureScreenshot' land here).
abstract interface class DebuggerApi {
  Future<void> attach(int tabId, {String requiredVersion = '1.3'});
  Future<void> detach(int tabId);
  Future<Object?> sendCommand(
    int tabId,
    String method, [
    Map<String, Object?>? params,
  ]);
}

/// chrome.history.
abstract interface class HistoryApi {
  Future<List<HistoryItem>> search({
    required String text,
    int? startTime,
    int? endTime,
    int? maxResults,
  });
}

/// chrome.bookmarks. Ids are strings like chrome's; roots '1' (Bookmarks
/// bar) and '2' (Other bookmarks) always exist and cannot be removed.
abstract interface class BookmarksApi {
  Future<List<BookmarkNode>> tree();
  Future<BookmarkNode> create({
    String? parentId,
    required String title,
    String? url,
  });
  Future<BookmarkNode> update(String id, {String? title, String? url});
  Future<void> remove(String id);
  Future<BookmarkNode> move(String id, {String? parentId, int? index});
}

/// chrome.downloads.
abstract interface class DownloadsApi {
  Future<int> download({required String url, String? filename, bool? saveAs});
  Future<List<DownloadItem>> search({String? query, String? state});
  Future<void> pause(int id);
  Future<void> resume(int id);
  Future<void> cancel(int id);
}

/// chrome.cookies.
abstract interface class CookiesApi {
  Future<Cookie?> get({required String url, required String name});
  Future<List<Cookie>> getAll({String? url, String? domain, String? name});
  Future<Cookie> set({
    required String url,
    required String name,
    required String value,
    bool? secure,
    bool? httpOnly,
    int? expirationDate,
  });
  Future<void> remove({required String url, required String name});
}

/// chrome.storage.local (the only area the agent uses).
abstract interface class StorageApi {
  int get quotaBytes;

  /// All entries when [keys] is null, else the present subset.
  Future<Map<String, Object?>> get([List<String>? keys]);
  Future<void> set(Map<String, Object?> items);
  Future<void> remove(List<String> keys);
  Future<void> clear();
  Stream<StorageChanged> get onChanged;
}

/// chrome.alarms. Create with at least one of [AlarmsApi.create]'s
/// periodMinutes / whenMs — chrome refuses both-missing.
abstract interface class AlarmsApi {
  Future<void> create({required String name, int? periodMinutes, int? whenMs});
  Future<bool> clear(String name);
  Future<List<Alarm>> getAll();
  Stream<Alarm> get onAlarm;
}

/// chrome.notifications. [NotificationsApi.create] returns false instead of
/// throwing when the permission is 'denied' — the agent treats that as a
/// soft skip, not an error.
abstract interface class NotificationsApi {
  String get permission; // 'granted' | 'denied'
  Future<bool> create({
    required String id,
    required String title,
    required String message,
    String? iconUrl,
  });
  Future<bool> clear(String id);
}

/// chrome.action (the toolbar badge).
abstract interface class ActionApi {
  Future<void> setBadgeText(String text);
  Future<void> setBadgeBackgroundColor(String colorCss);
  Future<void> setTitle(String title);
}

/// chrome.offscreen — single-document lifecycle with MV3 reason
/// validation against [mv3OffscreenReasons].
abstract interface class OffscreenApi {
  Future<void> createDocument({
    required String url,
    required Set<String> reasons,
    required String justification,
  });
  Future<void> closeDocument();
  Future<bool> hasDocument();
}

/// chrome.power.
abstract interface class PowerApi {
  Future<void> requestKeepAwake(String level); // 'system' | 'display'
  Future<void> releaseKeepAwake();
}

/// chrome.idle. The fake has no real idle detector — [IdleApi.queryState]
/// echoes whatever state was last set.
abstract interface class IdleApi {
  Future<String> queryState(int thresholdSeconds); // 'active'|'idle'|'locked'
  Stream<String> get onStateChanged;
}

/// chrome.contextMenus.
abstract interface class ContextMenusApi {
  Future<void> create({
    required String id,
    required String title,
    List<String>? contexts,
  });
  Future<void> removeAll();
  Stream<MenuClick> get onClicked;
}

/// chrome.omnibox — default-entry input events only.
abstract interface class OmniboxApi {
  Stream<OmniboxInput> get onInputEntered;
}

/// chrome.commands — registered keyboard shortcuts.
abstract interface class CommandsApi {
  Stream<String> get onCommand;
}

/// chrome.webNavigation — completed navigations (main + sub frames).
abstract interface class WebNavigationApi {
  Stream<NavCompleted> get onCompleted;
}

/// chrome.system.* — device info records.
abstract interface class SystemApi {
  Future<CpuInfo> cpu();
  Future<MemoryInfo> memory();
  Future<StorageInfo> storage();
  Future<DisplayInfo> display();
}

/// chrome.identity — the launchWebAuthFlow slice only.
abstract interface class IdentityApi {
  Future<String> launchWebAuthFlow({required String url});
}
