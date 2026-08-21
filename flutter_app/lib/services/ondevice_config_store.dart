// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The persisted record of the on-device engines the user has configured
/// (downloaded a model and applied it at least once). Drives whether the
/// on-device provider rows appear in the settings Providers list — an
/// engine the user never engaged with stays discoverable through the
/// "Add provider" flow instead of cluttering the list.
///
/// Non-secret by design: a set of provider-kind strings.
class OnDeviceConfigStore extends ChangeNotifier {
  OnDeviceConfigStore._(this._env);

  /// A store without persistence (tests, widget fallbacks).
  OnDeviceConfigStore.inMemory() : _env = null;

  /// File name (under [ExecutionEnv.cwd]) the store persists to.
  static const fileName = 'ondevice_config.json';

  static const _version = 1;

  final ExecutionEnv? _env;
  final Set<String> _kinds = {};

  /// Loads the record persisted in [env]; a missing, unreadable, or corrupt
  /// file yields an empty store.
  static Future<OnDeviceConfigStore> load(ExecutionEnv env) async {
    final store = OnDeviceConfigStore._(env);
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text == null) return store;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return store;
      if (decoded['version'] != _version) return store;
      final kinds = decoded['kinds'];
      if (kinds is List) {
        store._kinds.addAll(kinds.map((k) => k.toString()));
      }
    } on Object {
      // Best effort: a corrupt file loads as empty.
    }
    return store;
  }

  /// Whether the on-device [kind] was configured at least once.
  bool isConfigured(String kind) => _kinds.contains(kind);

  /// The configured kinds (read-only view).
  Set<String> get configuredKinds => Set.unmodifiable(_kinds);

  /// Marks the on-device [kind] as configured and persists. Persistence is
  /// best effort: a failed write must not break the connect flow.
  Future<void> markConfigured(String kind) async {
    if (!_kinds.add(kind)) return;
    notifyListeners();
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({'version': _version, 'kinds': _kinds.toList()}),
      );
    } on Object {
      // Best effort only.
    }
  }
}

/// Inherited access to the app-wide [OnDeviceConfigStore] (installed in
/// main.dart next to the other stores).
class OnDeviceConfigScope extends InheritedWidget {
  const OnDeviceConfigScope({
    super.key,
    required this.store,
    required super.child,
  });

  final OnDeviceConfigStore store;

  static OnDeviceConfigStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OnDeviceConfigScope>()?.store;

  @override
  bool updateShouldNotify(OnDeviceConfigScope oldWidget) =>
      store != oldWidget.store;
}
