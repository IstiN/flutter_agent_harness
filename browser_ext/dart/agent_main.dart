// dart2js entry for the extension service worker: binds the fa agent core
// to `globalThis.faAgent` (boot/sendUser/onEvent/decide/pushMail/getState/
// selfTest) and owns ALL chrome.* + `__faOps` js_interop bindings. Built by
// scripts/build_browser_ext.sh into browser_ext/sw/agent.js (never committed).
//
// v2 (issue #30): on top of the v1 faAgent surface (byte-compatible, AC8)
// the worker now runs the UI port server (`fa-ui-v2` runtime ports), the
// badge + entry-point + alarm machinery, the 34-tool v2 power surface over
// the JsChromeApi bridge, and the exfil-gate visited-origin set. The raw
// chrome.runtime port plumbing lives here; everything else rides the typed
// facades.
import 'dart:async';
import 'dart:js_interop';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart'
    show providerHttpClientFactory;

import 'src/agent_host.dart';
import 'src/background/alarms.dart';
import 'src/background/badge.dart';
import 'src/background/entry_points.dart';
import 'src/chrome_api.dart' show ChromeApi, ChromeApiException;
import 'src/chrome_api_js.dart';
import 'src/dap/dap_integration.dart';
import 'src/fetch_client.dart';
import 'src/providers.dart';
import 'src/security/exfil_gate.dart' show originOf;
import 'src/ui_host_adapter.dart';
import 'src/ui_port_server.dart';
import 'src/ui_transport.dart';

/// Arbitrary property set (this SDK ships no unsafe JSObject extension).
@JS('Reflect.set')
external void _setProperty(JSObject target, JSAny? key, JSAny? value);

/// sw/main.js binds this to ops.dispatch (the browser op table).
@JS('__faOps')
external JSPromise<JSAny?> _faOps(JSString op, JSObject args);

@JS('chrome.storage.local.get')
external JSPromise<JSAny?> _storageGet(JSAny? keys);

@JS('chrome.storage.local.set')
external JSPromise<JSAny?> _storageSet(JSObject keys);

/// Port name the v2 side panel connects with.
const _uiPortName = 'fa-ui-v2';

/// Visited-origin budget (LRU-ish): the exfil gate reads the live set at
/// every outbound call, so it stays bounded even on tab-heavy sessions.
const _maxVisitedOrigins = 500;

AgentHost? _host;
Future<AgentHost?> _hostBoot = Future.value(null);
JSFunction? _eventCb;
final _deltaBuffer = StringBuffer();
Timer? _deltaTimer;

// -- v2 state (chrome-dependent pieces stay null when chrome is absent) -----

ChromeApi? _chromeApi;
BadgeController? _badge;
EntryPointHub? _entryPoints;
AlarmScheduler? _scheduler;
final _visitedOrigins = <String>{};
bool _runSurfaceRunning = false;

/// The settings snapshot seeds at boot from chrome.storage and every v2
/// settings_put flows through here; onSettings applies the merged snapshot
/// to the live host (panel Save without a re-boot).
final _adapter = UiHostAdapter(
  backend: () => _host,
  onSettings: _applySettings,
  persist: _persistSetting,
);

final _ports = UiPortServer(host: _adapter);

