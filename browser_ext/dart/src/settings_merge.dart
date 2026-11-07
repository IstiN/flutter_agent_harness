// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'providers.dart' show storedIntSetting;

/// Field-level merge for the stored `faProvider` map (issue #34): a panel
/// save that omits a field (e.g. a model-less provider row, or a key the
/// user did not retype) must not wipe the stored value. Empty/absent
/// incoming fields keep the stored ones; non-empty strings win.
/// Integer fields (`contextWindow`, `contextWindowCap` — gh-2059 AC7)
/// merge by presence, tolerating the string-encoded form on BOTH sides
/// (a panel save may store numbers as strings; machine review S1 keeps
/// this aligned with `storedIntSetting`): an incoming int wins, otherwise
/// the stored int survives, else the field is absent.
Map<String, Object?> mergeProvider(
  Map<Object?, Object?>? stored,
  Map<Object?, Object?> incoming,
) {
  String field(String name) {
    final v = incoming[name];
    if (v is String && v.trim().isNotEmpty) return v;
    final s = stored?[name];
    if (s is String) return s;
    return '';
  }

  int? intField(String name) =>
      storedIntSetting(incoming, name) ??
      (stored == null ? null : storedIntSetting(stored, name));

  return {
    'baseUrl': field('baseUrl'),
    'apiKey': field('apiKey'),
    'model': field('model'),
    'contextWindow': intField('contextWindow'),
    'contextWindowCap': intField('contextWindowCap'),
  };
}
