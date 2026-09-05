// dart2js entry for the extension service worker: binds the fa agent core
// to `globalThis.faAgent` (boot/sendUser/onEvent/decide/pushMail/getState/
// selfTest) and owns ALL chrome.* + `__faOps` js_interop bindings. Built by
// scripts/build_browser_ext.sh into browser_ext/sw/agent.js (never committed).
import 'dart:async';
import 'dart:js_interop';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart'
    show providerHttpClientFactory;

import 'src/agent_host.dart';
import 'src/dap/dap_integration.dart';
import 'src/fetch_client.dart';
import 'src/providers.dart';

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

AgentHost? _host;
Future<AgentHost?> _hostBoot = Future.value(null);
JSFunction? _eventCb;
final _deltaBuffer = StringBuffer();
Timer? _deltaTimer;

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

  // Auto-boot with the stored panel config (provider form + approval mode).
  _ensureHost(await _loadStoredConfig());
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
          return AgentHost.boot(sink: _emit, ops: _callOp, config: config);
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

Future<HostConfig> _loadStoredConfig() async {
  final stored = await _loadStoredRaw();
  return _configFrom(
    provider: stored['faProvider'],
    approval: stored['faApproval'],
    dap: stored['faDap'],
  );
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