Future<void> main() async {
  // MV3 service workers have fetch but no XHR: package:http's default
  // client cannot work here — install the fetch-backed one up front.
  // package:cryptography resolves to BrowserCryptography under dart2js and
  // its X25519 binding crashes in a service worker (null-check on missing
  // WebCrypto guts) — which silently killed the DAP identity. The pure-Dart
  // implementations work everywhere; set them before anything touches keys.
  Cryptography.instance = DartCryptography.defaultInstance;
  providerHttpClientFactory = () => FetchClient();

  final faAgent = JSObject();
  // ponytail: seven explicit binds — .toJS needs a statically known type.
  _setProperty(faAgent, 'boot'.toJS, _bootImpl.toJS);
  _setProperty(faAgent, 'sendUser'.toJS, _sendUserImpl.toJS);
  _setProperty(faAgent, 'pushMail'.toJS, _pushMailImpl.toJS);
  _setProperty(faAgent, 'decide'.toJS, _decideImpl.toJS);
  _setProperty(faAgent, 'onEvent'.toJS, _onEventImpl.toJS);
  _setProperty(faAgent, 'getState'.toJS, _getStateImpl.toJS);
  _setProperty(faAgent, 'selfTest'.toJS, _selfTestImpl.toJS);
  _setProperty(globalContext, 'faAgent'.toJS, faAgent);
  _bindV2Surface();

  // v2 chrome machinery: a missing chrome surface (non-extension context,
  // stripped permissions) boots the v1-only agent — degraded, not dead.
  try {
    _chromeApi = JsChromeApi();
  } on ChromeApiException catch (error) {
    _dispatch({
      'type': 'status',
      'running': false,
      'booted': false,
      'note': '${error.message} — v2 power surface disabled',
    });
  }
  final chromeApi = _chromeApi;
  if (chromeApi != null) {
    _badge = BadgeController(chromeApi);
    // E25: the badge recomputes from authoritative inputs on every wake.
    unawaited(_badge!.resync(running: false, unreadMail: 0));

    final scheduler = AlarmScheduler(
      chromeApi,
      onDue: (task) => _host?.sendUser(task.prompt), // AC4c
    );
    _scheduler = scheduler;
    await scheduler.boot(); // E21: persisted tasks survive restarts

    final entryPoints = EntryPointHub(chromeApi); // subscribes at construction
    entryPoints.inputs.listen(_onExternalInput);
    _entryPoints = entryPoints;

    unawaited(_seedVisitedOrigins(chromeApi));
    chromeApi.webNavigation.onCompleted.listen(
      (nav) => _rememberOrigin(nav.url),
    );
    _listenUiPorts();
  }

  // Auto-boot with the stored panel config (provider form + approval mode).
  final stored = await _loadStoredRaw();
  _adapter.seed(stored);
  _ensureHost(
    _configFrom(
      provider: stored['faProvider'],
      approval: stored['faApproval'],
      dap: stored['faDap'],
    ),
  );
}

// -- faAgent surface ---------------------------------------------------------------

/// boot(config): explicit keys win, ABSENT keys inherit the stored panel
/// config (chrome.storage) — any interleaving of the SW's auto-boot and
/// panel/test boots converges on the same effective config instead of
/// last-writer-stomping partials.
JSPromise<JSAny?> _bootImpl(JSAny? config) => _bootMerged(config).toJS;

Future<JSAny?> _bootMerged(JSAny? config) async {
  final stored = await _loadStoredRaw();
  final map = config == null
      ? const <Object?, Object?>{}
      : (config as JSObject).dartify() as Map<Object?, Object?>;
  _ensureHost(
    _configFrom(
      provider: map.containsKey('provider')
          ? map['provider']
          : stored['faProvider'],
      approval: map.containsKey('approvalMode')
          ? map['approvalMode']
          : stored['faApproval'],
      dap: map.containsKey('dap') ? map['dap'] : stored['faDap'],
    ),
  );
  return {'ok': true}.jsify();
}

void _sendUserImpl(JSAny? text) =>
    _host?.sendUser((text as JSString?)?.toDart ?? '');

bool _isJsString(JSAny? v) => v != null && v.isA<JSString>();

void _pushMailImpl(JSAny? from, JSAny? text) {
  if (_isJsString(from) && _isJsString(text)) {
    _host?.pushMail((from! as JSString).toDart, (text! as JSString).toDart);
    final badge = _badge;
    if (badge != null) unawaited(badge.mailArrived()); // mail! outranks busy
  }
}

void _decideImpl(JSAny? id, JSAny? allow) {
  if (_isJsString(id)) {
    _host?.decide(
      (id! as JSString).toDart,
      (allow as JSBoolean?)?.toDart ?? false,
    );
  }
}

JSPromise<JSAny?> _selfTestImpl() => _runSelfTest().toJS;

Future<JSAny?> _runSelfTest() async {
  final host = await _hostBoot;
  final result = host == null
      ? <String, dynamic>{'ok': false, 'error': 'host not booted'}
      : await host.selfTest();
  return result.jsify();
}

void _onEventImpl(JSAny? cb) => _eventCb = cb as JSFunction?;

JSAny? _getStateImpl() =>
    (_host?.getState() ?? <String, dynamic>{'booted': false}).jsify();

