// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Field-level merge for the stored `faProvider` map (issue #34): a panel
/// save that omits a field (e.g. a model-less provider row, or a key the
/// user did not retype) must not wipe the stored value. Empty/absent
/// incoming fields keep the stored ones; non-empty strings win.
Map<String, String> mergeProvider(
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

  return {
    'baseUrl': field('baseUrl'),
    'apiKey': field('apiKey'),
    'model': field('model'),
  };
}
