// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:js_widget_runtime/js_widget_runtime.dart';

import 'apps_store.dart';

/// One-shot LLM completion used by the `jsr.fa.llm(prompt)` bridge call.
typedef FaLlmHandler = Future<Object?> Function(String prompt);

/// Handler for platform bridges (`homekit`, `health`, `contacts`). Receives
/// the action name (`homekit.read`, `health.stepsToday`, …) and args.
typedef FaPlatformHandler =
    Future<Object?> Function(String action, Map<String, Object?> args);

/// Host-side engine for one JS app: owns the [JsWidgetEngine], wires every
/// `jsr.*` I/O call through the shared [ExecutionEnv] and the app's
/// [AppPermissions], and persists JS storage across reloads.
///
/// Permission gates:
/// - `jsr.fetchJson` → [AppPermissions.network]
/// - `jsr.exec(<shell>)` → command must be in [AppPermissions.allowedCommands]
/// - `jsr.fa.llm` → [AppPermissions.llm]
/// - `jsr.fa.homekit/health/contacts` → the matching flag (stubbed until the
///   platform implementations land — a granted call answers "not available").
class JsAppEngine {
  JsAppEngine({
    required this.app,
    required this.env,
    required this.permissions,
    this.llmHandler,
    this.platformHandler,
    void Function(String line)? onLog,
  }) : _onLog = onLog;

  final JsAppInfo app;
  final ExecutionEnv env;
  final AppPermissions permissions;
  final FaLlmHandler? llmHandler;
  final FaPlatformHandler? platformHandler;
  final void Function(String line)? _onLog;

  /// The latest rendered UI tree; the view listens and rebuilds.
  final ValueNotifier<Map<String, dynamic>?> tree =
      ValueNotifier<Map<String, dynamic>?>(null);

  JsWidgetEngine? _engine;
  JsResolveCallback? _resolve;

  Map<String, dynamic>? get exportedState => _engine?.exportedState;
  List<Map<String, dynamic>> peekLogs() => _engine?.peekLogs() ?? const [];

  /// Starts (or restarts) the JS engine with the current `widget.js`.
  Future<void> start() async {
    final old = _engine;
    _engine = null;
    if (old != null) await old.dispose();

    final js = (await env.readTextFile(app.widgetPath)).getOrThrow();
    final storage = await _readStorage();
    final config = JsRuntimeConfig(
      widgetId: app.id,
      initialStorage: storage,
      hostBootstrapJs: _faBootstrapJs,
      onRender: (t) => tree.value = t,
      onSetTitle: (_) {},
      onStorageUpdate: _persistStorage,
      onLog: _onLog,
      isPermissionAllowed: _isAllowed,
      onResolveReady: (resolve) => _resolve = resolve,
      fetchHandler: _fetch,
      loadAssetHandler: _loadAsset,
      execHandler: _exec,
    );
    final engine = JsWidgetEngine(config: config);
    _engine = engine;
    await engine.run(js);
  }