// -- faAgentV2 surface (scheduled tasks + wiring snapshot) --------------------------

void _bindV2Surface() {
  final faAgentV2 = JSObject();
  _setProperty(faAgentV2, 'schedule'.toJS, _scheduleImpl.toJS);
  _setProperty(faAgentV2, 'removeScheduled'.toJS, _removeScheduledImpl.toJS);
  _setProperty(faAgentV2, 'listScheduled'.toJS, _listScheduledImpl.toJS);
  _setProperty(faAgentV2, 'state'.toJS, _v2StateImpl.toJS);
  _setProperty(globalContext, 'faAgentV2'.toJS, faAgentV2);
}

/// faAgentV2.schedule(id, prompt, periodMinutes) — registers a persisted
/// task; the alarm fires `prompt` into the agent (steers mid-run, AC4c).
JSPromise<JSAny?> _scheduleImpl(JSAny? id, JSAny? prompt, JSAny? period) =>
    _schedule(id, prompt, period).toJS;

Future<JSAny?> _schedule(JSAny? id, JSAny? prompt, JSAny? period) async {
  final scheduler = _scheduler;
  final taskId = _isJsString(id) ? (id! as JSString).toDart : null;
  final text = _isJsString(prompt) ? (prompt! as JSString).toDart : null;
  final minutes = (period?.isA<JSNumber>() ?? false)
      ? (period! as JSNumber).toDartInt
      : null;
  if (scheduler == null || taskId == null || text == null || minutes == null) {
    return {
      'ok': false,
      'error':
          'schedule(id, prompt, periodMinutes) — alarms surface '
          'unavailable or bad arguments',
    }.jsify();
  }
  try {
    await scheduler.schedule(
      ScheduledTask(
        id: taskId,
        prompt: text,
        period: Duration(minutes: minutes),
      ),
    );
    return {'ok': true}.jsify();
  } on Object catch (error) {
    return {'ok': false, 'error': '$error'}.jsify();
  }
}

JSPromise<JSAny?> _removeScheduledImpl(JSAny? id) => _removeScheduled(id).toJS;

Future<JSAny?> _removeScheduled(JSAny? id) async {
  final scheduler = _scheduler;
  if (scheduler == null || !_isJsString(id)) {
    return {'ok': false, 'error': 'removeScheduled(id) needs an id'}.jsify();
  }
  final removed = await scheduler.remove((id! as JSString).toDart);
  return {'ok': true, 'removed': removed}.jsify();
}

JSAny? _listScheduledImpl() => {
  'tasks': [
    for (final task in _scheduler?.list() ?? const <ScheduledTask>[])
      task.toJson(),
  ],
}.jsify();

/// Ports + badge + scheduled snapshot for the panel/test harness.
JSAny? _v2StateImpl() => {
  'connections': _ports.connections,
  'badge': _badge?.state.name,
  'visitedOrigins': _visitedOrigins.length,
}.jsify();

// -- Host lifecycle ------------------------------------------------------------------

void _ensureHost(HostConfig config) {
  final existing = _host;
  if (existing == null) {
    // A boot may already be in flight (main()'s auto-boot reading storage);
    // starting a second one makes _host last-writer-wins and the loser's
    // config silently evaporates. Queue instead: when the pending boot
    // finishes, apply the new config via reconfigure — or boot with it when
    // nothing actually came up.
    _hostBoot = _hostBoot
        .then((host) async {
          final live = host ?? _host;
          if (live != null) {
            live.reconfigure(config);
            return live;
          }
          final chromeApi = _chromeApi;
          return AgentHost.boot(
            sink: _emit,
            ops: _callOp,
            config: config,
            chrome: chromeApi,
            // The LIVE set: the gate reads it at call time, and
            // webNavigation keeps it warm after boot.
            visitedOrigins: chromeApi == null ? null : _visitedOrigins,
          );
        })
        .then((host) => _host = host);
  } else {
    existing.reconfigure(config);
  }
}

