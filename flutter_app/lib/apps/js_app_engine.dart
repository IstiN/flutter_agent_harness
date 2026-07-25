// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:js_widget_runtime/js_widget_runtime.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/services/calendar_service.dart';

/// One chat message for the `jsr.fa.llm.chat/stream` bridge calls; [role] is
/// `user`, `assistant`, or `system`.
typedef FaLlmMessage = ({String role, String content});

/// LLM completion used by the `jsr.fa.llm*` bridge calls. Receives the
/// conversation and resolves with the assistant's reply text. When [onDelta]
/// is given (the `llm.stream` call), it reports text deltas as they arrive.
typedef FaLlmHandler =
    Future<Object?> Function(
      List<FaLlmMessage> messages, {
      void Function(String delta)? onDelta,
    });

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
/// - `jsr.fa.llm` / `jsr.fa.llm.chat` / `jsr.fa.llm.stream` →
///   [AppPermissions.llm]
/// - `jsr.fa.calendar` → [AppPermissions.calendar] (real backend via
///   [CalendarApi]; requests OS access on first use)
/// - `jsr.fa.homekit/health/contacts` → the matching flag (stubbed until the
///   platform implementations land — a granted call answers "not available").
class JsAppEngine {
  JsAppEngine({
    required this.app,
    required this.env,
    required this.permissions,
    this.llmHandler,
    this.platformHandler,
    this.calendar,
    this.initialTheme = const {},
    void Function(String line)? onLog,
  }) : _onLog = onLog;

  final JsAppInfo app;
  final ExecutionEnv env;
  final AppPermissions permissions;
  final FaLlmHandler? llmHandler;
  final FaPlatformHandler? platformHandler;

  /// The `jsr.theme` map the app boots with (see `js_theme.dart`); later
  /// host theme changes are pushed via [updateTheme].
  final Map<String, dynamic> initialTheme;

  /// Calendar backend for `jsr.fa.calendar`; `null` uses the platform
  /// service ([createCalendarService] — a never-available stub on web).
  final CalendarApi? calendar;
  final void Function(String line)? _onLog;

  /// The latest rendered UI tree; the view listens and rebuilds.
  final ValueNotifier<Map<String, dynamic>?> tree =
      ValueNotifier<Map<String, dynamic>?>(null);

  /// Whether the running app registered a `jsr.onBack` handler — pushed by
  /// the bootstrap (`back.handler` bridge) every time the app assigns it.
  /// The view uses it for PopScope.canPop: with a handler, back gestures
  /// forward to JS first; without one the route pops natively.
  final ValueNotifier<bool> backHandlerRegistered = ValueNotifier(false);

  /// Called when the app declines to consume a back event (`back.close`
  /// bridge) — the host should pop the app route. Set by the view.
  void Function()? onCloseRequested;

  JsWidgetEngine? _engine;
  JsResolveCallback? _resolve;

  Map<String, dynamic>? get exportedState => _engine?.exportedState;
  List<Map<String, dynamic>> peekLogs() => _engine?.peekLogs() ?? const [];

