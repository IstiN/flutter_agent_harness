// dart2js entry for the Office taskpane agent (issue #89): binds the fa
// agent core to `globalThis.faOfficeAgent` (boot/sendUser/decide/onEvent/
// getState/selfTest) and owns the localStorage js_interop bindings. Built
// by scripts/build_office_addin.sh into office_addin/web/office_agent.js
// (never committed). The Outlook twin of the extension's agent_main.dart,
// minus chrome.* and the UI port server: the taskpane host is the only
// surface.
//
// Settings ride one localStorage JSON key (`faOfficeSettings`:
// {faProvider: {baseUrl, apiKey, model}, faApproval}) — boot auto-uses the
// stored config; an explicit boot(config) wins per key. Before the host
// finishes booting, every sendUser/decide/selfTest call dispatches the
// clean not-ready error instead of forwarding into a half-built host.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart'
    show providerHttpClientFactory;

// The provider + fetch slices come from the extension package (path dep).
// fa_browser_agent does not export src/ through lib/, so the sibling path
// import is the one working route to them.
import '../../browser_ext/dart/src/fetch_client.dart';
import '../../browser_ext/dart/src/providers.dart' show ProviderConfig;

import 'src/agent_host.dart';
import 'src/office_api_js.dart';
import 'src/office_storage_env.dart';

/// Arbitrary property set (this SDK ships no unsafe JSObject extension).
@JS('Reflect.set')
external void _setProperty(JSObject target, JSAny? key, JSAny? value);

@JS('localStorage.getItem')
external JSString? _localStorageGet(JSString key);

@JS('localStorage.setItem')
external void _localStorageSet(JSString key, JSString value);

const _settingsKey = 'faOfficeSettings';

const _notReadyError = 'host not ready — Office.onReady has not fired yet';

OfficeAgentHost? _host;
bool _booting = false;
bool _ready = false;
String? _note;
JSFunction? _eventCb;
final _deltaBuffer = StringBuffer();
Timer? _deltaTimer;

Future<void> main() async {
  // package:cryptography resolves to BrowserCryptography under dart2js;
  // the pure-Dart implementations work everywhere — set them before
  // anything touches keys. MV3-style constraint applies to the taskpane
  // webview too: fetch but no XHR, so install the fetch-backed http
  // client up front.
  Cryptography.instance = DartCryptography.defaultInstance;
  providerHttpClientFactory = () => FetchClient();

  final faOfficeAgent = JSObject();
  // ponytail: explicit binds — .toJS needs a statically known type.
  _setProperty(faOfficeAgent, 'boot'.toJS, _bootImpl.toJS);
  _setProperty(faOfficeAgent, 'sendUser'.toJS, _sendUserImpl.toJS);
  _setProperty(faOfficeAgent, 'decide'.toJS, _decideImpl.toJS);
  _setProperty(faOfficeAgent, 'onEvent'.toJS, _onEventImpl.toJS);
  _setProperty(faOfficeAgent, 'getState'.toJS, _getStateImpl.toJS);
  _setProperty(faOfficeAgent, 'selfTest'.toJS, _selfTestImpl.toJS);
  _setProperty(globalContext, 'faOfficeAgent'.toJS, faOfficeAgent);

  // Auto-boot with the stored taskpane settings.
  await _boot(null);
}

// -- faOfficeAgent surface ---------------------------------------------------

JSPromise<JSAny?> _bootImpl(JSAny? config) => _boot(config).toJS;

Future<JSAny?> _boot(JSAny? config) async {
  if (_host != null || _booting) return _getState().jsify();
  _booting = true;
  try {
    final stored = _loadStored();
    final explicit = config == null
        ? null
        : config.dartify() as Map<Object?, Object?>?;
    final providerRaw = explicit?['faProvider'] ?? stored['faProvider'];
    final approval =
        '${explicit?['faApproval'] ?? stored['faApproval'] ?? 'ask'}';
    _host = await OfficeAgentHost.boot(
      sink: _emit,
      api: JsOfficeApi(),
      config: (provider: _providerFrom(providerRaw), approvalMode: approval),
      env: OfficeStorageEnv(read: _storageRead, write: _storageWrite),
    );
    _ready = true;
    _note = _host!.getState()['note'] as String?;
  } on Object catch (error) {
    _note = 'host API unavailable — agent answers without outlook tools';
    _dispatch({
      'type': 'status',
      'booted': false,
      'ready': false,
      'note': _note,
      'error': '$error',
    });
  } finally {
    _booting = false;
  }
  return _getState().jsify();
}

ProviderConfig? _providerFrom(Object? raw) {
  if (raw is! Map) return null;
  final model = '${raw['model'] ?? ''}'.trim();
  if (model.isEmpty) return null;
  return (
    baseUrl: '${raw['baseUrl'] ?? ''}'.trim(),
    apiKey: '${raw['apiKey'] ?? ''}',
    model: model,
  );
}

void _sendUserImpl(JSAny? text) {
  final host = _host;
  if (!_ready || host == null) {
    _dispatch({'type': 'error', 'error': _notReadyError});
    return;
  }
  host.sendUser(text.isA<JSString>() ? (text as JSString).toDart : '');
}

void _decideImpl(JSAny? id, JSAny? allow) {
  final host = _host;
  if (!_ready || host == null) {
    _dispatch({'type': 'error', 'error': _notReadyError});
    return;
  }
  host.decide(
    id.isA<JSString>() ? (id as JSString).toDart : '',
    allow.isA<JSBoolean>() ? (allow as JSBoolean).toDart : false,
  );
}

JSPromise<JSAny?> _selfTestImpl() => _runSelfTest().toJS;

Future<JSAny?> _runSelfTest() async {
  final host = _host;
  if (!_ready || host == null) {
    return {'ok': false, 'error': _notReadyError}.jsify();
  }
  return host.selfTest().jsify();
}

void _onEventImpl(JSAny? cb) => _eventCb = cb as JSFunction?;

JSAny? _getStateImpl() => _getState().jsify();

Map<String, dynamic> _getState() {
  final host = _host;
  if (host == null) {
    return {
      'booted': false,
      'ready': _ready,
      'host': 'unknown',
      'running': false,
      'note': ?_note,
    };
  }
  return host.getState();
}

// -- Event bridge --------------------------------------------------------------

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
    // A detached taskpane must never break a run.
  }
}

// -- localStorage plumbing -------------------------------------------------------

Map<Object?, Object?> _loadStored() {
  try {
    final raw = _localStorageGet(_settingsKey.toJS)?.toDart;
    if (raw == null || raw.isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded as Map<Object?, Object?>;
  } on Object {
    // Corrupt settings → clean start, never crash boot.
  }
  return const {};
}

String? _storageRead(String key) {
  try {
    return _localStorageGet(key.toJS)?.toDart;
  } on Object {
    return null; // storage blocked → clean fs
  }
}

void _storageWrite(String key, String value) {
  try {
    _localStorageSet(key.toJS, value.toJS);
  } on Object {
    // Save failed (quota, privacy mode): the env stays dirty and retries
    // on the next mutation or flush; never break the sandbox over it.
  }
}