/// Event sink with the 50ms delta throttle: text deltas coalesce into one
/// `delta` event per window; every other event flushes the buffer first so
/// message_done/tool_result never overtake pending text.
void _emit(Map<String, dynamic> event) {
  if (event['type'] == 'delta') {
    _deltaBuffer.write(event['text']);
    _deltaTimer ??= Timer(const Duration(milliseconds: 50), () {
      _deltaTimer = null;
      _flushDelta();
    });
    return;
  }
  _flushDelta();
  _dispatch(event);
}

void _flushDelta() {
  if (_deltaBuffer.isEmpty) return;
  final text = _deltaBuffer.toString();
  _deltaBuffer.clear();
  _dispatch({'type': 'delta', 'text': text});
}

void _dispatch(Map<String, dynamic> event) {
  try {
    _eventCb?.callAsFunction(null, event.jsify());
  } on Object {
    // A dead panel must never break a run.
  }
  _ports.onHostEvent(event); // v2 fan-out: sync broadcast, safe from a sink
  _syncRunSurface(event);
}

/// Badge transitions + entry-point run tagging ride the status events so
/// every run path (prompt, mail, entry points, scheduled) stays in sync.
void _syncRunSurface(Map<String, dynamic> event) {
  if (event['type'] != 'status') return;
  final running = event['running'] == true;
  final badge = _badge;
  if (badge != null) {
    if (running && !_runSurfaceRunning) {
      unawaited(badge.runStarted());
    } else if (!running && _runSurfaceRunning) {
      unawaited(badge.runEnded());
      // E20: a denied permission degrades inside the controller.
      unawaited(badge.notify(title: 'fa', message: 'run finished'));
    }
  }
  _runSurfaceRunning = running;
  _entryPoints?.setActive(running);
}

/// E24: every external trigger feeds the SAME agent — sendUser starts a
/// turn when idle and steers the live run otherwise. A second agent is
/// never spawned.
void _onExternalInput(ExternalInput input) {
  final prompt = switch (input) {
    OmniboxInput(:final text) when text.isNotEmpty => '[from omnibox] $text',
    CommandInput(:final text) when text.isNotEmpty => '[from hotkey] $text',
    ContextMenuInput() => _menuPrompt(input),
    _ => null,
  };
  if (prompt == null) return;
  _host?.sendUser(prompt);
}

/// Selection, then link, then image url — whatever the click carried;
/// empty clicks (plain page menu) never start a run.
String? _menuPrompt(ContextMenuInput menu) {
  final target = menu.selectionText ?? menu.linkUrl ?? menu.srcUrl;
  if (target == null || target.isEmpty) return null;
  return '[from page ${menu.pageUrl ?? 'unknown'}] $target';
}

// -- UI port server (fa-ui-v2) -------------------------------------------------------

@JS('chrome.runtime.onConnect.addListener')
external void _onConnectAddListener(JSFunction listener);

extension type _JsEvent._(JSObject _) implements JSObject {
  external void addListener(JSFunction callback);
}

extension type _JsPort._(JSObject _) implements JSObject {
  external String get name;
  external void postMessage(JSAny? message);
  external void disconnect();
  external _JsEvent get onMessage;
  external _JsEvent get onDisconnect;
}

/// Adapts a chrome.runtime Port onto the [UiPortChannel] boundary:
/// structured-clone payloads dartify straight to the wire maps (no JSON
/// round-trip), non-map payloads are protocol garbage and skipped, and the
/// port's onDisconnect maps onto stream completion (the server's drop
/// signal).
final class _PortChannel implements UiPortChannel {
  _PortChannel(this._port) {
    _port.onMessage.addListener(
      ((JSAny? payload) {
        if (_closed) return;
        final decoded = payload?.dartify();
        if (decoded is Map) {
          _inbound.add(Map<String, dynamic>.from(decoded));
        }
      }).toJS,
    );
    _port.onDisconnect.addListener(
      ((JSAny? _) {
        _closed = true;
        _inbound.close();
      }).toJS,
    );
  }

  final _JsPort _port;
  final _inbound = StreamController<Map<String, dynamic>>();
  bool _closed = false;

  @override
  void send(Map<String, dynamic> json) {
    if (!_closed) _port.postMessage(json.jsify());
  }

  @override
  Stream<Map<String, dynamic>> get onMessage => _inbound.stream;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _port.disconnect();
  }

  @override
  bool get isClosed => _closed;
}