  Future<void> callEvent(String actionId, [Map<String, dynamic>? payload]) {
    final engine = _engine;
    if (engine == null) return Future.value();
    return engine.callEvent(actionId, payload);
  }

  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    if (engine != null) await engine.dispose();
    tree.dispose();
  }

  // --- storage persistence -------------------------------------------------

  String get _storagePath => '${app.dir}/storage.json';

  Future<Map<String, dynamic>> _readStorage() async {
    final raw = await env.readTextFile(_storagePath);
    final text = raw.valueOrNull;
    if (text != null) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) return decoded;
      } on FormatException {
        // Corrupt storage — start fresh.
      }
    }
    return {};
  }

  void _persistStorage(Map<String, dynamic> storage) {
    unawaited(env.writeFile(_storagePath, jsonEncode(storage)));
  }

  // --- permission gates ----------------------------------------------------
  //
  // Every capability is allowed at the bootstrap level; the handlers below
  // enforce permissions themselves so the JS side gets an ACTIONABLE error
  // ("network permission is disabled for X") instead of the package's
  // generic rejection.

  bool _isAllowed(String capability) => true;

  // --- jsr.fetchJson ---------------------------------------------------------

  Future<void> _fetch(
    String id,
    String url,
    String method,
    Map<String, String> headers,
  ) async {
    if (!permissions.network) {
      _resolve?.call(id, {'__error': _denied('network')});
      return;
    }
    try {
      final uri = Uri.parse(url);
      final response = switch (method.toUpperCase()) {
        'POST' => await http.post(uri, headers: headers),
        _ => await http.get(uri, headers: headers),
      };
      _resolve?.call(id, jsonDecode(response.body));
    } on Object catch (error) {
      _resolve?.call(id, {'__error': error.toString()});
    }
  }

  // --- jsr.loadAsset ---------------------------------------------------------

  Future<void> _loadAsset(String id, String path) async {
    try {
      _resolve?.call(
        id,
        (await env.readTextFile('${app.dir}/$path')).getOrThrow(),
      );
    } on Object catch (error) {
      _resolve?.call(id, {'__error': error.toString()});
    }
  }

  // --- jsr.exec + the jsr.fa bridge ------------------------------------------

  static const String _faBootstrapJs = '''
jsr.fa = {
  call: function(method, args) {
    return jsr.exec(JSON.stringify({fa: method, args: args || {}}));
  },
  llm: function(prompt) { return jsr.fa.call('llm', {prompt: prompt}); },
  homekit: function(action, args) { return jsr.fa.call('homekit.' + action, args); },
  health: function(action, args) { return jsr.fa.call('health.' + action, args); },
  contacts: function(action, args) { return jsr.fa.call('contacts.' + action, args); },
};
''';

  Future<void> _exec(String id, String cmd) async {
    // The jsr.fa bridge rides on exec with a JSON envelope.
    if (cmd.startsWith('{')) {
      try {
        final decoded = jsonDecode(cmd);
        if (decoded is Map<String, dynamic> && decoded['fa'] is String) {
          await _faCall(
            id,
            decoded['fa'] as String,
            (decoded['args'] as Map?)?.cast<String, Object?>() ?? const {},
          );
          return;
        }
      } on FormatException {
        // Not a bridge call — fall through to shell handling.
      }
    }
    if (!_isShellAllowed(cmd)) {
      _resolve?.call(id, {'__error': _denied('this command')});
      return;
    }
    final result = await env.exec(cmd);
    final value = result.valueOrNull;
    if (value == null) {
      _resolve?.call(id, {'__error': '${result.errorOrNull}'});
      return;
    }
    _resolve?.call(id, {
      'stdout': value.stdout,
      'stderr': value.stderr,
      'exitCode': value.exitCode,
    });
  }

  bool _isShellAllowed(String cmd) {
    final name = cmd.trim().split(RegExp(r'\s+')).first;
    return permissions.allowedCommands.contains(name);
  }

  Future<void> _faCall(
    String id,
    String method,
    Map<String, Object?> args,
  ) async {
    try {
      if (method == 'llm') {
        if (!permissions.llm) throw StateError(_denied('llm'));
        final handler = llmHandler;
        if (handler == null) throw StateError('LLM is not connected');
        _resolve?.call(id, await handler((args['prompt'] ?? '').toString()));
        return;
      }
      final prefix = method.split('.').first;
      final granted = switch (prefix) {
        'homekit' => permissions.homekit,
        'health' => permissions.health,
        'contacts' => permissions.contacts,
        _ => false,
      };
      if (!granted) throw StateError(_denied(prefix));
      final handler = platformHandler;
      if (handler == null) {
        throw StateError(
          '$prefix bridge is not available on this platform yet',
        );
      }
      _resolve?.call(id, await handler(method, args));
    } on Object catch (error) {
      _resolve?.call(id, {'__error': error.toString()});
    }
  }

  String _denied(String what) =>
      '$what permission is disabled for "${app.name}" '
      '(enable it in the app permissions)';
}