  /// Starts (or restarts) the JS engine with the current `widget.js`.
  Future<void> start() async {
    final old = _engine;
    _engine = null;
    if (old != null) await old.dispose();
    backHandlerRegistered.value = false;

    final js = (await env.readTextFile(app.widgetPath)).getOrThrow();
    final storage = await _readStorage();
    final config = JsRuntimeConfig(
      widgetId: app.id,
      initialTheme: initialTheme,
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

  /// Pushes a new `jsr.theme` map into the running app; the JS side replaces
  /// `jsr.theme` and invokes `jsr._onThemeChange(theme)` when the app
  /// subscribed. No-op before [start] completes.
  Future<void> updateTheme(Map<String, dynamic> theme) {
    _engine?.updateTheme(theme);
    return Future.value();
  }

  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    if (engine != null) await engine.dispose();
    tree.dispose();
    backHandlerRegistered.dispose();
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
  calendar: function(args) { return jsr.fa.call('calendar.events', args); },
};
jsr.fa.calendar.create = function(args) { return jsr.fa.call('calendar.create', args); };
jsr.fa.calendar.update = function(args) { return jsr.fa.call('calendar.update', args); };
jsr.fa.calendar.delete = function(args) { return jsr.fa.call('calendar.delete', args); };

// Multi-turn + streaming LLM calls. Stream deltas cannot cross the bridge as
// a function reference, so the host pushes reserved 'llm.delta' events (see
// the onEvent wrapper below) carrying the ACCUMULATED partial text; the
// promise resolves with the full reply.
jsr._llmStreams = {};
jsr.fa.llm.chat = function(messages) { return jsr.fa.call('llm.chat', {messages: messages}); };
jsr.fa.llm.stream = function(messages, onDelta) {
  var streamId = 'llm-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  if (typeof onDelta === 'function') jsr._llmStreams[streamId] = onDelta;
  return jsr.fa.call('llm.stream', {messages: messages, stream: streamId}).then(function(text) {
    delete jsr._llmStreams[streamId];
    return text;
  }, function(error) {
    delete jsr._llmStreams[streamId];
    throw error;
  });
};
jsr._dispatchLlmDelta = function(payload) {
  var handler = payload && jsr._llmStreams[payload.stream];
  if (handler) {
    try { handler(payload.text); } catch (e) { console.error('jsr.fa.llm.stream onDelta: ' + e); }
  }
};

// Back-navigation contract: the host forwards route-back attempts (iOS edge
// swipe, Android system back, app-bar arrow) as a reserved 'back' event. An
// app that assigned jsr.onBack may consume it (return true) for internal
// navigation; anything else lets the host close the app.
jsr._onBackFn = null;
Object.defineProperty(jsr, 'onBack', {
  configurable: true,
  get: function() { return jsr._onBackFn; },
  set: function(fn) {
    jsr._onBackFn = (typeof fn === 'function') ? fn : null;
    jsr.fa.call('back.handler', {registered: jsr._onBackFn !== null});
  },
});
(function() {
  var baseOnEvent = jsr.onEvent;
  jsr.onEvent = function(fn) {
    baseOnEvent(function(actionId, payload) {
      if (actionId === 'llm.delta') {
        jsr._dispatchLlmDelta(payload);
        return;
      }
      if (actionId === 'back') {
        var consumed = false;
        if (jsr._onBackFn !== null) {
          try { consumed = jsr._onBackFn() === true; }
          catch (e) { console.error('jsr.onBack: ' + e); }
        }
        if (!consumed) jsr.fa.call('back.close');
        return;
      }
      fn(actionId, payload);
    });
  };
  // Fallback so llm.stream deltas land even when the app never registers an
  // event handler; an app registration replaces this via the wrapper above.
  baseOnEvent(function(actionId, payload) {
    if (actionId === 'llm.delta') jsr._dispatchLlmDelta(payload);
  });
})();
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
      if (method == 'llm' || method == 'llm.chat' || method == 'llm.stream') {
        if (!permissions.llm) throw StateError(_denied('llm'));
        final handler = llmHandler;
        if (handler == null) {
          throw StateError(
            'no LLM is connected — connect a model in the Fa settings first',
          );
        }
        final messages = method == 'llm'
            ? [(role: 'user', content: (args['prompt'] ?? '').toString())]
            : _parseLlmMessages(args['messages']);
        if (method == 'llm.stream') {
          // Deltas cross back as reserved 'llm.delta' events (see
          // _faBootstrapJs) carrying the accumulated partial text.
          final streamId = (args['stream'] ?? '').toString();
          final partial = StringBuffer();
          _resolve?.call(
            id,
            await handler(
              messages,
              onDelta: (delta) {
                partial.write(delta);
                final engine = _engine;
                if (engine == null) return;
                unawaited(
                  engine.callEvent('llm.delta', {
                    'stream': streamId,
                    'text': partial.toString(),
                  }),
                );
              },
            ),
          );
          return;
        }
        _resolve?.call(id, await handler(messages));
        return;
      }
      if (method == 'calendar.events') {
        _resolve?.call(id, await _calendarEvents(args));
        return;
      }
      if (method == 'calendar.create') {
        _resolve?.call(id, await _calendarCreate(args));
        return;
      }
      if (method == 'calendar.update') {
        _resolve?.call(id, await _calendarUpdate(args));
        return;
      }
      if (method == 'calendar.delete') {
        _resolve?.call(id, await _calendarDelete(args));
        return;
      }
      // Back-navigation contract (see _faBootstrapJs): the app reports its
      // jsr.onBack registration, and asks the host to close when a back
      // event went unconsumed. Neither is permission-gated.
      if (method == 'back.handler') {
        backHandlerRegistered.value = args['registered'] == true;
        _resolve?.call(id, true);
        return;
      }
      if (method == 'back.close') {
        onCloseRequested?.call();
        _resolve?.call(id, true);
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

  /// `jsr.fa.calendar({date, days})` → `{events: [...]}` — system calendar
  /// access, gated on the `calendar` permission.
  Future<Map<String, Object?>> _calendarEvents(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedCalendar();
    final range = calendarRange(
      date: args['date']?.toString(),
      days: (args['days'] as num?)?.toInt(),
    );
    final events = await api.events(start: range.start, end: range.end);
    return {
      'events': [
        for (final event in events)
          {
            'id': event.id,
            'title': event.title,
            'startMs': event.start.millisecondsSinceEpoch,
            'endMs': event.end.millisecondsSinceEpoch,
            'allDay': event.allDay,
            if (event.calendar != null) 'calendar': event.calendar,
            if (event.location != null) 'location': event.location,
            if (event.notes != null) 'notes': event.notes,
          },
      ],
    };
  }

  /// `jsr.fa.calendar.create({title, date, startHour, endHour, allDay,
  /// location, notes})` → `{id}` — same `calendar` permission gate.
  Future<Map<String, Object?>> _calendarCreate(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedCalendar();
    final title = (args['title'] ?? '').toString().trim();
    if (title.isEmpty) throw StateError('title is required');
    final slot = calendarSlot(
      date: args['date']?.toString(),
      startHour: args['startHour'] as num?,
      endHour: args['endHour'] as num?,
      allDay: args['allDay'] == true,
    );
    final id = await api.createEvent(
      title: title,
      start: slot.start,
      end: slot.end,
      allDay: slot.allDay,
      location: args['location']?.toString(),
      notes: args['notes']?.toString(),
    );
    return {'id': id};
  }

  /// `jsr.fa.calendar.update({id, ...same fields})` → `{updated: true}`;
  /// only the supplied fields change.
  Future<Map<String, Object?>> _calendarUpdate(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedCalendar();
    final id = (args['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('id is required');
    final hasSlot =
        args.containsKey('startHour') ||
        args.containsKey('endHour') ||
        args.containsKey('allDay');
    final slot = hasSlot
        ? calendarSlot(
            date: args['date']?.toString(),
            startHour: args['startHour'] as num?,
            endHour: args['endHour'] as num?,
            allDay: args['allDay'] == true,
          )
        : null;
    await api.updateEvent(
      id: id,
      title: args['title']?.toString(),
      start: slot?.start,
      end: slot?.end,
      allDay: slot?.allDay,
      location: args['location']?.toString(),
      notes: args['notes']?.toString(),
    );
    return {'updated': true};
  }

  /// `jsr.fa.calendar.delete({id})` → `{deleted: true}`.
  Future<Map<String, Object?>> _calendarDelete(
    Map<String, Object?> args,
  ) async {
    final api = await _gatedCalendar();
    final id = (args['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('id is required');
    await api.deleteEvent(id: id);
    return {'deleted': true};
  }

  /// The permission gate every `jsr.fa.calendar*` bridge call shares:
  /// the `calendar` permission, a platform backend, and OS access.
  Future<CalendarApi> _gatedCalendar() async {
    if (!permissions.calendar) throw StateError(_denied('calendar'));
    final api = calendar ?? createCalendarService();
    if (!await api.isAvailable) {
      throw StateError('calendar is not available on this platform');
    }
    if (!await api.requestAccess()) {
      throw StateError(
        'calendar access was denied — enable it in the system privacy '
        'settings (Privacy & Security → Calendars)',
      );
    }
    return api;
  }

  /// Validates the `messages` argument of `llm.chat`/`llm.stream`:
  /// `[{role: 'user'|'assistant'|'system', content: '...'}]`.
  static List<FaLlmMessage> _parseLlmMessages(Object? raw) {
    if (raw is! List) {
      throw StateError('messages must be a list of {role, content} objects');
    }
    final messages = <FaLlmMessage>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw StateError('each message must be a {role, content} object');
      }
      final role = (entry['role'] ?? '').toString();
      if (role != 'user' && role != 'assistant' && role != 'system') {
        throw StateError(
          'unsupported message role "$role" (user/assistant/system)',
        );
      }
      messages.add((role: role, content: (entry['content'] ?? '').toString()));
    }
    if (messages.isEmpty) throw StateError('messages must not be empty');
    return messages;
  }

  String _denied(String what) =>
      '$what permission is disabled for "${app.name}" '
      '(enable it in the app permissions)';
}