void _listenUiPorts() {
  _onConnectAddListener(
    ((JSObject rawPort) {
      final port = rawPort as _JsPort;
      if (port.name != _uiPortName) return;
      _ports.serve(_PortChannel(port));
    }).toJS,
  );
}

// -- Exfil-gate visited origins -------------------------------------------------------

void _rememberOrigin(String? url) {
  final origin = originOf(url);
  if (origin == null) return;
  _visitedOrigins
    ..remove(origin) // refresh pushes the origin to the back (LRU-ish)
    ..add(origin);
  while (_visitedOrigins.length > _maxVisitedOrigins) {
    _visitedOrigins.remove(_visitedOrigins.first);
  }
}

Future<void> _seedVisitedOrigins(ChromeApi chrome) async {
  try {
    for (final tab in await chrome.tabs.query()) {
      _rememberOrigin(tab.url);
    }
  } on Object {
    // Best-effort: webNavigation.onCompleted keeps the set warm either way.
  }
}

// -- Settings plumbing -----------------------------------------------------------------

/// Applies the merged settings snapshot to the live host (v2 settings_put
/// and the v1 panel Save land in the same reconfigure path).
void _applySettings(Map<String, Object?> settings) {
  final host = _host;
  if (host == null) return;
  host.reconfigure(
    _configFrom(
      provider: settings['faProvider'],
      approval: settings['faApproval'],
      dap: settings['faDap'],
    ),
  );
}

Future<void> _persistSetting(String key, Object? value) async {
  try {
    await _storageSet(<String, Object?>{key: value}.jsify() as JSObject).toDart;
  } on Object {
    // Storage blocked → the in-memory snapshot still wins this session.
  }
}

Future<Map<Object?, Object?>> _loadStoredRaw() async {
  try {
    final result = await _storageGet(
      ['faProvider', 'faApproval', 'faDap'].jsify(),
    ).toDart;
    if (result != null) {
      return (result as JSObject).dartify() as Map<Object?, Object?>;
    }
  } on Object {
    // Storage blocked → defaults.
  }
  return const {};
}

HostConfig _configFrom({Object? provider, Object? approval, Object? dap}) {
  ProviderConfig? resolved;
  if (provider is Map) {
    final baseUrl = '${provider['baseUrl'] ?? ''}'.trim();
    final apiKey = '${provider['apiKey'] ?? ''}';
    final model = '${provider['model'] ?? ''}'.trim();
    if (model.isNotEmpty) {
      resolved = (baseUrl: baseUrl, apiKey: apiKey, model: model);
    }
  }
  return (
    provider: resolved,
    approvalMode: approval is String ? approval : 'ask',
    // main.js overlays the live bridge mailbox name onto pushed status.
    mailbox: '',
    dap: _dapFrom(dap),
  );
}

/// faDap storage shape: `{url, name}`. Empty url = no hub presence.
DapConfig? _dapFrom(Object? raw) {
  if (raw is! Map) return null;
  final url = '${raw['url'] ?? ''}'.trim();
  if (url.isEmpty) return null;
  return DapConfig(
    url: url,
    name: '${raw['name'] ?? ''}'.trim(),
    loadKeyFile: () => _storageGetString('faDapKey'),
    saveKeyFile: (text) => _storageSetString('faDapKey', text),
  );
}

Future<String?> _storageGetString(String key) async {
  try {
    final result = await _storageGet([key].jsify()).toDart;
    if (result == null) return null;
    final stored = (result as JSObject).dartify() as Map<Object?, Object?>;
    return stored[key] is String ? stored[key] as String : null;
  } on Object {
    return null; // storage blocked → identity regenerates next start
  }
}

Future<void> _storageSetString(String key, String value) async {
  await _storageSet(<String, Object?>{key: value}.jsify() as JSObject).toDart;
}

// -- Ops bridge --------------------------------------------------------------------------

Future<Map<String, dynamic>> _callOp(
  String op,
  Map<String, dynamic> args,
) async {
  final raw = await _faOps(op.toJS, args.jsify() as JSObject).toDart;
  if (raw == null) return {'ok': false, 'error': 'op "$op" returned nothing'};
  return ((raw as JSObject).dartify() as Map).cast<String, dynamic>();
}
